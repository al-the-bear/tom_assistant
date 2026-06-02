// Foreground / background run coordinator (Plan steps D.18, D.19;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// The fourth stage of the dispatcher's `accept → classify → select →
// schedule` pipeline: the *schedule* stage. Selection (D.16) resolves a
// procedure id; the coordinator owns *which* runs are allowed to be live at
// once and *when* a submitted run actually executes.
//
// ── What D.18 owns ──────────────────────────────────────────────────
//
// D.18 delivers the coordinator core — the single-foreground /
// single-background *invariant* and the submission surface:
//
//   - At most one foreground run at a time (foreground = an inbound user
//     prompt being served).
//   - At most one background run at a time (background = scheduler-driven
//     free-time work).
//   - The shared [PreemptionState] the engine yields against, owned here so
//     the coordinator and the engine reference one object.
//
// ── What D.19 adds ──────────────────────────────────────────────────
//
// D.19 fills the FIFO foreground queue *behind* the same
// [submitForeground] signature. When the foreground slot is busy a
// submission no longer fails loudly — it is enqueued (configurable depth,
// default 4) and started, in submission order, as soon as the running
// foreground frees the slot. Only when the queue is *also* at capacity does
// a foreground submission fail, and then with [ForegroundQueueFull] (an
// overflow / backpressure signal), not [RunSlotBusy]. Per the
// no-backwards-compatibility principle the old busy-foreground rejection is
// swapped wholesale, not kept as a fallback.
//
// The background slot stays single — there is no background queue, so a
// second concurrent background submission still fails loudly with
// [RunSlotBusy].
//
// ── What D.20 adds ──────────────────────────────────────────────────
//
// D.20 makes the coordinator *drive* the shared [PreemptionState] it has
// owned since D.18. The engine reads that state through
// `yield_if_foreground_waiting()`; D.20 supplies the write side, so a
// foreground arrival actually causes a live background run to step aside:
//
//   - When a foreground submission is *admitted* (started immediately or
//     enqueued) while a background run is live, the coordinator calls
//     [PreemptionState.requestForegroundPreemption]. The background run
//     parks at its *next* cooperative checkpoint — never mid-step.
//   - When the foreground workload fully drains (the slot is free *and* the
//     FIFO queue is empty), the coordinator calls
//     [PreemptionState.signalResume], releasing any parked background run.
//
// Both writes are idempotent (a redundant request keeps the existing resume
// signal; a resume with nothing pending is a no-op), so back-to-back
// foreground arrivals during one background run resume the background
// exactly once, when the *whole* foreground chain has drained. A foreground
// submission that *overflows* the queue ([ForegroundQueueFull]) is not
// admitted and therefore does not drive preemption.
//
// ── What D.21 adds ──────────────────────────────────────────────────
//
// D.21 makes the coordinator enforce a *hard step deadline* as an
// independent cross-check of the engine's own per-step deadline (C.36,
// `preemption/step_deadline.dart`). Every admitted run body — foreground or
// background — is raced against a coordinator-owned [StepDeadline] using the
// same mechanism the engine uses internally. The two deadlines are
// defence-in-depth on the same wall clock:
//
//   - The engine's [StepDeadline] (default 60 s) fires *inside* the run body
//     and closes the run cleanly as truncated; from the coordinator's vantage
//     the body simply *completes*, so the coordinator's timer is cancelled and
//     never fires. This is the normal path.
//   - The coordinator's deadline fires only when the run body does *not*
//     complete within the limit — i.e. the engine's deadline failed to bound
//     the run at all (a genuinely hung body, a run that bypassed the engine,
//     or a misconfigured engine deadline). The coordinator then *force-yields*
//     the run: it frees the slot, pumps the foreground queue / resumes a
//     parked background, and surfaces [RunDeadlineExceeded]
//     (`procedure.deadline.exceeded`, spec § 14) to the caller. The abandoned
//     body may still run to completion untracked — a `Future` is not
//     cancellable — but its result and any late error are dropped.
//
// To keep the cross-check a *backstop* rather than a competitor, the
// coordinator's default limit is the engine's default plus a grace margin
// ([defaultCoordinatorDeadlineGrace]), so under normal operation the engine's
// in-band truncation always wins the race.
//
// ── What D.24 adds ──────────────────────────────────────────────────
//
// D.24 wires the supervising [PreemptionController] (D.23) into the
// coordinator's existing transition points, so the controller's
// `PreemptionEvent` stream reflects the live coordinator without the
// controller ever becoming a second writer of [PreemptionState]:
//
//   - When a body actually starts in a slot, the coordinator calls
//     [PreemptionController.recordRunStarted] — never for a rejected
//     submission ([RunSlotBusy], [ForegroundQueueFull]) nor while a
//     foreground submission still waits in the FIFO queue.
//   - When a body finishes, the coordinator calls
//     [PreemptionController.recordRunFinished] with the mapped
//     [RunSlotOutcome]: a clean return is `completed`, a thrown error is
//     `failed`, and a hard-step-deadline force-yield (the [StepTruncated]
//     outcome surfacing [RunDeadlineExceeded]) is `forceYielded`.
//   - Each [PreemptionState.requestForegroundPreemption] is mirrored by
//     [PreemptionController.recordForegroundPreemptionRequested]; each
//     [PreemptionState.signalResume] by
//     [PreemptionController.recordBackgroundResumeSignalled]. The controller
//     mirrors `PreemptionState`'s idempotency on its *own* model, so the
//     event stream carries one event per true edge even though the
//     coordinator calls these more than once per real transition.
//
// The controller is constructor-injectable (default: a fresh one) so a
// consumer can supply the same controller it exposes elsewhere; the
// coordinator surfaces its event stream through [preemptionEvents] so the
// dispatcher API (this module's barrel) exposes preemption observability
// without the consumer reaching into the coordinator's internals.
//
// ── What the coordinator does NOT own yet (deferred) ────────────────
//
// The remaining D.5/D.6 substeps plug into this core without changing its
// submission signatures:
//
//   - D.25 — the full event-transition suite driven end-to-end through the
//     wired coordinator (D.24 ships its own wiring tests; D.25 is the
//     exhaustive transition matrix).
//   - D.26 — run ids assigned to scheduled bodies, threaded through the
//     controller's `record*` `runId` argument.

