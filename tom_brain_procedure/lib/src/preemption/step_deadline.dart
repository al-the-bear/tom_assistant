// StepDeadline — the hard per-step wall-clock cap that force-yields a
// runaway background step and marks it truncated (Plan step C.36, subphase
// C.9; `tom_brain_procedure_specification.md` § 9, PE-5, § 10.3;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// ── Why a hard deadline at all ──────────────────────────────────────
//
// Preemption is cooperative: a background run yields to a waiting
// foreground only at its *next* `yield_if_foreground_waiting()` checkpoint
// (C.35), never mid-step. That bounds how long the foreground waits to *one
// step*. A "step" is the work between two checkpoints, and by definition has
// no checkpoint inside it — so a step that runs away (an LLM call that never
// returns, a pathological loop in a procedure) would hold the foreground
// open indefinitely. The hard step deadline is the floor under that: a step
// that exceeds the limit (default 60 s wall clock) is *force-yielded* — the
// engine stops waiting on it and closes the run as truncated.
//
// ── What "force-yield" means here vs. the cooperative yield ──────────
//
// Cooperative yield (C.35) parks the background on a resume signal and lets
// it continue later — the step finishes, the run survives. The deadline is
// the opposite: there is no inner checkpoint to reach, so the only way to
// give the foreground its turn is to *stop waiting on the current step*. A
// `Future` cannot be cancelled, so the truncated step's work may still run
// to completion in the background; the engine simply abandons its result.
// The run is closed through the recorder's normal `complete` path with
// `TrailOutcomeStatus.preempted` and a truncated-step trail note (the
// recorder is already deadline-ready — the `preempted` status exists), so a
// force-yielded run lands on `recent_runs` like any other.
//
// ── What C.36 owns vs. does NOT own ─────────────────────────────────
//
// C.36 owns the *mechanism*: arming a wall-clock timer for a step, racing
// the step's future against it ([guard]), and reporting which side won
// ([StepOutcome]). It does NOT own *driving* the foreground/background
// coordinator — setting the foreground-waiting flag on arrival, signalling
// resume on completion — which belongs to the Phase D dispatcher's
// `RunCoordinator` / `PreemptionController` (spec § 10.3; build order
// D.23–D.25). The deadline and the cooperative `PreemptionState` (C.34) are
// independent levers on the same subsystem: the state bounds the wait to one
// step *cooperatively*; the deadline bounds the step itself *hard*. Mapping a
// `StepTruncated` outcome onto a `RunCompletion(status: preempted, …)` plus
// the truncated-step note is the engine step-runner's job (C.38) — C.36
// supplies the outcome and the well-known note category, not the recorder
// wiring.

import 'dart:async';

/// The default hard cap on a single background step (definition § 7.1:
/// "configurable; default 60 s wall clock"). The configurable override
/// lands with `EngineConfig` (C.42); until then this is the floor every
/// `StepDeadline` uses unless a caller passes an explicit `limit`.
const Duration defaultStepDeadline = Duration(seconds: 60);

/// The trail-note category a truncated step is recorded under.
///
/// When the deadline force-yields a step, the engine step-runner (C.38)
/// appends a `note` in this category to the run's trail so an operator (and
/// the dispatcher's harvester) can see the run was cut short rather than
/// finishing on its own. Kept here, next to the mechanism that detects the
/// truncation, so the producer and the category name cannot drift apart.
const String stepTruncatedNoteCategory = 'step_truncated';

/// The seam through which [StepDeadline] schedules its wall-clock timer.
///
/// Defaults to `Timer.new` in production. Injectable so a test can drive the
/// deadline deterministically — capturing the callback and firing it on
/// demand — without sleeping for the real limit. Mirrors the injectable
/// clock the run recorder (C.31) takes for the same reason.
typedef DeadlineTimerFactory = Timer Function(
  Duration duration,
  void Function() onExpire,
);

/// Which side of the deadline race won, for a step guarded by [StepDeadline].
///
/// A sealed pair so a caller must handle both outcomes: the step finished in
/// time ([StepCompleted], carrying its value) or the deadline fired first
/// ([StepTruncated], carrying the limit it breached).
sealed class StepOutcome<T> {
  const StepOutcome();
}

/// The step finished before the deadline; [value] is its result.
final class StepCompleted<T> extends StepOutcome<T> {
  /// Wraps the step's [value].
  const StepCompleted(this.value);

