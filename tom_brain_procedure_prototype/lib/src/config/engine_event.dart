// C.44 — `EngineEvent` sealed sum.
//
// `tom_brain_procedure_prototype_specification.md` § 13 names five
// variants for the engine's typed observability stream:
// `InvocationStarted`, `PrimitiveCalled`, `StepYielded`,
// `InvocationCompleted`, `InvocationFailed`. They are what consumers
// (the dispatcher trail, the Tom Forge procedure-run inspector, a
// metrics scraper, tests) subscribe to via `EngineEventBus.events()`
// (`engine_event_bus.dart`).
//
// Sealed for the same reason `SubstrateEvent` (B.9) and `MemoryEvent`
// (A-phase) are sealed: a new variant is an engine-contract change, not
// a silent extension. Adding one bumps the spec § 13 list and every
// consumer-side exhaustive `switch` must compile-error until it handles
// the new case.
//
// Why these inherit `BrainEvent` (from `tom_brain_shared`):
//
//   - `BrainEvent` is the universal observability base shared by every
//     Tom Brain component. It carries `occurredAt` (UTC) + `runId` +
//     `causedBy`, defines the `payloadJson()` contract for
//     serialisation, composes `toJson()` (kind + base fields +
//     payload), and the kebab-case `kind` discriminator
//     (`<component>.<event-name>`). Trail consumers stitch the
//     cross-component causal graph off that base without branching on
//     Dart runtime types.
//   - The engine-specific carrier is `EngineEvent`; each variant
//     carries its engine-side payload plus the inherited base. A
//     consumer can switch on the engine variant or on the `kind`
//     string — both are stable.
//
// `runId` (the base field) is the procedure-run id the event belongs
// to. Every engine event happens inside a run, so the variants below
// take `runId` as **required** (overriding the base's nullable default)
// — there is no engine event outside a run. The base stays nullable
// because boot / migration events in other components legitimately have
// no run.
//
// Relationship to the run trail (`TrailEntry`): the trail is the
// *durable, in-memory record* of a run that the recorder writes into
// `tom_brain_memory`; `EngineEvent`s are the *live, observe-only*
// lifecycle signal. The two overlap by design — an operator watches
// events as a run unfolds; the trail is what survives for replay. The
// engine's emission wiring (turning each lifecycle moment into an
// `EngineEvent` on the bus) is the composition root's job, mirroring
// how substrate's producers are wired at its `InProcessTomBrainSubstrate`
// root (B.40+); see Q-C.44.1.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TrailOutcomeStatus;
import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// Marker / base for every typed engine observability event.
///
/// A consumer subscribed to `EngineEventBus.events()` sees only
/// subtypes of this class. Exhaustive `switch` over the closed taxonomy
/// (five variants, spec § 13) is the recommended branch surface.
sealed class EngineEvent extends BrainEvent {
  /// Builds the base of an engine event.
  ///
  /// [runId] is **required** (and non-null) — every engine event happens
  /// inside a procedure run. This narrows `BrainEvent`'s nullable
  /// `runId`, which stays nullable for components that emit outside any
  /// run (boot, migration, MCP-server lifecycle).
  EngineEvent({
    required super.occurredAt,
    required String super.runId,
    super.causedBy,
  });

  /// The procedure-run id this event belongs to. Always present for
  /// engine events (the base's `runId` is non-null here by construction).
  @override
  String get runId => super.runId!;
}

/// A procedure invocation began — emitted once per run after the
/// procedure id resolves and the run trail opens, before the procedure
/// source runs.
final class InvocationStarted extends EngineEvent {
  /// The resolved procedure id (e.g. `answer_with_memory_v1`).
  final String procedureId;

  /// The resolved procedure version, when the header pins one.
  final int? version;

  /// The parent run's id when this is a nested `runProcedure` call;
  /// `null` for a top-level invocation.
  final String? parentRunId;

  /// The depth this invocation runs at (1 for a top-level run; deeper
  /// for nested `runProcedure` calls, bounded by the hard depth cap).
  final int depth;

  InvocationStarted({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.procedureId,
    this.version,
    this.parentRunId,
    required this.depth,
  });

  @override
  String get kind => 'engine.invocation-started';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'procedureId': procedureId,
        if (version != null) 'version': version,
        if (parentRunId != null) 'parentRunId': parentRunId,
        'depth': depth,
      };
}

/// A bridged or engine-native primitive was invoked during the run
/// (e.g. a `mem.*` / `sub.*` bridge method, or a native `note`,
/// `runProcedure`, `yield_if_foreground_waiting`).
final class PrimitiveCalled extends EngineEvent {
  /// The primitive's name as the procedure script names it.
  final String primitive;

  /// The depth of the run that issued the call.
  final int depth;

  PrimitiveCalled({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.primitive,
    required this.depth,
  });

  @override
  String get kind => 'engine.primitive-called';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'primitive': primitive,
        'depth': depth,
      };
}

/// The run yielded — either cooperatively (a `yield_if_foreground_waiting`
/// check found a foreground waiter) or by force (the hard per-step
/// deadline expired and truncated the step).
final class StepYielded extends EngineEvent {
  /// Why the run yielded — [foregroundWaitingReason] (cooperative) or
  /// [deadlineReason] (forced).
  final String reason;

  /// `true` when the yield was a hard-deadline truncation (the step did
  /// not get to a natural yield point); `false` for a cooperative yield.
  final bool truncated;

  StepYielded({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.reason,
    required this.truncated,
  });

  /// Reason value for a cooperative yield (a foreground waiter is pending).
  static const String foregroundWaitingReason = 'foreground_waiting';

  /// Reason value for a forced yield (the hard step deadline expired).
  static const String deadlineReason = 'deadline';

  @override
  String get kind => 'engine.step-yielded';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'reason': reason,
        'truncated': truncated,
      };
}

/// A run closed on a terminal status (any non-error close: `accepted`,
/// `rejected`, `aborted`, `preempted`, `budgetExceeded`). A crash is
/// reported by [InvocationFailed], not here.
final class InvocationCompleted extends EngineEvent {
  /// The procedure id that closed.
  final String procedureId;

  /// The terminal status the run closed on.
  final TrailOutcomeStatus status;

  /// A short human-readable summary of how the run closed.
  final String? summary;

  InvocationCompleted({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.procedureId,
    required this.status,
    this.summary,
  });

  @override
  String get kind => 'engine.invocation-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'procedureId': procedureId,
        'status': status.name,
        if (summary != null) 'summary': summary,
      };
}

/// A run failed — the procedure threw an unhandled error (a runtime
/// crash, `procedure.runtime.crash`) or otherwise errored before a
/// terminal close. Carries the failure class + message.
final class InvocationFailed extends EngineEvent {
  /// The procedure id that failed.
  final String procedureId;

  /// The typed failure class (e.g. `procedure.runtime.crash`).
  final String failureKind;

  /// The failure message — the stringified error.
  final String message;

  InvocationFailed({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.procedureId,
    required this.failureKind,
    required this.message,
  });

  @override
  String get kind => 'engine.invocation-failed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'procedureId': procedureId,
        'failureKind': failureKind,
        'message': message,
      };
}
