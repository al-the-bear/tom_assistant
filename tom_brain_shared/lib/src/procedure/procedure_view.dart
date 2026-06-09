// ProcedureView / ProcedureRunView — typed read-projections over the `Procedure`
// and `ProcedureRun` memory nodes (`procedure_specification.md` § 7.1, § 9.2).
//
// Memory stores a procedure (and each of its runs) as a generic `Node` whose
// fields live in an untyped `values` map. Every consumer that reads them back —
// the typed queries in `tom_brain_memory` (`CandidateProceduresFor`,
// `ProcedureRunsOf`, `ProcedureRevisionChain`), the selector re-rank, a Forge
// inspector — would otherwise repeat the same string-key plucking and the same
// fragile `as`-coercions. These two value types pull that decode into one place,
// loudly: an unparseable `status` token or a malformed timestamp throws here,
// at the node boundary, rather than surfacing as a confusing failure three
// layers up.
//
// Why these live in shared (not in `tom_brain_memory` or `tom_brain_procedure`):
// the projection is the shape of the stored procedure as every layer reads it.
// Memory composes the typed queries on top, the procedure engine's authoring
// loop builds the node these project, and a Forge inspector renders them — none
// owns the shape, so it is shared vocabulary (procedure spec § 14, the same
// placement rationale as `ProcedureStatus` / `CapabilitySet`).

import '../embedding/embedding.dart' show Vec;
import '../ids/ids.dart' show NodeId;
import '../memory/nodes/node.dart' show Node;
import 'capability_set.dart';
import 'procedure_status.dart';

/// The canonical `Procedure` node type name. The single source of truth for the
/// string both the authoring loop persists under and the typed queries filter
/// on, so a rename is one edit rather than a scatter of string literals.
const String procedureNodeTypeName = 'Procedure';

/// The canonical `ProcedureRun` node type name (see [procedureNodeTypeName]).
const String procedureRunNodeTypeName = 'ProcedureRun';

/// A typed read-projection of a `Procedure` node (`procedure_specification.md`
/// § 7.1).
///
/// Carries only the fields a reader needs to rank, gate, and present a
/// procedure. The verbatim d4rt `source` (`code` field) is deliberately *not*
/// projected here — ranking and presentation never need the body, and pulling
/// it would make every candidate-list read drag the full source text. A caller
/// that needs the body reads the `code` field off the underlying [Node] it
/// already holds.
final class ProcedureView {
  /// The node's stable id.
  final NodeId id;

  /// The logical procedure id (e.g. `answer_with_memory_v1`) — stored in the
  /// node's `name` field and matched against `ProcedureRun.procedureId`.
  final String name;

  /// One-line summary of what the procedure does, when present.
  final String? summary;

  /// Lifecycle stage. `null` when the node predates lifecycle stamping (the
  /// schema fields are nullable); the re-rank treats a null status as
  /// not-retrievable.
  final ProcedureStatus? status;

  /// Revision number within this logical id's `superseded_by` chain. `null`
  /// before the authoring loop stamps it.
  final int? revision;

  /// The bridged-API capabilities the procedure's header declares. Empty when
  /// the node carries no `requires` list (a procedure that needs nothing).
  final CapabilitySet requires;

  /// Rolling success rate in [0,1], computed by the Synthesizer sleep pass from
  /// the run history. `null` before the first metrics pass.
  final double? successRate;

  /// Number of recorded runs, cached by the metrics pass. `null` before it.
  final int? runCount;

  /// Timestamp of the last successful run (UTC). `null` when never run.
  final DateTime? lastRunAt;

  /// Timestamp the authoring loop recorded (UTC). `null` when unstamped.
  final DateTime? authoredAt;

  /// The node's stored embedding over (intent || inputs || requires), when the
  /// type carries one.
  final Vec? embedding;

  const ProcedureView({
    required this.id,
    required this.name,
    required this.requires,
    this.summary,
    this.status,
    this.revision,
    this.successRate,
    this.runCount,
    this.lastRunAt,
    this.authoredAt,
    this.embedding,
  });