import 'dart:async';
import 'dart:collection';

import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

import '../preemption/step_deadline.dart'
    show
        DeadlineTimerFactory,
        StepCompleted,
        StepDeadline,
        StepOutcome,
        StepTruncated,
        defaultStepDeadline;
import 'preemption_controller.dart' show PreemptionController;
import 'preemption_event.dart' show PreemptionEvent, RunSlotOutcome;

/// The two run slots the coordinator tracks (PE-5).
///
/// Exactly one run may occupy each slot at a time. `foreground` serves an
/// inbound user prompt; `background` serves scheduler-driven free-time work.
enum RunSlot {
  /// An inbound user prompt being served. At most one is live at a time.
  foreground,

  /// Scheduler-driven free-time work (dreaming, research, triage,
  /// authoring). At most one is live at a time.
  background,
}

/// The unit of work the coordinator schedules into a slot.
///
/// A run body is a thunk that, when invoked, performs the run and completes
/// with its result. The coordinator owns *when* the body runs and clearing
/// the slot when it finishes; the body owns *what* the run does (in
/// production, driving the [procedure engine]). Generic in the result type
/// so a caller awaits the run's own value, not an erased one.
typedef RunBody<T> = Future<T> Function();

/// Raised when a run is submitted into a slot that already holds a live run
/// *and* that slot has no queue to absorb it.
///
/// Since D.19 this applies to the **background** slot only: there is no
/// background queue, so a second concurrent background submission fails
/// loudly rather than running two background runs at once. The foreground
/// slot no longer raises this — a busy foreground slot enqueues the
/// submission (and signals [ForegroundQueueFull] only on overflow).
final class RunSlotBusy implements Exception {
  /// Records which [slot] was already occupied when a run was submitted.
  const RunSlotBusy(this.slot);

  /// The slot that already held a live run.
  final RunSlot slot;

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'the ${slot.name} slot already holds a live run; '
      'the coordinator allows at most one ${slot.name} run at a time';

  @override
  String toString() => 'RunSlotBusy: $message';
}

