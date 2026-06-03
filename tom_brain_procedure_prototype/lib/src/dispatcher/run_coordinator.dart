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
// ── What D.26 adds ──────────────────────────────────────────────────
//
// D.26 gives the coordinator two new responsibilities the preceding steps
// flagged as deferred:
//
//   - **Run ids.** Every run is assigned an id the moment it occupies a slot
//     (an injectable [RunIdMint], default a monotonic per-coordinator
//     counter). The id is threaded into the controller's `recordRunStarted` /
//     `recordRunFinished` calls, so the `PreemptionEvent` slot enter/exit
//     events now carry a non-null `runId`. (The preemption-request / resume
//     events stay id-less — they are about a *transition* of the shared state,
//     not a single run.)
//   - **`inflight` integration (PE-4 dispatcher half).** When a [runRegistry]
//     is wired and a submission named the [procedureId] it executes, the
//     coordinator pushes a `status: running` `ProcedureRun` marker onto the
//     `inflight` bootstrap stack the moment the run occupies its slot. The
//     push is fired without blocking the body, preserving the coordinator's
//     synchronous admission semantics.
//
// ── What D.27 adds ──────────────────────────────────────────────────
//
// D.27 closes the loop the D.26 `inflight` push opened: the run-end half of
// the PE-4 dispatcher tracking.
//
//   - The coordinator holds the per-slot `inflight` handle D.26 created (the
//     `Future<NodeId>` marker plus the [RunRegistration] facts). When a run
//     ends — success, failure, *or* a hard-step-deadline force-yield — the
//     coordinator awaits that handle and calls [RunRegistry.recordEnd], which
//     removes the running marker from `inflight` and pushes a terminal
//     `ProcedureRun` marker (`status: completed` / `failed` / `force_yielded`)
//     onto `recent_runs`.
//   - The run-end write, like the start write, is fired without blocking the
//     completion path so the coordinator's slot-freeing timing is unchanged.
//     The held handle is cleared the moment the run ends, so the coordinator
//     never carries dead state for a finished run.
//
// ── What D.28 locks ─────────────────────────────────────────────────
//
// D.28 is a tests-only step (`test/d28_stack_state_runtime_test.dart`): no
// coordinator change. It pins the PE-4 dispatcher-half lifecycle by asserting
// the live *membership* of the `inflight` / `recent_runs` bootstrap stacks —
// `inflight` reflects exactly the runs the coordinator currently has live,
// `recent_runs` accumulates exactly the finished ones, and concurrent
// foreground + background appears as two distinct `inflight` entries that each
// migrate to a distinct `recent_runs` node.
//
// ── What D.45 adds ──────────────────────────────────────────────────
//
// D.45 gives the coordinator the *drain* half of the prototype's shutdown
// orchestration (`BrainProcessBoot` / `BootedBrain.shutdown`). A graceful
// shutdown must let the work the coordinator already admitted reach its
// natural end — so the in-flight run's `RunRecorder` calls `complete()` and
// closes its trail durably — before memory is flushed and the isolate is
// closed. [drain] is that quiesce step:
//
//   - It flips [isDraining] on, so any *new* [submitForeground] /
//     [submitBackground] is refused with [CoordinatorDraining] rather than
//     admitted. This is what lets the drain terminate: once the access layer
//     is torn down (no new inbound) and the coordinator refuses fresh work,
//     the live foreground chain (the running run plus everything already in
//     the FIFO queue) and any live background run can only shrink.
//   - It then *best-effort* waits for the coordinator to fall fully idle —
//     the foreground slot free, the FIFO queue empty, and the background slot
//     free. "Best-effort" is bounded by an optional [Duration] timeout: a run
//     body that will not finish in time (the same genuinely-hung body the D.21
//     hard-step-deadline guards) does not hold shutdown hostage. When the
//     timeout elapses the drain returns; the abandoned body may still run to
//     completion untracked, exactly as a force-yield leaves it.
//
// The drain owns *quiescing the coordinator*; closing memory (which flushes
// writes + checkpoints the WAL) and the substrate stays
// [BootedBrain.shutdown]'s job, layered on top of a drained coordinator.

import 'dart:async';
import 'dart:collection';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, PreemptionState;

