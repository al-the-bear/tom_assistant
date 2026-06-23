// The client-side DTOs for the Module-3 dreaming-cycle monitor (§ 5A), decoded
// from the `/api/dream/*` JSON contract (§ 8.3 (14)). Like the prompt-trace
// DTOs these mirror the server's `tom_brain_observatory/lib/src/model/
// dream_run.dart` shapes but are a *separate* decoding surface — the web app
// consumes the JSON, it does not import the server package (dart2js constraint).
//
// A dream run reuses the very [ProcedureRun] the prompt trace uses (§ 3.6): a
// turn-less run with a null `turnId`, so the same recursive run-tree view
// renders both. Optional fields decode to `null` when the key is absent — the
// contract omits keys the trail did not carry (§ 3.1), never fabricates them.

import 'prompt_trace.dart';

/// One cadence lane in the lane selector (§ 5A.2) — the body element of
/// `GET /api/dream/lanes`. The `other` lane (synthetic) collects any dream agent
/// no configured lane claims, so no run is ever hidden.
class DreamLane {
  /// The stable lane id (`fast` / `slow` / `deep` / `monthly`, or `other`).
  final String id;

  /// The agent procedure ids this lane fires, in fire order (empty for `other`).
  final List<String> agents;

  /// How many recent dream runs currently fall into this lane.
  final int runCount;

  const DreamLane({
    required this.id,
    required this.agents,
    required this.runCount,
  });

  factory DreamLane.fromJson(Map<String, dynamic> json) => DreamLane(
        id: json['id'] as String,
        agents: <String>[
          for (final a in (json['agents'] as List<dynamic>? ?? const <dynamic>[]))
            a as String,
        ],
        runCount: json['runCount'] as int? ?? 0,
      );
}

/// One row of the dream-run list (§ 5A.2) — the dreaming-side mirror of
/// [PromptListRow]. A dream run has no `turnId`, so it is keyed by [runId] alone.
class DreamRunRow {
  final String runId;
  final String procedureId;
  final String laneId;
  final DateTime? recordedAt;
  final String? outcomeStatus;
  final int? elapsedMs;
  final int llmCallCount;
  final int memoryAccessCount;

  const DreamRunRow({
    required this.runId,
    required this.procedureId,
    required this.laneId,
    required this.recordedAt,
    required this.outcomeStatus,
    required this.elapsedMs,
    required this.llmCallCount,
    required this.memoryAccessCount,
  });

  factory DreamRunRow.fromJson(Map<String, dynamic> json) => DreamRunRow(
        runId: json['runId'] as String,
        procedureId: json['procedureId'] as String,
        laneId: json['laneId'] as String,
        recordedAt: _maybeDate(json['recordedAt']),
        outcomeStatus: json['outcomeStatus'] as String?,
        elapsedMs: json['elapsedMs'] as int?,
        llmCallCount: json['llmCallCount'] as int? ?? 0,
        memoryAccessCount: json['memoryAccessCount'] as int? ?? 0,
      );
}

/// One drilled-in dream run (§ 5A.4) — the run-tree detail, the body of
/// `GET /api/dream/runs/{runId}`. The dreaming-side analogue of a `PromptTrace`'s
/// Run-Tree section, minus the Inbound / Configuration / Reply a turn-less run
/// has no source for.
class DreamRun {
  final String runId;
  final String procedureId;
  final String laneId;
  final ProcedureRun run;

  const DreamRun({
    required this.runId,
    required this.procedureId,
    required this.laneId,
    required this.run,
  });

  factory DreamRun.fromJson(Map<String, dynamic> json) => DreamRun(
        runId: json['runId'] as String,
        procedureId: json['procedureId'] as String,
        laneId: json['laneId'] as String,
        run: ProcedureRun.fromJson(json['run'] as Map<String, dynamic>),
      );
}

DateTime? _maybeDate(Object? value) =>
    value == null ? null : DateTime.parse(value as String);
