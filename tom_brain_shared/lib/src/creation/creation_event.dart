// CreationEvent — the typed observability events for one creation-loop run
// (`creation_specification.md` § 9.1).
//
// What this file owns:
//
//   * `CreationEvent` — a sealed sum extending `BrainEvent`, with the twelve
//     variants the spec names (§ 9.1): `CreationRequested`,
//     `EnvironmentObserved`, `TestDrafted`, `TestRun`, `DraftProduced`,
//     `DraftWritten`, `PostObservationCaptured`, `SuccessChecked`,
//     `CritiqueProduced`, `CreationAccepted`, `CreationRolledBack`,
//     `ScopeViolation`. They trace one intent from the request, through the
//     observe → test-first → draft → observe → critique loop (§ 4), to
//     acceptance (with the `Artifact`) or rollback / best-effort incompletion,
//     plus the scope-violation refusal (§ 10).
//
// Why these live in `tom_brain_shared` (§ 12 topology — "CreationEvent /
// Artifact value types → tom_brain_shared"): the `create_v1` procedure realises
// them, the `tom_brain_run` creation-trail writer projects a `create_v1`
// procedure-tree record into them, and a Forge session inspector (§ 9.3) renders
// them off the shared `BrainEvent` base. A type three components reference is
// declared once — and this is the first real consumer that § 12.1 decision 4
// deferred the family to.
//
// The `kind` discriminators ([creationEventKinds]) double as the *categories the
// `create_v1` d4rt body emits (or will emit) via the `note(category, payload)`
// primitive* — the body cannot import this library (the sandbox allow-list
// excludes it), so the vocabulary is the contract between the body's string
// literals and these typed leaves. The shipped body emits a realised subset;
// the trail writer projects that subset plus the run's node/effect trail. A
// vocabulary test pins that the two never drift.
//
// Why sealed: a new creation-lifecycle variant is a contract change, not a
// silent extension — adding one forces every exhaustive `switch` to handle it.
//
// `creationId` (on the base) is the opaque correlation handle tying one intent's
// events together. It is nullable because the early events fire before any
// `Artifact` node exists (`CreationRequested` precedes any persist), mirroring
// `PlanningEvent.planId` and `BrainEvent.runId`.

import '../events/brain_event.dart';

/// Marker / base for every typed creation-loop observability event.
///
/// Extends [BrainEvent], so each variant inherits `occurredAt` (UTC) +
/// `runId` + `causedBy`, the `payloadJson()` contract, the composed
/// `toJson()`, and the kebab-case `kind` discriminator (`creation.<event>`).
sealed class CreationEvent extends BrainEvent {
  /// Opaque correlation handle tying one intent's events together — the
  /// `Artifact` node id once it exists, `null` for the pre-persist events.
  final String? creationId;

  /// Builds the base of a creation event. [runId] stays nullable (the
  /// [BrainEvent] default): the loop always runs inside a `create_v1`
  /// procedure run, but the base does not force the id.
  CreationEvent({
    required super.occurredAt,
    this.creationId,
    super.runId,
    super.causedBy,
  });
}

/// An intent entered the creation loop — the first event of a run (§ 4.1,
/// entry validation § 10). Carries the observable success criterion that
/// entry validation required.
final class CreationRequested extends CreationEvent {
  /// The creation intent the loop received.
  final String intent;

  /// The observable success criterion (compile / tests / schema / analyzer).
  final String successCriterion;

  /// The resolved target the artifact will be written to, when known at
  /// request time.
  final String? target;

  CreationRequested({
    required super.occurredAt,
    required this.intent,
    required this.successCriterion,
    this.target,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.requested';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'intent': intent,
        'successCriterion': successCriterion,
        if (target != null) 'target': target,
      };
}

/// The pre-draft environment was captured — Stage A (§ 4.2).
final class EnvironmentObserved extends CreationEvent {
  /// How many targets / named context artifacts were observed.
  final int targetCount;

  EnvironmentObserved({
    required super.occurredAt,
    required this.targetCount,
    super.creationId,
    super.runId,
    super.causedBy,
  }) {
    if (targetCount < 0) {
      throw ArgumentError.value(
          targetCount, 'targetCount', 'must be non-negative');
    }
  }

  @override
  String get kind => 'creation.environment-observed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'targetCount': targetCount,
      };
}

/// The `tester` role drafted a test / success-check first — Stage B (§ 4.3).
final class TestDrafted extends CreationEvent {
  /// The test target that was drafted, when named.
  final String? testTarget;

  TestDrafted({
    required super.occurredAt,
    this.testTarget,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.test-drafted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        if (testTarget != null) 'testTarget': testTarget,
      };
}

/// The drafted test was run before the artifact exists — Stage B (§ 4.3). It
/// must fail with a comprehensible error or be skipped with a logged reason;
/// [failedOrSkipped] records that this "right kind of failure" held.
final class TestRun extends CreationEvent {
  /// Whether the pre-artifact test failed or was skipped as expected.
  final bool failedOrSkipped;

  /// The raw outcome token, when available (`failed` / `skipped` / `passed`).
  final String? outcome;