import '../preemption/step_deadline.dart'
    show
        DeadlineTimerFactory,
        StepCompleted,
        StepDeadline,
        StepOutcome,
        StepTruncated,
        defaultStepDeadline;
import 'fallback_executor.dart' show ClassifiedFailure;
import 'preemption_controller.dart' show PreemptionController;
import 'preemption_event.dart' show PreemptionEvent, RunSlotOutcome;
import 'run_registry.dart' show RunOutcome, RunRegistration, RunRegistry;

/// Mints a run id for a freshly-started run in [slot] (D.26).
///
/// Injectable so a deployment (or a test) can supply UUIDs or a
/// deterministic sequence; the coordinator's default is a monotonic
/// per-coordinator counter.
typedef RunIdMint = String Function(RunSlot slot);

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

/// The coordinator's default hard step deadline (D.21): the engine's per-step
/// deadline ([defaultStepDeadline], 60 s) plus the backstop
/// [defaultCoordinatorDeadlineGrace] (5 s) = 65 s.
///
/// Named (rather than inlined at the constructor default) so the shutdown drain
/// timeout can be tied to it (F.5.2 — `defaultShutdownDrainTimeout`) instead of
/// the two living as wholly-unrelated literals: the drain must outlast this
/// deadline so the normal bound on a run is the coordinator force-yield, not the
/// drain.
///
/// Why a literal, not `defaultStepDeadline + defaultCoordinatorDeadlineGrace`:
/// Dart `const` evaluation forbids arithmetic on `Duration` (only `num` /
/// `String` operands are allowed), and this value must stay `const` because it
/// feeds the `const` default of [defaultShutdownDrainTimeout]
/// (`BootedBrain.shutdown`'s `drainTimeout` parameter). The derivation is
/// therefore *asserted* by `test/f_dispatcher_cleanup_test.dart` — change either
/// component and that test fails — so the literal cannot silently drift from its
/// two summands.
const Duration defaultCoordinatorHardStepDeadline = Duration(seconds: 65);

/// Raised through a submission's future when the coordinator's hard step
/// deadline (D.21) force-yields a run whose body did not complete in time.
///
/// This is the coordinator-level half of the spec's `procedure.deadline.exceeded`
/// failure (§ 14: detected by "Coordinator + engine wall clock"). It surfaces
/// only when the engine's own [StepDeadline] failed to bound the run — under
/// normal operation the engine truncates the run *inside* the body, the body
/// completes, and this is never thrown. [failureKind] carries the typed class
/// (via [ClassifiedFailure]) so the Phase D [FallbackExecutor] (D.29)
/// classifies it as `procedure.deadline.exceeded` and steps the version chain.
final class RunDeadlineExceeded implements Exception, ClassifiedFailure {
  /// Records which [slot] held the run that breached the [limit].
  const RunDeadlineExceeded(this.slot, this.limit);

  /// The slot whose run was force-yielded by the coordinator deadline.
  final RunSlot slot;

  /// The coordinator's hard step deadline the run exceeded.
  final Duration limit;

  /// The typed failure class this surfaces (spec § 14), so the
  /// [FallbackExecutor] can classify it without string-matching the message.
  @override
  String get failureKind => 'procedure.deadline.exceeded';

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'the ${slot.name} run exceeded the coordinator hard step deadline '
      '(${limit.inMilliseconds} ms) and was force-yielded';

  @override
  String toString() => 'RunDeadlineExceeded: $message';
}

/// Raised when a run is submitted to a coordinator that is draining for
/// shutdown (D.45).
///
/// Once [RunCoordinator.drain] has begun, the coordinator admits no new work
/// — that refusal is what lets the in-flight foreground chain and any live
/// background run wind down to idle. A submission that arrives during the
/// drain (a late inbound that slipped past the access-layer teardown, a
/// scheduler tick that has not yet been stopped) fails loudly with this rather
/// than being admitted into a coordinator that is being torn down.
final class CoordinatorDraining implements Exception {
  /// Records the [slot] a run was submitted to while the coordinator was
  /// draining.
  const CoordinatorDraining(this.slot);

  /// The slot the refused submission targeted.
  final RunSlot slot;

  /// Human-readable explanation, reused by [toString].
  String get message =>
      'the coordinator is draining for shutdown and admits no new '
      '${slot.name} runs';

