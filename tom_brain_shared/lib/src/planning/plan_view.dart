// PlanView / PlanStepView — typed read-projections over the `Plan` and
// `PlanStep` memory nodes (`planning_specification.md` § 5.1, § 5.2, § 7.4).
//
// Memory stores a plan (and each of its steps) as a generic `Node` whose fields
// live in an untyped `values` map. Every consumer that reads them back — the
// typed queries in `tom_brain_memory` (`OpenPlansFor`, `StepsBlockedBy`,
// `SupersededHistoryOf`, `PlanStepsInOrder`), a Forge plan inspector, the
// `plan_v1` loop reading its own writes — would otherwise repeat the same
// string-key plucking and the same fragile `as`-coercions. These two value
// types pull that decode into one place, loudly: an unparseable `kind` / `status`
// token throws here, at the node boundary, rather than three layers up.
//
// Why these live in shared (not in `tom_brain_memory` or `tom_brain_procedure`):
// the projection is the shape of the stored plan as every layer reads it. Memory
// composes the typed queries on top, the `plan_v1` procedure builds the node
// these project, and a Forge inspector renders them — none owns the shape, so it
// is shared vocabulary (same placement rationale as `ProcedureView`).

import '../embedding/embedding.dart' show Vec;
import '../ids/ids.dart' show NodeId;
import '../memory/nodes/node.dart' show Node;
import 'plan_status.dart';
import 'step_status.dart';

/// The canonical `Plan` node type name — the single source of truth for the
/// string the loop persists under and the typed queries filter on.
const String planNodeTypeName = 'Plan';

/// The canonical `PlanStep` node type name (see [planNodeTypeName]).
const String planStepNodeTypeName = 'PlanStep';

/// The `attrs.kind` marker that distinguishes a `depends-on` dependency edge
/// from any other `part_of` edge between two `PlanStep` nodes
/// (`planning_specification.md` § 5.3; the schema note on the `PlanStep` node).
///
/// A `depends-on` relationship is modelled — per spec, with no new edge label —
/// as a `part_of` edge `dependent —part_of[kind=depends_on]→ dependency`. This
/// marker lets the typed queries (`StepsBlockedBy`, `PlanStepsInOrder`) and the
/// `plan_v1` loop agree on which `part_of` edges are dependencies. The
/// sandboxed `plan_v1` body writes the literal (it cannot import this library),
/// so a test pins the literal against this constant — exactly as
/// `planningEventKinds` anchors the body's `note(...)` categories.
const String dependsOnEdgeKind = 'depends_on';

/// A typed read-projection of a `Plan` node (`planning_specification.md`
/// § 5.1).
final class PlanView {
  /// The node's stable id.
  final NodeId id;

  /// The goal text the planner received.
  final String goal;

  /// One-line summary of the plan, when present.
  final String? summary;

  /// The classified goal kind. `null` when the node predates classification
  /// stamping (the schema field is nullable).
  final PlanKind? kind;

  /// Lifecycle stage. `null` before the loop stamps it.
  final PlanStatus? status;

  /// Confidence in [0,1], same machinery as Claim/Conclusion. `null` when
  /// unstamped.
  final double? confidence;

  /// Provenance — who/what created the plan (the producing procedure id, a
  /// persona). `null` when unstamped.
  final String? createdBy;

  /// The node's stored embedding over (goal || summary), when present.
  final Vec? embedding;

  const PlanView({
    required this.id,
    required this.goal,
    this.summary,
    this.kind,
    this.status,
    this.confidence,
    this.createdBy,
    this.embedding,
  });

  /// Projects a `Plan` [node] into a typed view.
  ///
  /// Throws [ArgumentError] when [node] is not a `Plan`. An unknown `kind` /
  /// `status` token throws via [PlanKind.fromToken] / [PlanStatus.fromToken].
  factory PlanView.fromNode(Node node) {
    if (node.typeName != planNodeTypeName) {
      throw ArgumentError.value(
        node.typeName,
        'node.typeName',
        'PlanView.fromNode expects a "$planNodeTypeName" node',
      );
    }
    final values = node.values;
    final kindToken = values['kind'] as String?;
    final statusToken = values['status'] as String?;
    return PlanView(
      id: node.id,
      goal: values['goal'] as String,
      summary: values['summary'] as String?,
      kind: kindToken == null ? null : PlanKind.fromToken(kindToken),
      status: statusToken == null ? null : PlanStatus.fromToken(statusToken),
      confidence: (values['confidence'] as num?)?.toDouble(),
      createdBy: values['created_by'] as String?,
      embedding: node.embedding,
    );
  }

  /// Whether the plan is still being pursued (`draft` / `active`). A null
  /// status is treated as not-open.
  bool get isOpen => status?.isOpen ?? false;
}

/// A typed read-projection of a `PlanStep` node (`planning_specification.md`
/// § 5.2).
final class PlanStepView {
  /// The node's stable id.
  final NodeId id;

  /// One short imperative phrase describing the step (the node's `description`
  /// fts field — the required text every step carries).
  final String description;

  /// The containing plan's logical/node id, when stamped.
  final String? planId;

  /// Position in the plan's ordered step list, when stamped.
  final int? stepIndex;

  /// A short title, when distinct from [description].
  final String? title;

  /// One paragraph describing what done looks like.
  final String? intent;

  /// The kind of work. `null` when unstamped.
  final StepKind? kind;

  /// Which subsystem (or the user) is expected to execute the step.
  final String? owner;

  /// The observable condition under which the step is done (§ 5.2, P5).
  final String? successCriterion;

  /// Execution stage. `null` before the loop stamps it.
  final StepStatus? status;

  /// The node's stored embedding over (description), when present.
  final Vec? embedding;

  const PlanStepView({
    required this.id,
    required this.description,
    this.planId,
    this.stepIndex,
    this.title,
    this.intent,
    this.kind,
    this.owner,
    this.successCriterion,
    this.status,
    this.embedding,
  });

  /// Projects a `PlanStep` [node] into a typed view.
  ///
  /// Throws [ArgumentError] when [node] is not a `PlanStep`. An unknown
  /// `kind` / `status` token throws via [StepKind.fromToken] /
  /// [StepStatus.fromToken].
  factory PlanStepView.fromNode(Node node) {
    if (node.typeName != planStepNodeTypeName) {
      throw ArgumentError.value(
        node.typeName,
        'node.typeName',
        'PlanStepView.fromNode expects a "$planStepNodeTypeName" node',
      );
    }
    final values = node.values;
    final kindToken = values['kind'] as String?;
    final statusToken = values['status'] as String?;
    return PlanStepView(
      id: node.id,
      description: values['description'] as String,
      planId: values['plan_id'] as String?,
      stepIndex: (values['step_index'] as num?)?.toInt(),
      title: values['title'] as String?,
      intent: values['intent'] as String?,
      kind: kindToken == null ? null : StepKind.fromToken(kindToken),
      owner: values['owner'] as String?,
      successCriterion: values['success_criterion'] as String?,
      status: statusToken == null ? null : StepStatus.fromToken(statusToken),
      embedding: node.embedding,
    );
  }

  /// Whether the step still awaits execution (`pending` / `in_progress`). A
  /// null status is treated as not-open.
  bool get isOpen => status?.isOpen ?? false;
}
