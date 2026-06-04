// D.49 — `DispatcherEvent` sealed sum.
//
// `tom_brain_procedure_prototype_specification.md` § 13 names seven
// variants for the dispatcher's typed observability stream:
// `AccessAccepted`, `ProcedureSelected`, `ForegroundQueued`,
// `Preempted`, `Resumed`, `RunCompleted`, `FallbackTried`. They are what
// consumers (the Tom Forge run inspector, a metrics scraper, tests)
// subscribe to via `DispatcherEventBus.events()`
// (`dispatcher_event_bus.dart`).
//
// This is the dispatcher half of the C.44 `EngineEvent` work: same
// sealed-sum + broadcast-bus shape, same `BrainEvent` base, same
// "consumers vary, producers don't" framing. A reader who has read
// `engine_event.dart` has read this.
//
// ── Where this lives, and why not `config/` ─────────────────────────
//
// `EngineEvent` lives in `config/` because the engine half placed its
// observability surface there (C.44). The *dispatcher* half already
// keeps its event families in this `dispatcher/` folder —
// `PreemptionEvent` (D.23) and `ProcedureFallback` (D.30) both live
// here, beside the runtime that emits them. Placing `DispatcherEvent`
// here keeps every dispatcher event in one module and, crucially, lets
// the `RunCompleted` / `FallbackTried` variants *reuse* the existing
// dispatcher runtime types (`RunOutcome`, `RunSlot`, `FallbackTrigger`,
// `ProcedureFallback`) without a `config/ → dispatcher/` import edge.
// Spec § 13's "Configuration + observability" grouping is a document
// section, not a folder mandate. See Q-D.49.1.
//
// ── `runId` stays nullable (it does NOT narrow like `EngineEvent`) ───
//
// `EngineEvent` narrows the base's nullable `runId` to required because
// every engine event happens inside a run. The dispatcher is different:
// `AccessAccepted` and `ProcedureSelected` fire *before* any run id is
// minted (the coordinator assigns the id only when a submission occupies
// a slot — D.26). So `DispatcherEvent` keeps `BrainEvent`'s nullable
// `runId`; the run-scoped variants (`RunCompleted`, `Preempted`,
// `Resumed`) carry one, the access-scoped variants do not.
//
// ── `FallbackTried` vs the existing `ProcedureFallback` ─────────────
//
// Spec § 13 names this dispatcher-stream variant `FallbackTried`; the
// plan (D.30) and definition (§ 6) name the executor's emission
// `ProcedureFallback` (Q-D.30.1 already flagged the divergence). Both
// names survive: `ProcedureFallback` is what the `FallbackExecutor`
// emits on its `FallbackEventSink`; `FallbackTried` is the
// `DispatcherEvent`-stream representation of the same fact. The
// composition root translates one to the other with the
// [FallbackTried.fromProcedureFallback] factory, so the field mapping
// is written once and locked by a test. See Q-D.49.2.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

import 'fallback_executor.dart' show FallbackTrigger;
import 'procedure_fallback_event.dart' show ProcedureFallback;
import 'run_coordinator.dart' show RunSlot;

/// Marker / base for every typed dispatcher observability event.
///
/// A consumer subscribed to `DispatcherEventBus.events()` sees only
/// subtypes of this class. Exhaustive `switch` over the closed taxonomy
/// (seven variants, spec § 13) is the recommended branch surface.
///
/// Unlike `EngineEvent`, this base does **not** narrow `runId` to
/// required: the access-scoped variants ([AccessAccepted],
/// [ProcedureSelected], [ForegroundQueued]) fire before a run id exists.
sealed class DispatcherEvent extends BrainEvent {
  /// Builds the base of a dispatcher event. [runId] stays nullable — see
  /// the file header.
  DispatcherEvent({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });
}

/// The dispatcher admitted an inbound [Access] at its entry surface
/// (§ 10.1, PE-11) — emitted once per accepted access, before
/// classification.
///
/// Access-scoped: no run id yet (the run is minted later, when a
/// submission occupies a coordinator slot).
final class AccessAccepted extends DispatcherEvent {
  /// The session the admitted access belongs to (`Session.sessionId`).
  final String sessionId;

  /// The pre-filled inbound kind hint the access layer supplied, when
  /// present; `null` when the access arrived un-hinted (the prototype's
  /// `classify_inbound_v1` stub then assigns one).
  final String? kindHint;

  AccessAccepted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.sessionId,
    this.kindHint,
  });

  @override
  String get kind => 'dispatcher.access-accepted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'sessionId': sessionId,
        if (kindHint != null) 'kindHint': kindHint,
      };
}

/// Procedure selection mapped a classified inbound kind to a procedure id
/// (§ 10.2) — emitted once per accepted access after classification.
final class ProcedureSelected extends DispatcherEvent {
  /// The classified inbound kind (e.g. `user_prompt`).
  final String inboundKind;

  /// The procedure id the kind routed to (e.g. `answer_with_memory_v1`).
  final String procedureId;

  ProcedureSelected({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.inboundKind,
    required this.procedureId,
  });

  @override
  String get kind => 'dispatcher.procedure-selected';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'inboundKind': inboundKind,
        'procedureId': procedureId,
      };
}