  @override
  String toString() => 'CoordinatorDraining: $message';
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
  ///
  /// [runRegistry] is the dispatcher-half `inflight` tracker (D.26). When
  /// supplied, every run the coordinator starts in a slot is pushed onto the
  /// `inflight` bootstrap stack as a `status: running` `ProcedureRun` marker
  /// via the memory client. When omitted (the default) the coordinator runs
  /// without memory-side run tracking — the posture every coordinator test
  /// before D.26 uses.
  ///
  /// [runIdMint] assigns a run id to each freshly-started run (D.26),
  /// threaded into the [PreemptionController] record calls and the
  /// [runRegistry] push. Defaults to a monotonic per-coordinator counter
  /// (`disp-<slot>-run-<n>`).
  RunCoordinator({
    PreemptionState? preemption,
    PreemptionController? preemptionController,
    this.runRegistry,
    RunIdMint? runIdMint,
    this.foregroundQueueDepth = 4,
    Duration? hardStepDeadline,
    DeadlineTimerFactory? deadlineTimerFactory,
  })  : preemption = preemption ?? PreemptionState(),
        preemptionController = preemptionController ?? PreemptionController(),
        _ownsPreemptionController = preemptionController == null,
        _runIdMint = runIdMint,
        hardStepDeadline = hardStepDeadline ?? defaultCoordinatorHardStepDeadline,
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

  /// Whether this coordinator constructed [preemptionController] itself (the
  /// default) and therefore owns its [PreemptionController.close] lifecycle
  /// (F.3.2). `false` when a controller was injected — its lifecycle is the
  /// consumer's, per the constructor contract, so [close] leaves it open.
  final bool _ownsPreemptionController;

  /// The dispatcher-half `inflight` tracker (D.26), or `null` when the
  /// coordinator runs without memory-side run tracking. When non-null the
  /// coordinator pushes a `status: running` `ProcedureRun` marker onto the
  /// `inflight` stack the moment a run starts in a slot — but only for a
  /// submission that named the [procedureId] it executes (an opaque body with
  /// no procedure identity is not a memory-trackable run).
  final RunRegistry? runRegistry;

  /// The run-id mint (D.26). `null` ⇒ the default monotonic counter
  /// ([_mintRunId]). Each run is assigned an id the moment it occupies a
  /// slot; the id is threaded into the [preemptionController] record calls
  /// and the [runRegistry] push.
  final RunIdMint? _runIdMint;

  /// Backing counter for the default run-id mint.
  int _runSeq = 0;

  /// The live `inflight` handle for the foreground run, or `null` when no
  /// foreground run is being memory-tracked (D.27). Set by [_registerInflight]
  /// when a registry is wired and the submission named a procedure id; cleared
  /// by [_finishInflight] at run end. Holds the `recordStart` marker future and
  /// the [RunRegistration] facts so the run-end transition can await the marker
  /// and close it out.
  _InflightHandle? _foregroundInflight;

  /// The live `inflight` handle for the background run, or `null` (D.27). Same
  /// lifecycle as [_foregroundInflight], for the background slot.
  _InflightHandle? _backgroundInflight;

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

  /// Whether [drain] has begun (D.45). Once set, new submissions are refused
  /// with [CoordinatorDraining] so the live work can wind down to idle.
  bool _draining = false;

  /// Whether [close] has shut down the *owned* [preemptionController], so the
  /// coordinator must stop driving it (F.3.2). A [drain] with a [Duration]
  /// timeout can return while a genuinely-hung run is still in-flight; when
  /// `BootedBrain.shutdown` then calls [close], that abandoned body may *still*
  /// complete later and try to record its slot-exit / resume transition. Driving
  /// a closed controller throws, so once we close our own controller we route
  /// those late records to a no-op — the abandoned body runs *untracked*, which
  /// is exactly the post-drain contract. An injected controller is never closed
  /// by [close], so this stays `false` and its records keep flowing to the
  /// consumer that owns its lifecycle.
  bool _recordingSuppressed = false;

  /// Whether a foreground run is currently live (occupying the slot).
  bool get hasForegroundRun => _foreground != null;

  /// Whether a background run is currently live.
  bool get hasBackgroundRun => _background != null;

  /// Whether the coordinator is draining for shutdown (D.45). While `true` it
  /// admits no new foreground or background work.
  bool get isDraining => _draining;

