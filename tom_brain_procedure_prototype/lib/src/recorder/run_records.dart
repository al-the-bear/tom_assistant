// Value types for the run recorder (Plan step C.31;
// `tom_brain_procedure_prototype_specification.md` § 8).
//
// These are the inputs and the output of `RunRecorder`'s lifecycle:
// `RunStart` (the launch facts captured when a procedure begins),
// `RunCompletion` (the close-out facts the engine hands back), and
// `ProcedureRunRecord` (the durable handle the recorder produces). The
// well-known names (`inflight`, `recent_runs`, the `ProcedureRun` node
// type) live here too — they are the contract the recorder shares with
// the bootstrap memory schema (`tom_brain_memory` bootstrap node type
// #13 `ProcedureRun`; the `inflight` / `recent_runs` bootstrap stacks).

import 'package:tom_brain_memory/tom_brain_memory.dart' show TrailOutcomeStatus;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EffortMetrics, NodeId, TrailId;

// The well-known bootstrap-schema names the recorder shares with memory
// (`inflight` / `recent_runs` stacks, `ProcedureRun` node type — memory
// bootstrap node type #13) are owned by `tom_brain_memory` and re-exported
// here so the prototype's recorder and dispatcher consume a single source of
// truth (E.2). Re-exported rather than merely imported so the existing
// consumers that import these names from `run_records.dart` keep working.
export 'package:tom_brain_memory/tom_brain_memory.dart'
    show inflightStackName, procedureRunNodeType, recentRunsStackName;

/// The launch facts captured when a procedure run begins.
///
/// The engine assigns [runId] before the recorder is involved (the run
/// identity spans more than memory — see `ProcedureRunRef`). [version]
/// is the resolved procedure version. [procedureNodeId], when the
/// procedure is a brain-authored memory `Procedure` node, lets the
/// recorder draw the `derived_from` edge at completion; for disk-shipped
/// procedures it is `null` and no edge is drawn (see Q-C.31.2).
final class RunStart {
  /// Procedure id (e.g. `answer_with_memory_v1`).
  final String procedureId;

  /// Resolved procedure version.
  final int version;

  /// Opaque engine-assigned run id.
  final String runId;

  /// Parent run id when dispatched from another procedure; `null` for
  /// top-level runs.
  final String? parentRunId;

  /// Bound argument map, written to the trail's `invocation` entry.
  final Map<String, Object?> arguments;

  /// Memory node id of the procedure, when it is a memory-resident
  /// `Procedure` node. `null` for disk-shipped procedures.
  final NodeId? procedureNodeId;

  /// Builds the launch facts.
  const RunStart({
    required this.procedureId,
    required this.version,
    required this.runId,
    this.parentRunId,
    this.arguments = const <String, Object?>{},
    this.procedureNodeId,
  });
}

/// The close-out facts the engine hands the recorder when a run finishes.
///
/// [status] is the structural outcome (reused from memory's
/// `TrailOutcomeStatus`); [summary] is the one-line human-readable
/// outcome surfaced in `recent_runs` peeks; [effort] is the final
/// effort-metric set (accumulated by C.32); [producedNodeIds] are the
/// result nodes the run wrote, each of which gets a `produced_by` edge
/// back to the run record.
final class RunCompletion {
  /// Structural outcome.
  final TrailOutcomeStatus status;

  /// One-line human-readable outcome.
  final String summary;

  /// Final effort-metric set.
  final EffortMetrics effort;

  /// Ids of result nodes the run produced.
  final List<String> producedNodeIds;

  /// Optional structured detail merged into the trail outcome.
  final Map<String, Object?> details;

  /// Builds the close-out facts.
  const RunCompletion({
    required this.status,
    required this.summary,
    this.effort = EffortMetrics.zero,
    this.producedNodeIds = const <String>[],
    this.details = const <String, Object?>{},
  });
}

/// The durable handle a finished run resolves to.
///
/// Returned by `RunRecorder.complete`. Carries the id of the persisted
/// final `ProcedureRun` node, the trail it closed, and the final
/// structural facts so the engine API (C.38) can surface them without
/// re-reading memory.
final class ProcedureRunRecord {
  /// Id of the persisted final `ProcedureRun` node (the one that lands
  /// in `recent_runs`).
  final NodeId runNodeId;

  /// The trail this run wrote and closed.
  final TrailId trailId;

  /// Procedure id this run executed.
  final String procedureId;

  /// Opaque engine-assigned run id.
  final String runId;

  /// Structural outcome.
  final TrailOutcomeStatus status;

  /// Final effort-metric set.
  final EffortMetrics effort;

  /// Builds the handle.
  const ProcedureRunRecord({
    required this.runNodeId,
    required this.trailId,
    required this.procedureId,
    required this.runId,
    required this.status,
    required this.effort,
  });
}