/// Raised when a foreground submission arrives while the foreground slot is
/// busy *and* the FIFO foreground queue is already at capacity (D.19).
///
/// This is the queue's backpressure / overflow signal: the running
/// foreground run plus [depth] queued runs are the most the coordinator will
/// hold. A caller that hits this should shed load (reject the inbound, ask
/// the user to retry) rather than grow the queue unbounded. The background
/// slot has no queue and so signals [RunSlotBusy] instead, never this.
final class ForegroundQueueFull implements Exception {
  /// Records the foreground queue [depth] that was already full when the
  /// rejected submission arrived.
  const ForegroundQueueFull(this.depth);

  /// The configured foreground queue depth (max waiting runs) at the time
  /// of rejection.
  final int depth;

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'the foreground queue is full (depth $depth); the running foreground '
      'run plus $depth queued runs are the most the coordinator holds';

  @override
  String toString() => 'ForegroundQueueFull: $message';
}

/// The grace the coordinator's hard-step-deadline cross-check (D.21) adds
/// over the engine's own per-step deadline ([defaultStepDeadline], C.36).
///
/// The coordinator's default limit is the engine's default *plus* this grace,
/// so the engine's in-band truncation closes a runaway run first under normal
/// operation and the coordinator's harder abort fires only when the engine
/// failed to bound the run at all. Keeping the cross-check strictly more
/// lenient than the thing it checks is what makes it a backstop rather than a
/// competitor.
const Duration defaultCoordinatorDeadlineGrace = Duration(seconds: 5);

/// Raised through a submission's future when the coordinator's hard step
/// deadline (D.21) force-yields a run whose body did not complete in time.
///
/// This is the coordinator-level half of the spec's `procedure.deadline.exceeded`
/// failure (§ 14: detected by "Coordinator + engine wall clock"). It surfaces
/// only when the engine's own [StepDeadline] failed to bound the run — under
/// normal operation the engine truncates the run *inside* the body, the body
/// completes, and this is never thrown. [failureKind] carries the typed class
/// so the Phase D fallback executor (D.29) can classify it.
final class RunDeadlineExceeded implements Exception {
  /// Records which [slot] held the run that breached the [limit].
  const RunDeadlineExceeded(this.slot, this.limit);

  /// The slot whose run was force-yielded by the coordinator deadline.
  final RunSlot slot;

  /// The coordinator's hard step deadline the run exceeded.
  final Duration limit;

  /// The typed failure class this surfaces (spec § 14), so a fallback
  /// executor can classify it without string-matching the message.
  String get failureKind => 'procedure.deadline.exceeded';

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'the ${slot.name} run exceeded the coordinator hard step deadline '
      '(${limit.inMilliseconds} ms) and was force-yielded';

  @override
  String toString() => 'RunDeadlineExceeded: $message';
}