  /// Whether the coordinator is fully idle: no foreground run, an empty FIFO
  /// foreground queue, and no background run. The state [drain] waits to reach.
  bool get isIdle =>
      _foreground == null && _foregroundQueue.isEmpty && _background == null;

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
  ///
  /// [procedureId] / [version] name the procedure this run executes; when a
  /// [runRegistry] is wired and [procedureId] is supplied, the run is pushed
  /// onto `inflight` the moment it occupies the slot (D.26). They are captured
  /// at submission time and applied when a queued run is later pumped into the
  /// freed slot.
  Future<T> submitForeground<T>(
    RunBody<T> body, {
    String? procedureId,
    int version = 1,
  }) {
    if (_draining) {
      // Shutting down: admit no new work so the live chain can drain (D.45).
      throw const CoordinatorDraining(RunSlot.foreground);
    }
    final completer = Completer<T>();
    void start() => _runInSlot(
          RunSlot.foreground,
          body,
          completer,
          procedureId,
          version,
          pumpQueueOnDone: true,
        );

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
      _record(preemptionController.recordForegroundPreemptionRequested);
    }
    return completer.future;
  }

  /// Submits [body] as the background run.
  ///
  /// Throws [RunSlotBusy] synchronously if a background run is already live —
  /// there is no background queue. Otherwise the body starts immediately, the
  /// background slot is marked occupied until the body completes, and the
  /// returned future carries the body's own result (or error).
  ///
  /// [procedureId] / [version] name the procedure this run executes; when a
  /// [runRegistry] is wired and [procedureId] is supplied, the run is pushed
  /// onto `inflight` the moment it occupies the slot (D.26).
  Future<T> submitBackground<T>(
    RunBody<T> body, {
    String? procedureId,
    int version = 1,
  }) {
    if (_draining) {
      // Shutting down: admit no new work so the live run can drain (D.45).
      throw const CoordinatorDraining(RunSlot.background);
    }
    if (_background != null) {
      throw const RunSlotBusy(RunSlot.background);
    }
    final completer = Completer<T>();
    _runInSlot(
      RunSlot.background,
      body,
      completer,
      procedureId,
      version,
      pumpQueueOnDone: false,
    );
    return completer.future;
  }

  /// Synchronously reserves the background slot for an *about-to-be-built* run,
  /// or returns `null` when a background run is already live or the coordinator
  /// is draining (F.3.1).
  ///
  /// This closes the [FreeTimeScheduler.tick] time-of-check/time-of-use race:
  /// the scheduler must check "is the background slot free?" and then perform
  /// `await`s (read the stacks, pop an entry, build the run body) before it can
  /// submit. Without an atomic reserve, two near-simultaneous ticks — or a tick
  /// racing a [submitBackground] — could both observe the slot free and both
  /// admit a background run, breaking the single-background invariant (PE-5).
  ///
  /// The reservation marks the background slot occupied *now*, synchronously,
  /// so any concurrent admission attempt during the caller's `await`s sees the
  /// slot busy. The caller must then either run its body via
  /// [BackgroundReservation.submit] or release the slot via
  /// [BackgroundReservation.cancel] (e.g. when no work materialised) — exactly
  /// one, exactly once.
  BackgroundReservation? reserveBackground() {
    if (_draining || _background != null) {
      return null;
    }
    final marker = Completer<void>();
    _background = marker.future;
    return BackgroundReservation._(this, marker);
  }

  /// Quiesces the coordinator for shutdown (D.45).
  ///
  /// Flips [isDraining] on so any further [submitForeground] /
  /// [submitBackground] is refused with [CoordinatorDraining], then *best-
  /// effort* waits for the coordinator to fall fully [isIdle] — the foreground
  /// slot free, the FIFO queue drained, and the background slot free. The
  /// in-flight foreground run (and everything already queued behind it) and any
  /// live background run reach their natural end, so each run's `RunRecorder`
  /// closes its trail before memory is flushed.
  ///
  /// "Best-effort" is bounded by [timeout]: when supplied, a coordinator that
  /// has not fallen idle within it stops being waited on and [drain] returns
  /// regardless. The abandoned body may still run to completion untracked —
  /// a `Future` is not cancellable — exactly as a hard-step-deadline
  /// force-yield (D.21) leaves it. A `null` [timeout] waits for full idle.
  ///
  /// Idempotent: a second call (already draining) re-awaits the current idle
  /// state, which resolves immediately once the coordinator is idle.
  Future<void> drain({Duration? timeout}) async {
    _draining = true;
    final settled = _awaitSettled();
    if (timeout == null) {
      await settled;
    } else {
      await settled.timeout(timeout, onTimeout: () {});
    }
  }

  /// Closes the coordinator's owned disposables (F.3.2).
  ///
  /// Closes [preemptionController] — so its event subscribers see the
  /// done-stream and no controller resource outlives the coordinator — but only
  /// when the coordinator *constructed* it (the default). An injected
  /// controller's lifecycle belongs to the consumer that supplied it, per the
  /// constructor contract, so this leaves it open. Idempotent: a second call is
  /// a no-op (the controller's own [PreemptionController.close] is idempotent).
  ///
  /// Call after [drain] in a shutdown sequence — `BootedBrain.shutdown` does so
  /// once the coordinator has quiesced, so no transition emits after the stream
  /// closes.
  Future<void> close() async {
    if (_ownsPreemptionController) {
      // Suppress further records *before* the controller closes, so a late
      // completion of an abandoned run (drain timed out on a hung body) routes
      // its slot-exit / resume transition to a no-op rather than driving a
      // closed controller (which would throw).
      _recordingSuppressed = true;
      await preemptionController.close();
    }
  }

  /// Drives a [preemptionController] `record*` call unless the coordinator has
  /// closed its own controller (F.3.2). Centralises the post-close suppression
  /// so every transition record shares one guard — see [_recordingSuppressed].
  void _record(void Function() emit) {
    if (_recordingSuppressed) {
      return;
    }
    emit();
  }

  /// Completes once the coordinator is fully [isIdle] (D.45).
  ///
  /// Awaits whichever slot markers are live; a foreground completion pumps the
  /// FIFO queue synchronously (re-occupying the slot) *before* this loop's
  /// continuation runs, so the re-check sees any queued successor and keeps
  /// waiting until the whole chain — running plus queued — has drained. The
  /// slot markers complete on both success and error, so this never throws.
  Future<void> _awaitSettled() async {
    while (!isIdle) {
      final live = <Future<void>>[?_foreground, ?_background];
      // A non-idle coordinator with no live slot marker can only be the
      // transient in-pump window (queue non-empty, slot momentarily null),
      // which never persists across an await; with nothing to await, yield a
      // microtask and re-check rather than busy-spin or block forever.
      if (live.isEmpty) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      await Future.wait<void>(live);
    }
  }

  /// Occupies [slot] with [body], completing [completer] with the body's
  /// result, then — when [pumpQueueOnDone] is set (the foreground path) — pumps
  /// the next queued foreground run and resumes any parked background.
  ///
  /// The single run-completion path shared by [submitForeground] (via its
  /// `start` closure), [submitBackground], and [BackgroundReservation.submit]
  /// (F.2.1): the slot-occupancy marker, run-id mint, controller start/finish
  /// records, and `inflight` registration/close-out all live here once, so a
  /// fix to run-completion (e.g. the deadline mapping) lands in a single place
  /// rather than being patched per slot.
  ///
  /// When [slotMarker] is supplied the slot was already marked occupied by the
  /// caller (a [BackgroundReservation]); this reuses that marker rather than
  /// minting a fresh one, so the reservation's slot hold flows straight into
  /// the run without a window where the slot looks free.
  void _runInSlot<T>(
    RunSlot slot,
    RunBody<T> body,
    Completer<T> completer,
    String? procedureId,
    int version, {
    required bool pumpQueueOnDone,
    Completer<void>? slotMarker,
  }) {
    final marker = slotMarker ?? Completer<void>();
    if (slotMarker == null) {
      // Mark the slot occupied *before* invoking the body, so a re-entrant
      // submission from inside the body sees the slot busy rather than racing.
      _setSlotMarker(slot, marker.future);
    }
    final runId = _nextRunId(slot);
    _record(() => preemptionController.recordRunStarted(slot, runId: runId));
    _registerInflight(slot, runId, procedureId, version);

    // Frees the slot and emits the run-end records. Run *before* the caller's
    // future is completed and (foreground) before the queue is pumped, so a
    // queued successor's RunSlotEntered follows this run's RunSlotExited.
    void finishSlot(RunSlotOutcome slotOutcome) {
      _setSlotMarker(slot, null);
      marker.complete();
      _record(() =>
          preemptionController.recordRunFinished(slot, slotOutcome, runId: runId));
      _finishInflight(slot, slotOutcome);
    }

    // The foreground-only tail: pump the next queued run and release a parked
    // background once the whole foreground chain has drained.
    void afterComplete() {
      if (pumpQueueOnDone) {
        _pumpForegroundQueue();
        _resumeBackgroundIfForegroundDrained();
      }
    }

    _guardWithDeadline(body).then(
      (outcome) {
        finishSlot(_slotOutcomeOf(outcome));
        _completeFromOutcome(completer, outcome, slot);
        afterComplete();
      },
      onError: (Object error, StackTrace stackTrace) {
        finishSlot(RunSlotOutcome.failed);
        completer.completeError(error, stackTrace);
        afterComplete();
      },
    );
  }

  /// Sets (or clears, with `null`) the slot-occupancy marker for [slot].
  void _setSlotMarker(RunSlot slot, Future<void>? marker) {
    switch (slot) {
      case RunSlot.foreground:
        _foreground = marker;
      case RunSlot.background:
        _background = marker;
    }
  }

  /// Releases a [BackgroundReservation] that was never submitted (F.3.1): frees
  /// the background slot and completes its hold marker. A no-op if the slot has
  /// already moved on (defensive — the reservation contract is submit-or-cancel
  /// exactly once).
  void _releaseBackgroundReservation(Completer<void> marker) {
    if (identical(_background, marker.future)) {
      _background = null;
    }
    if (!marker.isCompleted) {
      marker.complete();
    }
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
      _record(preemptionController.recordBackgroundResumeSignalled);
    }
  }

  /// Mints the run id for a run just admitted into [slot] (D.26), using the
  /// injected [RunIdMint] when present and the default monotonic counter
  /// ([_mintRunId]) otherwise.
  String _nextRunId(RunSlot slot) =>
      _runIdMint != null ? _runIdMint(slot) : _mintRunId(slot);

  /// The default run-id mint: a monotonic per-coordinator counter,
  /// `disp-<slot>-run-<n>` (n is one-based, shared across both slots so every
  /// id within a coordinator is unique).
  String _mintRunId(RunSlot slot) => 'disp-${slot.name}-run-${++_runSeq}';

  /// Pushes a `status: running` `ProcedureRun` marker onto `inflight` for a
  /// run just admitted into [slot] (D.26) and holds the handle for run-end
  /// close-out (D.27).
  ///
  /// A no-op when no [runRegistry] is wired or the submission did not name the
  /// [procedureId] it executes — an opaque body has no procedure identity to
  /// record. The push is fired without blocking the run body: the coordinator
  /// keeps its synchronous admission semantics (a submission occupies its slot
  /// immediately), and the memory write proceeds concurrently. The
  /// `recordStart` marker future and the [RunRegistration] facts are stored in
  /// the slot's [_InflightHandle] so [_finishInflight] can remove the marker
  /// from `inflight` and push to `recent_runs` when the run ends.
  void _registerInflight(
    RunSlot slot,
    String runId,
    String? procedureId,
    int version,
  ) {
    final registry = runRegistry;
    if (registry == null || procedureId == null) {
      return;
    }
    final registration = RunRegistration(
      runId: runId,
      procedureId: procedureId,
      version: version,
      slot: slot,
    );
    // Fire the start push without blocking; keep the future as the run-end
    // handle.
    final markerFuture = registry.recordStart(registration);
    final handle = _InflightHandle(markerFuture, registration);
    switch (slot) {
      case RunSlot.foreground:
        _foregroundInflight = handle;
      case RunSlot.background:
        _backgroundInflight = handle;
    }
  }

  /// Closes out the `inflight` handle for a run just ended in [slot] (D.27):
  /// removes the running marker from `inflight` and pushes a terminal
  /// `ProcedureRun` marker (mapped from [outcome]) onto `recent_runs`.
  ///
  /// A no-op when the slot has no live handle (no registry wired, or an opaque
  /// body that was never tracked). The held handle is cleared *before* the
  /// memory write is fired, so the coordinator carries no dead state for a
  /// finished run, and the run-end write — like the start write — proceeds
  /// without blocking the completion path.
  void _finishInflight(RunSlot slot, RunSlotOutcome outcome) {
    final registry = runRegistry;
    final handle = switch (slot) {
      RunSlot.foreground => _foregroundInflight,
      RunSlot.background => _backgroundInflight,
    };
    if (registry == null || handle == null) {
      return;
    }
    switch (slot) {
      case RunSlot.foreground:
        _foregroundInflight = null;
      case RunSlot.background:
        _backgroundInflight = null;
    }
    unawaited(_closeInflight(registry, handle, outcome));
  }

  /// Awaits the start-push marker future and hands the run-end facts to the
  /// registry (D.27). Split out so [_finishInflight] stays synchronous.
  Future<void> _closeInflight(
    RunRegistry registry,
    _InflightHandle handle,
    RunSlotOutcome outcome,
  ) async {
    final NodeId markerId = await handle.markerFuture;
    await registry.recordEnd(
      handle.registration,
      markerId: markerId,
      outcome: _runOutcomeOf(outcome),
    );
  }

  /// Maps the preemption-controller [RunSlotOutcome] (D.24) to the registry's
  /// [RunOutcome] (D.27) so the finished `recent_runs` marker carries the
  /// matching terminal status.
  RunOutcome _runOutcomeOf(RunSlotOutcome outcome) => switch (outcome) {
        RunSlotOutcome.completed => RunOutcome.completed,
        RunSlotOutcome.failed => RunOutcome.failed,
        RunSlotOutcome.forceYielded => RunOutcome.forceYielded,
      };

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