  /// The value the guarded step produced.
  final T value;
}

/// The deadline fired before the step finished; the step was force-yielded.
///
/// [limit] is the wall-clock cap that was breached. The engine step-runner
/// (C.38) maps this onto a `RunCompletion(status: preempted, …)` plus a
/// [stepTruncatedNoteCategory] trail note.
final class StepTruncated<T> extends StepOutcome<T> {
  /// Records the breached [limit].
  const StepTruncated(this.limit);

  /// The wall-clock cap the step exceeded.
  final Duration limit;
}

/// A single-use, per-step hard wall-clock cap.
///
/// One instance guards exactly one step: [start] arms the timer, [guard]
/// races a step future against it, and [cancel] disarms a still-running
/// timer when the step finished in time. To guard the next step, build a
/// fresh `StepDeadline` — the same discipline the engine uses for the
/// per-run [run recorder]. The cap defaults to [defaultStepDeadline]; pass
/// [limit] to override (the configurable path `EngineConfig`, C.42, feeds).
final class StepDeadline {
  /// Builds a deadline with the given [limit] (default [defaultStepDeadline])
  /// over the injectable [timerFactory] (default `Timer.new`).
  ///
  /// Throws [ArgumentError] when [limit] is not strictly positive — a
  /// zero-or-negative cap would force-yield every step before it could run.
  StepDeadline({
    this.limit = defaultStepDeadline,
    DeadlineTimerFactory? timerFactory,
  }) : _timerFactory = timerFactory ?? Timer.new {
    if (limit <= Duration.zero) {
      throw ArgumentError.value(
        limit,
        'limit',
        'a step deadline must be strictly positive',
      );
    }
  }

  /// The hard wall-clock cap on the guarded step.
  final Duration limit;

  final DeadlineTimerFactory _timerFactory;

  Timer? _timer;
  bool _armed = false;
  bool _expired = false;
  final Completer<void> _expiry = Completer<void>();

  /// Whether the timer is currently counting down (armed, not yet fired,
  /// not yet cancelled).
  bool get isArmed => _armed && !_expired && _timer != null;

  /// Whether the deadline has fired (the step was force-yielded).
  bool get isExpired => _expired;

  /// Completes when the deadline fires. Never completes if the step finishes
  /// in time and [cancel] disarms the timer first.
  Future<void> get expired => _expiry.future;

  /// Arms the wall-clock timer for [limit].
  ///
  /// Throws [StateError] if called twice — a `StepDeadline` guards exactly
  /// one step.
  void start() {
    if (_armed) {
      throw StateError('StepDeadline.start called twice for the same step.');
    }
    _armed = true;
    _timer = _timerFactory(limit, _fire);
  }

  /// Disarms a still-running timer because the step finished in time.
  ///
  /// Idempotent and safe after expiry (a fired timer is already gone). After
  /// [cancel] the deadline can no longer fire.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Arms the deadline, races [step] against it, and reports the winner.
  ///
  /// Returns [StepCompleted] with the step's value when it finishes within
  /// [limit] (the timer is cancelled), or [StepTruncated] when the deadline
  /// fires first. If [step] throws before the deadline, the error propagates
  /// (the timer is cancelled). A step that loses the race is abandoned, not
  /// cancelled: its future may still complete later, but its result and any
  /// late error are dropped (a `Future` is not cancellable — see the header).
  Future<StepOutcome<T>> guard<T>(Future<T> step) {
    start();
    final result = Completer<StepOutcome<T>>();

    unawaited(
      step.then(
        (T value) {
          if (result.isCompleted) {
            return;
          }
          cancel();
          result.complete(StepCompleted<T>(value));
        },
        onError: (Object error, StackTrace stack) {
          if (result.isCompleted) {
            // Deadline already won; the late error is dropped on purpose
            // (the run was closed as truncated). Swallowing it here keeps it
            // from surfacing as an unhandled async error.
            return;
          }
          cancel();
          result.completeError(error, stack);
        },
      ),
    );

    unawaited(
      expired.then((_) {
        if (result.isCompleted) {
          return;
        }
        result.complete(StepTruncated<T>(limit));
      }),
    );

    return result.future;
  }

  void _fire() {
    if (_expired) {
      return;
    }
    _expired = true;
    _timer = null;
    if (!_expiry.isCompleted) {
      _expiry.complete();
    }
  }
}
