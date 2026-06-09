// PlanningEvent — the typed observability events for one planning-loop run
// (`planning_specification.md` § 10.1).
//
// What this file owns:
//
//   * `PlanningEvent` — a sealed sum extending `BrainEvent`, with the nine
//     variants the spec names: `PlanRequested`, `GoalClassified`,
//     `StepsDecomposed`, `GraphEstimated`, `PlanCritiqueProduced`,
//     `PlanAccepted`, `PlanRejected`, `PlanRevised`, `StepStatusChanged`. They
//     trace one goal from the request, through classification / decomposition /
//     estimation / critique, to acceptance (or rejection + re-entry), and the
//     re-planning + step-status transitions that follow.
//
// Why these live in `tom_brain_shared` (per § 11 topology — "PlanningEvent value
// types → tom_brain_shared"): the `plan_v1` procedure emits them, the dispatcher
// and a Forge plan inspector observe them off the shared `BrainEvent` base, and
// the trail render names them. A type three components reference is declared once.
//
// The `kind` discriminators ([planningEventKinds]) double as the *categories the
// `plan_v1` d4rt body emits via the `note(category, payload)` primitive* — the
// body cannot import this library (the sandbox allow-list excludes it), so the
// vocabulary is the contract between the body's string literals and these typed
// leaves. `b...`-style tests pin that the two never drift.
//
// Why sealed: a new planning-lifecycle variant is a contract change, not a
// silent extension — adding one forces every exhaustive `switch` to handle it.
//
// `planId` (on the base) is the opaque correlation handle tying one goal's
// events together. It is nullable because the early events fire before any Plan
// node exists (`PlanRequested` precedes the persist), mirroring `AccessEvent`'s
// nullable `accessId` and `BrainEvent`'s nullable `runId`.

import '../events/brain_event.dart';
import 'plan_status.dart';
import 'step_status.dart';

/// Marker / base for every typed planning-loop observability event.
///
/// Extends [BrainEvent], so each variant inherits `occurredAt` (UTC) +
/// `runId` + `causedBy`, the `payloadJson()` contract, the composed
/// `toJson()`, and the kebab-case `kind` discriminator (`planning.<event>`).
sealed class PlanningEvent extends BrainEvent {
  /// Opaque correlation handle tying one goal's events together — the Plan
  /// node id once it exists, `null` for the pre-persist events.
  final String? planId;

  /// Builds the base of a planning event. [runId] stays nullable (the
  /// [BrainEvent] default): the loop may run inside a procedure run or be
  /// driven directly.
  PlanningEvent({
    required super.occurredAt,
    this.planId,
    super.runId,
    super.causedBy,
  });
}

/// A goal entered the planning loop — the first event of a run.
final class PlanRequested extends PlanningEvent {
  /// The goal text the loop received.
  final String goal;

  PlanRequested({
    required super.occurredAt,
    required this.goal,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.requested';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'goal': goal,
      };
}

/// The `planner` role classified the goal into a [PlanKind] (§ 4.2).
final class GoalClassified extends PlanningEvent {
  /// The classified kind.
  final PlanKind planKind;

  GoalClassified({
    required super.occurredAt,
    required this.planKind,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.goal-classified';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'planKind': planKind.token,
      };
}

/// The `decomposer` role produced a step set (§ 4.3).
final class StepsDecomposed extends PlanningEvent {
  /// How many candidate steps were produced.
  final int stepCount;

  StepsDecomposed({
    required super.occurredAt,
    required this.stepCount,
    super.planId,
    super.runId,
    super.causedBy,
  }) {
    if (stepCount < 0) {
      throw ArgumentError.value(stepCount, 'stepCount', 'must be non-negative');
    }
  }

  @override
  String get kind => 'planning.steps-decomposed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'stepCount': stepCount,
      };
}

/// The graph was ordered and cost-rolled-up (§ 4.4).
final class GraphEstimated extends PlanningEvent {
  /// Steps in the ordered graph.
  final int stepCount;

  /// Dependency edges in the ordered graph.
  final int edgeCount;

  GraphEstimated({
    required super.occurredAt,
    required this.stepCount,
    required this.edgeCount,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.graph-estimated';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'stepCount': stepCount,
        'edgeCount': edgeCount,
      };
}

/// The `plan_evaluator` role produced a critique verdict (§ 4.5).
final class PlanCritiqueProduced extends PlanningEvent {
  /// Whether the critique accepted the graph.
  final bool accepted;

  /// The loop iteration this critique belongs to (0-based).
  final int iteration;

  PlanCritiqueProduced({
    required super.occurredAt,
    required this.accepted,
    required this.iteration,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.critique-produced';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'accepted': accepted,
        'iteration': iteration,
      };
}

/// The loop committed a plan — the terminal success (§ 4.1).
final class PlanAccepted extends PlanningEvent {
  /// Steps persisted into the committed plan graph.
  final int stepCount;

  PlanAccepted({
    required super.occurredAt,
    required this.stepCount,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.accepted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'stepCount': stepCount,
      };
}

/// The critique rejected the graph; the loop re-enters (§ 4.6).
final class PlanRejected extends PlanningEvent {
  /// The loop iteration that was rejected (0-based).
  final int iteration;

  /// A short reason string, when the critique supplied one.
  final String? reason;

  PlanRejected({
    required super.occurredAt,
    required this.iteration,
    this.reason,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.rejected';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'iteration': iteration,
        if (reason != null) 'reason': reason,
      };
}

/// A re-plan replaced a plan (or sub-graph) with a new one, structurally
/// (`superseded_by`, never destructive — § 4.7, P4).
final class PlanRevised extends PlanningEvent {
  /// The id of the plan (or step) that was superseded.
  final String supersededId;

  /// The id of the replacement plan (or step).
  final String replacementId;

  PlanRevised({
    required super.occurredAt,
    required this.supersededId,
    required this.replacementId,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.revised';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'supersededId': supersededId,
        'replacementId': replacementId,
      };
}

/// A consumer reported a step status transition (§ 5.2).
final class StepStatusChanged extends PlanningEvent {
  /// The step whose status changed.
  final String stepId;

  /// The prior status, when known.
  final StepStatus? from;

  /// The new status.
  final StepStatus to;

  StepStatusChanged({
    required super.occurredAt,
    required this.stepId,
    required this.to,
    this.from,
    super.planId,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'planning.step-status-changed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        if (planId != null) 'planId': planId,
        'stepId': stepId,
        if (from != null) 'from': from!.token,
        'to': to.token,
      };
}

/// The nine `PlanningEvent.kind` discriminators, in the canonical lifecycle
/// order of `planning_specification.md` § 10.1.
///
/// This list is the single source of truth for the planning observability
/// vocabulary. The `plan_v1` d4rt body emits a subset of these as `note(...)`
/// categories (the body cannot import the typed leaves), so a test pins that
/// the body's literals stay within this set and that each leaf's [kind] getter
/// appears here.
const List<String> planningEventKinds = <String>[
  'planning.requested',
  'planning.goal-classified',
  'planning.steps-decomposed',
  'planning.graph-estimated',
  'planning.critique-produced',
  'planning.accepted',
  'planning.rejected',
  'planning.revised',
  'planning.step-status-changed',
];