/// The dispatcher's foreground / background run coordinator (Plan D.18;
/// spec § 10.3, PE-5).
///
/// Tracks at most one foreground and one background run, exposes
/// [submitForeground] / [submitBackground], and owns the shared
/// [preemption] state the engine yields against. A submitted run occupies
/// its slot from submission until its body completes (success *or* error);
/// the slot is cleared before the returned future resolves, so a caller that
/// awaits a submission observes the slot already free.
final class RunCoordinator {
  /// Builds a coordinator over a [preemption] state (default: a fresh
  /// [PreemptionState]) with a FIFO foreground queue of
  /// [foregroundQueueDepth] waiting runs (default 4).
  ///
  /// The preemption state is injectable so the engine and the coordinator can
  /// be handed the *same* object — the coordinator drives the write side
  /// (from D.20), the engine's `yield_if_foreground_waiting()` checkpoint
  /// reads it.
  ///
  /// [foregroundQueueDepth] is the maximum number of foreground runs that may
  /// *wait* behind the running one; it excludes the run currently occupying
  /// the slot. A depth of 0 disables queueing entirely (a busy foreground
  /// slot then overflows immediately). Throws [ArgumentError] if negative.
  ///
  /// [hardStepDeadline] is the coordinator-level cross-check of the engine's
  /// per-step deadline (D.21). Every admitted run body is raced against it;
  /// a body that does not complete in time is force-yielded and its
  /// submission future fails with [RunDeadlineExceeded]. Defaults to the
  /// engine's [defaultStepDeadline] plus [defaultCoordinatorDeadlineGrace] so
  /// the engine's in-band truncation wins under normal operation. Throws
  /// [ArgumentError] if not strictly positive.
  ///
  /// [deadlineTimerFactory] is the injectable timer seam the cross-check uses
  /// (default `Timer.new`), so a test can fire the deadline deterministically
  /// without sleeping for the real limit — mirroring the engine's
  /// [StepDeadline] seam.
  ///
  /// [preemptionController] is the supervising observer the coordinator drives
  /// at each transition point (D.24). It is injectable (default: a fresh
  /// [PreemptionController]) so a consumer can hand the coordinator the same
  /// controller it exposes elsewhere — e.g. to a Tom Forge run inspector.
  /// The coordinator is observe-only towards it: it calls the `record*`
  /// surface but never reads it back, and the controller never writes
  /// [preemption]. When the controller is injected, its [close] lifecycle is
  /// the consumer's; the default-constructed one lives with the coordinator.
  RunCoordinator({
    PreemptionState? preemption,
    PreemptionController? preemptionController,
    this.foregroundQueueDepth = 4,
    Duration? hardStepDeadline,
    DeadlineTimerFactory? deadlineTimerFactory,
  })  : preemption = preemption ?? PreemptionState(),
        preemptionController = preemptionController ?? PreemptionController(),
        hardStepDeadline = hardStepDeadline ??
            (defaultStepDeadline + defaultCoordinatorDeadlineGrace),
        _deadlineTimerFactory = deadlineTimerFactory {
    if (foregroundQueueDepth < 0) {
      throw ArgumentError.value(
        foregroundQueueDepth,
        'foregroundQueueDepth',
        'must be zero or greater',
      );
    }
    if (this.hardStepDeadline <= Duration.zero) {
      throw ArgumentError.value(
        this.hardStepDeadline,
        'hardStepDeadline',
        'a coordinator hard step deadline must be strictly positive',
      );
    }
  }

  /// The shared cooperative-preemption state the engine yields against.
  ///
  /// D.18 exposes it; D.20 drives it: the foreground-waiting flag is set
  /// (via [PreemptionState.requestForegroundPreemption]) when a foreground
  /// submission is admitted while a background run is live, and resume is
  /// signalled (via [PreemptionState.signalResume]) once the foreground
  /// workload fully drains.
  final PreemptionState preemption;

  /// The supervising observer the coordinator drives at each transition point
  /// (D.24): run start / finish, foreground-preemption request, and resume
  /// signal. Observe-only — the coordinator calls its `record*` surface but
  /// never reads it back, and the controller never writes [preemption].
  /// Consumers subscribe through [preemptionEvents].
  final PreemptionController preemptionController;

  /// The maximum number of foreground runs that may wait behind the running
  /// one in the FIFO queue (excludes the run occupying the slot, D.19).
  final int foregroundQueueDepth;

  /// The coordinator-level hard step deadline (D.21): every admitted run body
  /// is raced against this wall-clock cap as an independent cross-check of the
  /// engine's own per-step deadline. A body that does not complete in time is
  /// force-yielded with [RunDeadlineExceeded]. Defaults to the engine's
  /// [defaultStepDeadline] plus [defaultCoordinatorDeadlineGrace].
  final Duration hardStepDeadline;

  /// The injectable timer seam each per-run [StepDeadline] cross-check uses
  /// (null ⇒ `Timer.new`). Kept for the cross-check's whole lifetime because a
  /// fresh `StepDeadline` is built per submitted run.
  final DeadlineTimerFactory? _deadlineTimerFactory;

  /// FIFO queue of foreground starters waiting for the slot to free up. Each
  /// starter, when invoked, re-occupies the foreground slot and runs its body
  /// (completing the original caller's future). Bounded by
  /// [foregroundQueueDepth]; overflow raises [ForegroundQueueFull].
  final Queue<void Function()> _foregroundQueue = Queue<void Function()>();

  Future<void>? _foreground;
  Future<void>? _background;

