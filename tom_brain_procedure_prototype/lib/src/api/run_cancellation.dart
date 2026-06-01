// RunCancellation — the cancel + external-timeout control behind a
// `ProcedureRun` handle (Plan step C.39, subphase C.10;
// `tom_brain_procedure_prototype_specification.md` § 10.1).
//
// ── Why a separate control from the step deadline ───────────────────
//
// C.36's `StepDeadline` is an *internal* guard: it bounds a single runaway
// background step so the cooperative-preemption hand-off (C.34/C.35) cannot
// be held open forever. C.39 is the *external* lever a caller drives the
// whole run with — the dispatcher (Phase D) that started a run can decide,
// from outside, that it no longer wants the result: either explicitly
// (`run.cancel()`) or because a wall-clock budget it set for the whole
// invocation elapsed (`invoke(..., timeout: …)`). These are different
// concerns — step protection vs. caller intent — so they are different
// mechanisms. The deadline closes a truncated run `preempted`; cancellation
// and timeout close the run `aborted` (the `TrailOutcomeStatus` documented
// as "aborted by the caller (cooperative cancel)").
//
// ── Cooperative, not forcible ───────────────────────────────────────
//
// A `Future` cannot be cancelled (the same constraint the step deadline
// documents). So cancellation here is *cooperative abandonment*: when the
// signal fires, the engine stops waiting on the run's step future and closes
// the run `aborted`; the abandoned d4rt work may still run to completion in
// the background, its result simply dropped. The run still lands on
// `recent_runs` (closed through the recorder's normal `complete` path) so an
// operator can see it was cut short by the caller rather than finishing on
// its own.
//
// ── What C.39 owns vs. does NOT own ─────────────────────────────────
//
// C.39 owns the *mechanism*: the signal a `cancel()` or an armed timeout
// completes, and the well-known trail-note categories the engine records the
// abandonment under. It does NOT own *driving* a tree of runs — cancelling a
// parent abandons its whole sub-tree by abandoning the parent's step future;
// a nested run is not individually re-closed (it owns its own recorder and
// finishes, or is itself abandoned, on its own terms). Threading cancellation
// down a `runProcedure` chain so each level closes `aborted` is a later
// concern (the Phase D coordinator, D.23–D.25).

import 'dart:async';

/// The trail-note category an explicitly-cancelled run is recorded under.
///
/// When `run.cancel()` fires, the engine appends a `note` in this category to
/// the run's trail before closing it `aborted`, so an operator can see the
/// run was abandoned by the caller rather than truncated by the deadline.
const String runCancelledNoteCategory = 'run_cancelled';

/// The trail-note category a timed-out run is recorded under.
///
/// When the external `timeout` a caller passed to `invoke` elapses, the
/// engine appends a `note` in this category (carrying the `timeoutMs` that
/// was breached) before closing the run `aborted`. Distinct from
/// [runCancelledNoteCategory] so the *cause* of the abort is legible on the
/// trail even though both close on the same structural status (Q-C.39.1).
const String runTimedOutNoteCategory = 'run_timed_out';

/// Why a run's cancellation signal fired.
///
/// A sealed pair of intents so the engine can record the right trail note:
/// an explicit caller [cancelled], or an elapsed external [timedOut] budget.
enum RunCancelCause {
  /// `run.cancel()` was called.
  cancelled,

  /// The external `timeout` passed to `invoke` elapsed.
  timedOut,
}

/// The seam through which [RunCancellation] schedules its timeout timer.
///
/// Defaults to `Timer.new` in production. Injectable so a test can drive the
/// timeout deterministically — capturing the callback and firing it on
/// demand — without sleeping for the real budget. Mirrors the injectable
/// timer the step deadline (C.36) takes for the same reason.
typedef CancellationTimerFactory = Timer Function(
  Duration duration,
  void Function() onExpire,
);

/// The cancel + external-timeout control for one procedure run.
///
/// Built per `invoke`. The handle a caller holds exposes [cancel]; the engine
/// pipeline races [signal] against the run's step future and, when the signal
/// wins, closes the run `aborted`. When the run finishes on its own the engine
/// calls [dispose] to disarm a pending timeout timer — after which a late
/// [cancel] is a no-op (the run already produced its outcome).
final class RunCancellation {
  /// Builds the control, optionally arming an external [timeout].
  ///
  /// When [timeout] is supplied the control fires [RunCancelCause.timedOut]
  /// after it elapses (over the injectable [timerFactory], default
  /// `Timer.new`). Throws [ArgumentError] when [timeout] is not strictly
  /// positive — a zero-or-negative budget would abort every run before it
  /// could advance.
  RunCancellation({
    this.timeout,
    CancellationTimerFactory? timerFactory,
  }) {
    final budget = timeout;
    if (budget == null) {
      return;
    }
    if (budget <= Duration.zero) {
      throw ArgumentError.value(
        budget,
        'timeout',
        'a run timeout must be strictly positive',
      );
    }
    final factory = timerFactory ?? Timer.new;
    _timer = factory(budget, _onTimeout);
  }

  /// The external wall-clock budget for the whole run, or `null` when the
  /// run has no timeout (cancellation is then only via [cancel]).
  final Duration? timeout;

  final Completer<RunCancelCause> _signal = Completer<RunCancelCause>();
  Timer? _timer;
  bool _closed = false;
  RunCancelCause? _cause;

  /// Completes when the run is cancelled or times out, carrying the cause.
  ///
  /// Never completes when the run finishes on its own (then [dispose] disarms
  /// the timer and leaves this future pending — the engine simply stops
  /// listening). The engine races this against the run's step future.
  Future<RunCancelCause> get signal => _signal.future;

  /// Whether the signal has fired (cancelled or timed out).
  bool get isSignalled => _cause != null;

  /// Whether the signal fired because the caller explicitly cancelled.
  bool get isCancelled => _cause == RunCancelCause.cancelled;

  /// Whether the signal fired because the external timeout elapsed.
  bool get isTimedOut => _cause == RunCancelCause.timedOut;

  /// Cancels the run on the caller's behalf.
  ///
  /// Idempotent and safe after the run finished: a [cancel] that arrives once
  /// the control is [dispose]d (the run produced its outcome) is dropped.
  void cancel() => _fire(RunCancelCause.cancelled);

  /// Disarms a pending timeout timer because the run finished on its own.
  ///
  /// Idempotent. After [dispose] the signal can no longer fire — a late
  /// [cancel] is a no-op, because the run already resolved its outcome.
  void dispose() {
    if (_closed) {
      return;
    }
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }

  void _onTimeout() => _fire(RunCancelCause.timedOut);

  void _fire(RunCancelCause cause) {
    if (_closed) {
      return;
    }
    _closed = true;
    _cause = cause;
    _timer?.cancel();
    _timer = null;
    if (!_signal.isCompleted) {
      _signal.complete(cause);
    }
  }
}
