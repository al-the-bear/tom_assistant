// The Dreaming-cycle monitor projection (Module 3, `prompt_tracing.md` § 5A) —
// the turn-less background dream/sleep runs, grouped by cadence lane and drilled
// into with the *same* run-tree the prompt trace uses for a user turn.
//
// This introduces no new persisted model: a dream run is a [ProcedureRun] with a
// null `turnId` (§ 3.6) read from the same `procedures/` trail (§ 8.1). These
// DTOs are the wire shapes for the three `/api/dream/*` read routes (§ 8.3 (14)).
// Optional fields are omitted when absent so the JSON mirrors what the trail
// actually carried (§ 3.1 — losses surface as missing keys, never fabricated
// `null`s).

import 'run_tree.dart';

/// One cadence lane in the lane selector (`prompt_tracing.md` § 5A.2). The
/// lane→agent grouping is the canonical `CadenceSchedule` (`tom_brain_run`); the
/// synthetic `other` lane (§ 5A.2) collects any dream agent no configured lane
/// claims, so no run is ever hidden.
final class DreamLane {
  /// The stable lane id (`fast` / `slow` / `deep` / `monthly`, or `other`).
  final String id;

  /// The agent procedure ids this lane fires, in fire order.
  final List<String> agents;

  /// How many recent dream runs currently fall into this lane.
  final int runCount;

  DreamLane({
    required this.id,
    required this.runCount,
    List<String> agents = const <String>[],
  }) : agents = List<String>.unmodifiable(agents);

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'agents': agents,
        'runCount': runCount,
      };
}

/// One row of the dream-run list (`prompt_tracing.md` § 5A.2) — the per-run
/// summary, the dreaming-side mirror of [PromptListRow] (§ 4.1). A dream run has
/// no `turnId` and no inbound record, so it is keyed by its [runId] alone.
final class DreamRunRow {
  /// The run correlation id (the bare log basename stem, no `__`).
  final String runId;

  /// The agent that ran (the procedure id / directory it logged under).
  final String procedureId;

  /// The cadence lane this run belongs to (`other` when no configured lane
  /// claims [procedureId]).
  final String laneId;

  /// The recorded instant (the log file's modification time), the list's
  /// newest-first sort key, or `null` when unavailable.
  final DateTime? recordedAt;

  /// The terminal outcome status (`accepted` / `errored` / …), or `null` for an
  /// in-flight run with no completed outcome line.
  final String? outcomeStatus;

  /// The run's wall-clock elapsed in milliseconds, or `null`.
  final int? elapsedMs;

  /// The count of LLM calls across the whole run-tree.
  final int llmCallCount;

  /// The count of memory/primitive accesses (non-`llm` primitive calls) across
  /// the whole run-tree.
  final int memoryAccessCount;

  const DreamRunRow({
    required this.runId,
    required this.procedureId,
    required this.laneId,
    required this.llmCallCount,
    required this.memoryAccessCount,
    this.recordedAt,
    this.outcomeStatus,
    this.elapsedMs,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'runId': runId,
        'procedureId': procedureId,
        'laneId': laneId,
        if (recordedAt != null) 'recordedAt': recordedAt!.toIso8601String(),
        if (outcomeStatus != null) 'outcomeStatus': outcomeStatus,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        'llmCallCount': llmCallCount,
        'memoryAccessCount': memoryAccessCount,
      };
}

/// One drilled-in dream run (`prompt_tracing.md` § 5A.4) — the run-tree detail.
/// The dreaming-side analogue of a `PromptTrace`'s Run-Tree section, minus the
/// Inbound / Configuration / Reply sections a turn-less run has no source for.
final class DreamRun {
  /// The run correlation id.
  final String runId;

  /// The agent that ran.
  final String procedureId;

  /// The cadence lane this run belongs to (`other` when unclaimed).
  final String laneId;

  /// The full § 3.6 procedure run-tree (the § 4.4 run-tree view's root).
  final ProcedureRun run;

  const DreamRun({
    required this.runId,
    required this.procedureId,
    required this.laneId,
    required this.run,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'runId': runId,
        'procedureId': procedureId,
        'laneId': laneId,
        'run': run.toJson(),
      };
}