  /// Whether a foreground run is currently live (occupying the slot).
  bool get hasForegroundRun => _foreground != null;

  /// Whether a background run is currently live.
  bool get hasBackgroundRun => _background != null;

  /// The number of foreground runs currently waiting in the FIFO queue
  /// (excludes the run occupying the slot, D.19).
  int get foregroundQueueLength => _foregroundQueue.length;

  /// The supervising [PreemptionController]'s typed event stream (D.24).
  ///
  /// A convenience over `preemptionController.events()`, exposed so the
  /// dispatcher API can surface preemption observability without a consumer
  /// reaching into the coordinator's internals. Broadcast: multiple
  /// subscribers each see every transition; missed events stay missed.
  Stream<PreemptionEvent> preemptionEvents() => preemptionController.events();

  /// Submits [body] as a foreground run (D.18 surface, D.19 queue).
  ///
  /// If the foreground slot is free the body starts immediately. If it is
  /// busy the submission is enqueued FIFO and started, in submission order,
  /// as soon as the running foreground frees the slot. Throws
  /// [ForegroundQueueFull] synchronously only when the slot is busy *and* the
  /// queue is already at [foregroundQueueDepth]. The returned future carries
  /// the body's own result (or error) whenever the run eventually executes.
  Future<T> submitForeground<T>(RunBody<T> body) {
    final completer = Completer<T>();
    void start() => _runInForegroundSlot(body, completer);

    if (_foreground == null) {
      // Slot free: start immediately.
      start();
    } else if (_foregroundQueue.length >= foregroundQueueDepth) {
      // Slot busy and the queue is full: overflow. Not admitted, so it does
      // not drive preemption.
      throw ForegroundQueueFull(foregroundQueueDepth);
    } else {
      // Slot busy with queue capacity: wait FIFO behind the running run.
      _foregroundQueue.add(start);
    }
    // The submission is admitted (started or queued). If a background run is
    // live, ask it to yield at its next cooperative checkpoint (D.20). The
    // request is idempotent, so a second foreground arrival during the same
    // background run keeps the existing resume signal.
    if (_background != null) {
      preemption.requestForegroundPreemption();
      // Mirror the write onto the supervising observer (D.24). Idempotent on
      // the controller's own model, so back-to-back foreground arrivals during
      // one background run emit exactly one ForegroundPreemptionRequested.
      preemptionController.recordForegroundPreemptionRequested();
    }
    return completer.future;
  }