/// A foreground submission was enqueued behind a busy foreground slot
/// (§ 10.3, the D.19 FIFO queue) — emitted when the slot is occupied and
/// the queue had room.
final class ForegroundQueued extends DispatcherEvent {
  /// The foreground FIFO queue length *after* this submission was
  /// enqueued (≥ 1).
  final int queueDepth;

  ForegroundQueued({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.queueDepth,
  });

  @override
  String get kind => 'dispatcher.foreground-queued';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'queueDepth': queueDepth,
      };
}

/// A foreground preemption was requested against a running background run
/// (§ 10.3, PE-5) — the background yields cooperatively at its next
/// checkpoint, never mid-step. [runId] is the preempted background run.
final class Preempted extends DispatcherEvent {
  /// The incoming foreground run that triggered the preemption, when it
  /// already has an id; `null` when the foreground submission is still
  /// queued (no slot, no id yet).
  final String? foregroundRunId;

  Preempted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    this.foregroundRunId,
  });

  @override
  String get kind => 'dispatcher.preempted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (foregroundRunId != null) 'foregroundRunId': foregroundRunId,
      };
}

/// A parked background run resumed after the foreground workload fully
/// drained (slot free *and* FIFO queue empty — § 10.3). [runId] is the
/// resumed background run.
final class Resumed extends DispatcherEvent {
  Resumed({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'dispatcher.resumed';

  @override
  Map<String, Object?> payloadJson() => const <String, Object?>{};
}

/// The terminal outcome a run reached when the coordinator freed its slot,
/// carried on the [RunCompleted] dispatcher event.
///
/// Mirrors the three run-end paths the coordinator distinguishes: a body that
/// returned normally ([completed]), one that threw a non-deadline error
/// ([failed]), and one the coordinator's hard step deadline truncated
/// ([forceYielded]). The wire form ([status]) is snake-case so it renders
/// identically to [RunSlotOutcome.status] across the dispatcher's
/// observability surfaces (Q-D.26.1: the engine `RunRecorder` owns the durable
/// `recent_runs` record; this enum names the outcome on the event stream).
enum RunOutcome {
  /// The run body returned normally.
  completed,

  /// The run body threw a non-deadline error.
  failed,

  /// The coordinator's hard step deadline truncated the run.
  forceYielded;

  /// The snake-case wire string this outcome serialises to on the event
  /// stream — matching [RunSlotOutcome.status].
  String get status => switch (this) {
        RunOutcome.completed => 'completed',
        RunOutcome.failed => 'failed',
        RunOutcome.forceYielded => 'force_yielded',
      };
}

/// A run finished from the coordinator's perspective (§ 10.3, PE-4
/// dispatcher half) — emitted on every run end, success or failure or
/// force-yield. [runId] is the run that ended.
final class RunCompleted extends DispatcherEvent {
  /// The procedure id the run executed.
  final String procedureId;

  /// The terminal outcome the run reached (the same enum the
  /// `recent_runs` finished marker records — D.27).
  final RunOutcome outcome;

  /// The coordinator slot the run occupied.
  final RunSlot slot;

  RunCompleted({
    required super.occurredAt,
    required String super.runId,
    super.causedBy,
    required this.procedureId,
    required this.outcome,
    required this.slot,
  });

  /// The run id this completion belongs to. Always present for a
  /// [RunCompleted] (the constructor requires it).
  @override
  String get runId => super.runId!;

  @override
  String get kind => 'dispatcher.run-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'procedureId': procedureId,
        'outcome': outcome.status,
        'slot': slot.name,
      };
}

/// A fallback edge fired during a `FallbackExecutor.run` chain walk — the
/// `DispatcherEvent`-stream representation of a [ProcedureFallback]
/// (§ 10.4, PE-6; def § 6). Carries the same facts; build one from a
/// [ProcedureFallback] with [fromProcedureFallback].
final class FallbackTried extends DispatcherEvent {
  /// The procedure id whose version chain was walked.
  final String procedureId;

  /// The version that failed and triggered this fallback.
  final int fromVersion;

  /// The next-older version the executor stepped down to, or `null` when
  /// the failing version was the oldest in the chain and the failure
  /// surfaced.
  final int? toVersion;

  /// The typed run-failure class that triggered the fallback.
  final FallbackTrigger trigger;

  FallbackTried({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.procedureId,
    required this.fromVersion,
    required this.toVersion,
    required this.trigger,
  });

  /// Builds a [FallbackTried] from the executor's [ProcedureFallback]
  /// emission, preserving the base fields and the fallback facts. This is
  /// the single point where the two event names are bridged (file header).
  factory FallbackTried.fromProcedureFallback(ProcedureFallback event) =>
      FallbackTried(
        occurredAt: event.occurredAt,
        runId: event.runId,
        causedBy: event.causedBy,
        procedureId: event.procedureId,
        fromVersion: event.fromVersion,
        toVersion: event.toVersion,
        trigger: event.trigger,
      );

  /// Whether the failure surfaced to the caller because [fromVersion] was
  /// the oldest version in the chain (no older version to step to).
  bool get surfaced => toVersion == null;

  @override
  String get kind => 'dispatcher.fallback-tried';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'procedureId': procedureId,
        'fromVersion': fromVersion,
        if (toVersion != null) 'toVersion': toVersion,
        'trigger': trigger.failureKind,
        'surfaced': surfaced,
      };
}