  /// Projects a `Procedure` [node] into a typed view.
  ///
  /// Throws [ArgumentError] when [node] is not a `Procedure` — projecting the
  /// wrong type is a programmer error, surfaced loudly rather than producing a
  /// silently-wrong view. An unknown `status` token throws via
  /// [ProcedureStatus.fromToken]; a malformed timestamp throws via
  /// [DateTime.parse].
  factory ProcedureView.fromNode(Node node) {
    if (node.typeName != procedureNodeTypeName) {
      throw ArgumentError.value(
        node.typeName,
        'node.typeName',
        'ProcedureView.fromNode expects a "$procedureNodeTypeName" node',
      );
    }
    final values = node.values;
    final statusToken = values['status'] as String?;
    final requiresList = (values['requires'] as List?)?.cast<String>();
    return ProcedureView(
      id: node.id,
      name: values['name'] as String,
      summary: values['summary'] as String?,
      status:
          statusToken == null ? null : ProcedureStatus.fromToken(statusToken),
      revision: (values['revision'] as num?)?.toInt(),
      requires: CapabilitySet.fromIterable(requiresList ?? const <String>[]),
      successRate: (values['successRate'] as num?)?.toDouble(),
      runCount: (values['runCount'] as num?)?.toInt(),
      lastRunAt: _parseUtc(values['lastRunAt']),
      authoredAt: _parseUtc(values['authoredAt']),
      embedding: node.embedding,
    );
  }

  /// Whether default retrieval would surface this procedure — `active` or
  /// `preferred` only (a null status is never retrievable).
  bool get isRetrievable => status?.isRetrievable ?? false;
}

/// A typed read-projection of a `ProcedureRun` node (`procedure_specification.md`
/// § 9.2 — the run-history record the `RunRecorder` writes).
final class ProcedureRunView {
  /// The run node's stable id.
  final NodeId id;

  /// The logical id of the procedure this run executed.
  final String procedureId;

  /// The procedure revision this run executed, when recorded.
  final int? version;

  /// The run's own id (`engine:<procedureId>:<runId>` provenance).
  final String runId;

  /// The parent run id when this run was dispatched by another, else `null`.
  final String? parentRunId;

  /// The run status token (`running`, then the authoritative final token).
  final String status;

  /// One-line outcome summary; `null` on the start marker.
  final String? summary;

  /// When the run started (UTC).
  final DateTime startedAt;

  /// When the run finished (UTC); `null` on the start marker.
  final DateTime? finishedAt;

  /// The run's accumulated effort metrics, as recorded; `null` on the start
  /// marker.
  final Map<String, Object?>? effort;

  /// Ids of the nodes the run produced; empty on the start marker.
  final List<NodeId> producedNodeIds;

  /// The id of the run's trail JSONL.
  final String trailId;

  const ProcedureRunView({
    required this.id,
    required this.procedureId,
    required this.runId,
    required this.status,
    required this.startedAt,
    required this.trailId,
    required this.producedNodeIds,
    this.version,
    this.parentRunId,
    this.summary,
    this.finishedAt,
    this.effort,
  });

  /// Projects a `ProcedureRun` [node] into a typed view.
  ///
  /// Throws [ArgumentError] when [node] is not a `ProcedureRun`.
  factory ProcedureRunView.fromNode(Node node) {
    if (node.typeName != procedureRunNodeTypeName) {
      throw ArgumentError.value(
        node.typeName,
        'node.typeName',
        'ProcedureRunView.fromNode expects a "$procedureRunNodeTypeName" node',
      );
    }
    final values = node.values;
    final producedIds = (values['producedNodeIds'] as List?)
            ?.cast<String>()
            .map(NodeId.fromString)
            .toList(growable: false) ??
        const <NodeId>[];
    final effort = values['effort'];
    return ProcedureRunView(
      id: node.id,
      procedureId: values['procedureId'] as String,
      version: (values['version'] as num?)?.toInt(),
      runId: values['runId'] as String,
      parentRunId: values['parentRunId'] as String?,
      status: values['status'] as String,
      summary: values['summary'] as String?,
      startedAt: _parseUtc(values['startedAt'])!,
      finishedAt: _parseUtc(values['finishedAt']),
      effort: effort is Map ? Map<String, Object?>.from(effort) : null,
      producedNodeIds: producedIds,
      trailId: values['trailId'] as String,
    );
  }
}

/// Parses an ISO-8601 timestamp [value] into a UTC [DateTime], or `null` when
/// [value] is `null`. Throws [FormatException] (via [DateTime.parse]) on a
/// malformed string — a corrupt timestamp is a loud failure, not a silent drop.
DateTime? _parseUtc(Object? value) {
  if (value == null) return null;
  return DateTime.parse(value as String).toUtc();
}