  /// Submits [body] as the background run.
  ///
  /// Throws [RunSlotBusy] synchronously if a background run is already live —
  /// there is no background queue. Otherwise the body starts immediately, the
  /// background slot is marked occupied until the body completes, and the
  /// returned future carries the body's own result (or error).
  Future<T> submitBackground<T>(RunBody<T> body) {
    if (_background != null) {
      throw const RunSlotBusy(RunSlot.background);
    }
    final completer = Completer<T>();
    final marker = Completer<void>();
    // Mark the slot occupied *before* invoking the body, so a re-entrant
    // submission from inside the body sees the slot busy rather than racing.
    _background = marker.future;
    preemptionController.recordRunStarted(RunSlot.background);
    _guardWithDeadline(body).then(
      (outcome) {
        _background = null;
        marker.complete();
        preemptionController.recordRunFinished(
          RunSlot.background,
          _slotOutcomeOf(outcome),
        );
        _completeFromOutcome(completer, outcome, RunSlot.background);
      },
      onError: (Object error, StackTrace stackTrace) {
        _background = null;
        marker.complete();
        preemptionController.recordRunFinished(
          RunSlot.background,
          RunSlotOutcome.failed,
        );
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
  }

  /// Occupies the foreground slot with [body], completing [completer] with
  /// the body's result, then pumps the next queued foreground run (if any).
  void _runInForegroundSlot<T>(RunBody<T> body, Completer<T> completer) {
    final marker = Completer<void>();
    _foreground = marker.future;
    preemptionController.recordRunStarted(RunSlot.foreground);
    _guardWithDeadline(body).then(
      (outcome) {
        _foreground = null;
        marker.complete();
        // Emit the exit *before* pumping the queue, so a queued successor's
        // RunSlotEntered follows this run's RunSlotExited in the stream.
        preemptionController.recordRunFinished(
          RunSlot.foreground,
          _slotOutcomeOf(outcome),
        );
        _completeFromOutcome(completer, outcome, RunSlot.foreground);
        _pumpForegroundQueue();
        _resumeBackgroundIfForegroundDrained();
      },
      onError: (Object error, StackTrace stackTrace) {
        _foreground = null;
        marker.complete();
        preemptionController.recordRunFinished(
          RunSlot.foreground,
          RunSlotOutcome.failed,
        );
        completer.completeError(error, stackTrace);
        _pumpForegroundQueue();
        _resumeBackgroundIfForegroundDrained();
      },
    );
  }

  /// Races [body] against a fresh per-run [StepDeadline] (D.21).
  ///
  /// Reuses the engine's deadline mechanism (C.36) so the coordinator's
  /// cross-check and the engine's own per-step guard share one implementation.
  /// The returned future resolves to a [StepCompleted] when the body finishes
  /// within [hardStepDeadline] (the timer is cancelled) or a [StepTruncated]
  /// when the deadline fires first; it propagates the body's error unchanged
  /// when the body throws before the deadline.
  Future<StepOutcome<T>> _guardWithDeadline<T>(RunBody<T> body) {
    final deadline = StepDeadline(
      limit: hardStepDeadline,
      timerFactory: _deadlineTimerFactory,
    );
    return deadline.guard<T>(Future<T>.sync(body));
  }

  /// Completes [completer] from a [StepDeadline] [outcome] (D.21): the body's
  /// value on [StepCompleted], or a [RunDeadlineExceeded] failure naming the
  /// [slot] on [StepTruncated].
  void _completeFromOutcome<T>(
    Completer<T> completer,
    StepOutcome<T> outcome,
    RunSlot slot,
  ) {
    switch (outcome) {
      case StepCompleted<T>(:final value):
        completer.complete(value);
      case StepTruncated<T>(:final limit):
        completer.completeError(
          RunDeadlineExceeded(slot, limit),
          StackTrace.current,
        );
    }
  }

  /// Starts the next waiting foreground run, re-occupying the freed slot.
  ///
  /// Runs synchronously on the just-freed slot, so the slot moves directly
  /// from the finished run to the next queued one within a single event-loop
  /// turn — a queued run never observes a gap where the slot is free but a
  /// successor is waiting.
  void _pumpForegroundQueue() {
    if (_foreground != null || _foregroundQueue.isEmpty) {
      return;
    }
    _foregroundQueue.removeFirst()();
  }

  /// Releases a parked background run once the foreground workload has fully
  /// drained — the slot is free *and* the FIFO queue is empty (D.20).
  ///
  /// Called after a foreground run completes and the queue has been pumped:
  /// if the pump started a queued successor the slot is busy again and this
  /// is a no-op (the background stays preempted until the *whole* foreground
  /// chain drains). [PreemptionState.signalResume] is itself idempotent, so a
  /// call with no preemption pending (no background was ever asked to yield)
  /// is harmless.
  void _resumeBackgroundIfForegroundDrained() {
    if (_foreground == null && _foregroundQueue.isEmpty) {
      preemption.signalResume();
      // Mirror the write onto the supervising observer (D.24). Idempotent on
      // the controller's own model, so a resume with nothing pending (no
      // background was ever asked to yield) emits nothing.
      preemptionController.recordBackgroundResumeSignalled();
    }
  }

  /// Maps a [StepDeadline] [outcome] to the [RunSlotOutcome] the controller
  /// records (D.24): a body that finished within the limit is
  /// [RunSlotOutcome.completed]; one the coordinator's hard step deadline
  /// truncated is [RunSlotOutcome.forceYielded]. A body that *threw* never
  /// reaches here — that path records [RunSlotOutcome.failed] directly.
  RunSlotOutcome _slotOutcomeOf<T>(StepOutcome<T> outcome) => switch (outcome) {
        StepCompleted<T>() => RunSlotOutcome.completed,
        StepTruncated<T>() => RunSlotOutcome.forceYielded,
      };
}
