// ProcedureOutcome — the terminal value a `ProcedureRun` resolves to
// (Plan step C.38; `tom_brain_procedure_prototype_specification.md`
// § 10.1, § 8).
//
// A run produces two things over its lifetime: a *stream* of trail
// entries as it unfolds, and one *terminal* outcome when it finishes.
// `ProcedureOutcome` is the latter — the close-out facts the dispatcher
// (and tests) read after `await run.outcome`. It bundles the structural
// status, the procedure's typed result (when it produced one), the
// durable run record the recorder persisted, the full ordered trail, and
// the captured error (when the run crashed). Everything a consumer needs
// without re-reading memory.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TrailEntry, TrailOutcomeStatus;

import '../recorder/run_records.dart';
import 'procedure_result.dart';

/// The terminal result of a procedure run.
///
/// Immutable: [entries] is wrapped unmodifiable on construction. The
/// [status] is the structural outcome the trail closed on; [result] is the
/// procedure's typed output bag when the run produced one (`null` when it
/// was truncated or crashed before returning); [record] is the durable
/// `ProcedureRun` handle the recorder persisted; [error] carries the
/// captured exception when the run crashed.
final class ProcedureOutcome {
  /// Builds the terminal outcome.
  ProcedureOutcome({
    required this.runId,
    required this.procedureId,
    required this.status,
    required this.record,
    required List<TrailEntry> entries,
    this.result,
    this.error,
  }) : entries = List<TrailEntry>.unmodifiable(entries);

  /// The engine-assigned run id.
  final String runId;

  /// The procedure this run executed.
  final String procedureId;

  /// The structural outcome the trail closed on.
  final TrailOutcomeStatus status;

  /// The durable run record (node id, trail id, effort) the recorder
  /// persisted to `recent_runs`.
  final ProcedureRunRecord record;

  /// The full, ordered trail the run wrote — `invocation` first, every
  /// note / primitive call in order, `outcome` last.
  final List<TrailEntry> entries;

  /// The procedure's typed result, or `null` when the run did not return a
  /// usable one (truncated by the step deadline, or crashed).
  final ProcedureResult? result;

  /// The captured exception when the run crashed; `null` otherwise.
  final Object? error;

  /// Whether the run closed on an accepted result.
  bool get isSuccess => status == TrailOutcomeStatus.accepted;

  @override
  String toString() =>
      'ProcedureOutcome($procedureId/$runId → ${status.name})';
}
