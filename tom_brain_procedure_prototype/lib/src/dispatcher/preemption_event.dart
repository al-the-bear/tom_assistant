// `PreemptionEvent` — the typed observability events the dispatcher's
// `PreemptionController` emits on every coordinator transition (Plan step
// D.23; `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// The `RunCoordinator` (D.18–D.21) owns the *mechanics* of the single-
// foreground / single-background invariant, the FIFO foreground queue,
// cooperative preemption, and the hard step deadline. It is the single
// writer of the shared `PreemptionState`. `PreemptionController` (D.23) is
// the *supervising observer*: it watches both run slots and emits one of
// these events on every transition, so an operator (the Tom Forge run
// inspector), a trail recorder, or a test can see the preemption state
// machine move without polling the coordinator or becoming a second writer
// of `PreemptionState`.
//
// The taxonomy is the coordinator's observable transition set:
//
//   - [RunSlotEntered]               — a run began occupying a slot.
//   - [RunSlotExited]                — a run left its slot (with an outcome).
//   - [ForegroundPreemptionRequested]— a foreground arrival asked the live
//                                       background run to yield at its next
//                                       cooperative checkpoint.
//   - [BackgroundResumeSignalled]    — the foreground workload drained and the
//                                       parked background run was released.
//
// Sealed for the same reason `EngineEvent` (C.44) and `SubstrateEvent` (B.9)
// are sealed: a new variant is a dispatcher-contract change, not a silent
// extension. Adding one bumps this taxonomy and every consumer-side
// exhaustive `switch` must compile-error until it handles the new case.
//
// Each variant inherits `BrainEvent` (from `tom_brain_shared`), the
// universal observability base carrying `occurredAt` (UTC) + `runId` +
// `causedBy`, the `payloadJson()` serialisation contract, and the kebab-case
// `kind` discriminator (`<component>.<event-name>`). Since D.26 the
// coordinator assigns a run id to every run the moment it occupies a slot and
// threads it through, so [RunSlotEntered] / [RunSlotExited] carry a non-null
// `runId`. The state-transition events ([ForegroundPreemptionRequested] /
// [BackgroundResumeSignalled]) keep a null `runId` (the base default): they
// describe a *transition* of the shared preemption state, not a single run.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

import 'run_coordinator.dart' show RunSlot;

/// How a run left its slot, carried by [RunSlotExited].
///
/// The coordinator knows which of these applies at every completion point:
/// a body that returns normally is [completed]; a body that throws a
/// non-deadline error is [failed]; a body the coordinator's hard step
/// deadline truncated (surfacing `RunDeadlineExceeded`) is [forceYielded].
enum RunSlotOutcome {
  /// The run body returned a value normally.
  completed,

  /// The run body threw an error that was not a coordinator deadline
  /// force-yield (e.g. a procedure runtime crash propagating out of the body).
  failed,

  /// The coordinator's hard step deadline (D.21) fired and force-yielded the
  /// run; the caller saw `RunDeadlineExceeded` (`procedure.deadline.exceeded`).
  forceYielded;

  /// The wire string this outcome serialises to on the trail (F.4.1).
  ///
  /// Snake-case so the two parallel run-outcome vocabularies render identically
  /// across the dispatcher's observability surfaces — this matches the registry
  /// [RunOutcome.status] form persisted to `recent_runs` (D.27) and emitted on
  /// the `DispatcherEvent` stream (`RunCompleted`), so "how did the run end"
  /// reads the same whether it surfaces via [RunSlotExited] or `RunCompleted`.
  String get status => switch (this) {
        RunSlotOutcome.completed => 'completed',
        RunSlotOutcome.failed => 'failed',
        RunSlotOutcome.forceYielded => 'force_yielded',
      };
}

/// Marker / base for every typed preemption observability event (D.23).
///
/// A consumer subscribed to `PreemptionController.events()` sees only
/// subtypes of this class. Exhaustive `switch` over the closed taxonomy
/// (four variants) is the recommended branch surface.
sealed class PreemptionEvent extends BrainEvent {
  /// Builds the base of a preemption event.
  ///
  /// [runId] is the coordinator-assigned run id (D.26) for the slot
  /// enter/exit events, and null for the state-transition events.
  PreemptionEvent({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });
}

/// A run began occupying a coordinator slot.
///
/// Emitted when the coordinator actually *starts* a body in a slot — never
/// for a submission that was rejected (`RunSlotBusy`, `ForegroundQueueFull`)
/// or is still waiting in the FIFO foreground queue. A queued foreground run
/// produces this event only when it later re-occupies the freed slot.
final class RunSlotEntered extends PreemptionEvent {
  /// The slot the run entered.
  final RunSlot slot;

  RunSlotEntered({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.slot,
  });

  @override
  String get kind => 'dispatcher.run-slot-entered';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'slot': slot.name,
      };
}

/// A run left its coordinator slot, freeing it.
///
/// Carries the [outcome] that closed the run so a consumer can distinguish a
/// clean completion from a failure or a hard-deadline force-yield without
/// correlating against the engine's own event stream.
final class RunSlotExited extends PreemptionEvent {
  /// The slot the run vacated.
  final RunSlot slot;

  /// How the run closed.
  final RunSlotOutcome outcome;

  RunSlotExited({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.slot,
    required this.outcome,
  });

  @override
  String get kind => 'dispatcher.run-slot-exited';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'slot': slot.name,
        'outcome': outcome.status,
      };
}

/// A foreground arrival asked the live background run to yield.
///
/// Emitted on the *transition* into the waiting state only — the controller
/// mirrors `PreemptionState`'s idempotency, so back-to-back foreground
/// arrivals during one background run produce exactly one of these (the
/// first), not one per arrival. There is no payload beyond the base fields:
/// the event *is* the transition.
final class ForegroundPreemptionRequested extends PreemptionEvent {
  ForegroundPreemptionRequested({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'dispatcher.foreground-preemption-requested';

  @override
  Map<String, Object?> payloadJson() => const <String, Object?>{};
}

/// The foreground workload drained and the parked background run was released.
///
/// Emitted on the transition *out* of the waiting state only — a resume
/// signalled with no preemption pending is a no-op and produces no event,
/// mirroring `PreemptionState.signalResume`'s idempotency.
final class BackgroundResumeSignalled extends PreemptionEvent {
  BackgroundResumeSignalled({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'dispatcher.background-resume-signalled';

  @override
  Map<String, Object?> payloadJson() => const <String, Object?>{};
}