  TestRun({
    required super.occurredAt,
    required this.failedOrSkipped,
    this.outcome,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.test-run';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'failedOrSkipped': failedOrSkipped,
        if (outcome != null) 'outcome': outcome,
      };
}

/// The `creator` role produced a draft — Stage C (§ 4.4).
final class DraftProduced extends CreationEvent {
  /// The loop iteration this draft belongs to (0-based).
  final int iteration;

  DraftProduced({
    required super.occurredAt,
    required this.iteration,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.draft-produced';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'iteration': iteration,
      };
}

/// The draft was written to disk (or staged) — Stage C (§ 4.4). "There is no
/// in-memory draft we never wrote."
final class DraftWritten extends CreationEvent {
  /// The loop iteration this write belongs to (0-based).
  final int iteration;

  /// The target the draft was written to.
  final String target;

  DraftWritten({
    required super.occurredAt,
    required this.iteration,
    required this.target,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.draft-written';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'iteration': iteration,
        'target': target,
      };
}

/// The post-draft environment was re-captured — Stage D (§ 4.5).
final class PostObservationCaptured extends CreationEvent {
  /// The loop iteration this observation belongs to (0-based).
  final int iteration;

  /// How many targets were re-observed.
  final int targetCount;

  PostObservationCaptured({
    required super.occurredAt,
    required this.iteration,
    required this.targetCount,
    super.creationId,
    super.runId,
    super.causedBy,
  }) {
    if (targetCount < 0) {
      throw ArgumentError.value(
          targetCount, 'targetCount', 'must be non-negative');
    }
  }

  @override
  String get kind => 'creation.post-observation-captured';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'iteration': iteration,
        'targetCount': targetCount,
      };
}

/// The success criterion was evaluated against the post-draft observations —
/// Stage D (§ 4.5).
final class SuccessChecked extends CreationEvent {
  /// The loop iteration this check belongs to (0-based).
  final int iteration;

  /// Whether the success criterion was satisfied.
  final bool satisfied;

  SuccessChecked({
    required super.occurredAt,
    required this.iteration,
    required this.satisfied,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.success-checked';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'iteration': iteration,
        'satisfied': satisfied,
      };
}

/// The `reviewer` role produced a critique verdict — Stage E (§ 4.6).
final class CritiqueProduced extends CreationEvent {
  /// Whether the critique accepted the draft.
  final bool accepted;

  /// The loop iteration this critique belongs to (0-based).
  final int iteration;

  /// A short rationale, when the critique supplied one.
  final String? reason;

  CritiqueProduced({
    required super.occurredAt,
    required this.accepted,
    required this.iteration,
    this.reason,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.critique-produced';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'accepted': accepted,
        'iteration': iteration,
        if (reason != null) 'reason': reason,
      };
}

/// The loop accepted a draft — the terminal success (§ 4.1). The `Artifact`
/// node has been persisted and linked `Artifact —satisfied_by→ Question`.
final class CreationAccepted extends CreationEvent {
  /// The accepted artifact's target.
  final String target;

  /// How many iterations the loop took to accept (1-based count).
  final int iterations;

  CreationAccepted({
    required super.occurredAt,
    required this.target,
    required this.iterations,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.accepted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'target': target,
        'iterations': iterations,
      };
}

/// A rejected draft was rolled back (§ 4.7), or the loop exhausted its
/// iterations and returned a best-effort incomplete result (§ 4.1, § 10).
final class CreationRolledBack extends CreationEvent {
  /// The loop iteration that was rolled back (0-based).
  final int iteration;

  /// Whether this is the terminal best-effort incompletion (iterations
  /// exhausted) rather than a mid-loop rollback.
  final bool incomplete;

  CreationRolledBack({
    required super.occurredAt,
    required this.iteration,
    required this.incomplete,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.rolled-back';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        'iteration': iteration,
        'incomplete': incomplete,
      };
}

/// A tool call attempted to touch a file outside the creation's file scope;
/// the tool layer blocked it (§ 7, § 10 `error.scope_violation`).
final class ScopeViolation extends CreationEvent {
  /// The tool that attempted the out-of-scope access, when known.
  final String? tool;

  /// The path the tool attempted to touch, when known.
  final String? attemptedPath;

  ScopeViolation({
    required super.occurredAt,
    this.tool,
    this.attemptedPath,
    super.creationId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'creation.scope-violation';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (creationId != null) 'creationId': creationId,
        if (tool != null) 'tool': tool,
        if (attemptedPath != null) 'attemptedPath': attemptedPath,
      };
}

/// The twelve `CreationEvent.kind` discriminators, in the canonical lifecycle
/// order of `creation_specification.md` § 9.1.
///
/// This list is the single source of truth for the creation observability
/// vocabulary. The `create_v1` d4rt body emits a subset of these as `note(...)`
/// categories (the body cannot import the typed leaves), and the
/// `tom_brain_run` creation-trail writer projects that subset into the typed
/// leaves, so a test pins that every leaf's [kind] getter appears here in
/// order.
const List<String> creationEventKinds = <String>[
  'creation.requested',
  'creation.environment-observed',
  'creation.test-drafted',
  'creation.test-run',
  'creation.draft-produced',
  'creation.draft-written',
  'creation.post-observation-captured',
  'creation.success-checked',
  'creation.critique-produced',
  'creation.accepted',
  'creation.rolled-back',
  'creation.scope-violation',
];