/// The coordinator's live `inflight` tracking for one run (D.27).
///
/// Holds the [markerFuture] returned by [RunRegistry.recordStart] (the
/// running marker's eventual node id, fired without blocking the body) and
/// the [registration] facts, so the run-end transition can await the marker,
/// remove it from `inflight`, and push a terminal marker onto `recent_runs`.
final class _InflightHandle {
  /// Wraps the start-push [markerFuture] and the [registration] facts.
  const _InflightHandle(this.markerFuture, this.registration);

  /// The running marker node id, eventually — the handle the run-end
  /// transition removes from `inflight`.
  final Future<NodeId> markerFuture;

  /// The launch facts the registry needs to write the finished marker.
  final RunRegistration registration;
}

/// A synchronous hold on the coordinator's background slot, handed back by
/// [RunCoordinator.reserveBackground] (F.3.1).
///
/// The free-time scheduler reserves the slot *before* it does the `await`s
/// needed to build a background run (reading the stacks, popping an entry,
/// routing it to a body). The reservation marks the slot occupied immediately,
/// so a concurrent tick or a racing [RunCoordinator.submitBackground] sees the
/// slot busy and does not double-admit. The holder must settle the reservation
/// exactly once: [submit] to run the built body in the held slot, or [cancel]
/// to release it when no work materialised.
final class BackgroundReservation {
  BackgroundReservation._(this._coordinator, this._marker);

  final RunCoordinator _coordinator;
  final Completer<void> _marker;
  bool _settled = false;

  /// Runs [body] in the reserved background slot, completing with the body's
  /// own result (or error). Threads [procedureId] / [version] into the run's
  /// `inflight` tracking exactly as [RunCoordinator.submitBackground] does.
  ///
  /// Throws [StateError] if the reservation was already settled (submitted or
  /// cancelled).
  Future<T> submit<T>(
    RunBody<T> body, {
    String? procedureId,
    int version = 1,
  }) {
    _settle();
    final completer = Completer<T>();
    _coordinator._runInSlot(
      RunSlot.background,
      body,
      completer,
      procedureId,
      version,
      pumpQueueOnDone: false,
      slotMarker: _marker,
    );
    return completer.future;
  }

  /// Releases the reserved background slot without running anything (the caller
  /// found no work to schedule). Idempotent only in the sense that a settled
  /// reservation throws [StateError]; a fresh one releases the slot.
  void cancel() {
    _settle();
    _coordinator._releaseBackgroundReservation(_marker);
  }

  void _settle() {
    if (_settled) {
      throw StateError(
        'background reservation already settled (submit or cancel exactly once)',
      );
    }
    _settled = true;
  }
}
