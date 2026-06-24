// Builds the Module 3 dreaming-cycle views (`prompt_tracing.md` § 5A) from the
// turn-less dream-run logs under `procedures/` (§ 5A.3). Three builders back the
// three `/api/dream/*` routes (§ 8.3 (14)):
//
//   * [dreamLanes]     → the lane selector (§ 5A.2)   → `GET /api/dream/lanes`
//   * [dreamRunRows]   → the run list (§ 5A.2)        → `GET /api/dream/runs`
//   * [dreamRunFor]    → one run-tree detail (§ 5A.4) → `GET /api/dream/runs/{id}`
//
// The lane→agent grouping is the canonical `CadenceSchedule` (`tom_brain_run`),
// consulted rather than re-declared, so the monitor cannot drift from the
// driver's lanes. An agent no configured lane claims falls into the synthetic
// `other` lane (§ 5A.2) so no run is ever hidden. This adds no new data source —
// every read is a fresh parse of the immutable trail (§ 8.3).

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_brain_run/tom_brain_run.dart'
    show CadenceSchedule, DreamLaneSpec;

import '../model/dream_run.dart';
import 'run_tree_parser.dart';
import 'run_tree_walk.dart';
import 'trail_host.dart';

/// The synthetic lane id collecting dream agents no configured lane claims
/// (`prompt_tracing.md` § 5A.2).
const String otherDreamLane = 'other';

/// The configured cadence lanes for [host], each with its agent set and the
/// count of recent dream runs that fall into it (§ 5A.2). The lanes come from
/// [schedule] (defaulting to the canonical `CadenceSchedule.defaults()`); a
/// synthetic [otherDreamLane] is appended **only when** at least one discovered
/// dream run maps to no configured lane, so the selector never shows an empty
/// `other`.
List<DreamLane> dreamLanes(TrailHost host, {CadenceSchedule? schedule}) {
  if (host.isUnconfigured) return const <DreamLane>[];
  final lanes = (schedule ?? CadenceSchedule.defaults()).lanes;
  final agentToLane = _agentToLane(lanes);

  final countByLane = <String, int>{for (final lane in lanes) lane.id: 0};
  var otherCount = 0;
  for (final log in host.dreamRunLogs()) {
    final procedureId = _procedureIdOf(log);
    final laneId = agentToLane[procedureId];
    if (laneId == null) {
      otherCount++;
    } else {
      countByLane[laneId] = countByLane[laneId]! + 1;
    }
  }

  return <DreamLane>[
    for (final lane in lanes)
      DreamLane(
        id: lane.id,
        agents: lane.agents,
        runCount: countByLane[lane.id]!,
      ),
    if (otherCount > 0)
      DreamLane(id: otherDreamLane, runCount: otherCount),
  ];
}

/// The recent dream-run rows for [host], newest-first (§ 5A.2). When [lane] is
/// given, only runs in that lane are returned (including `other`); otherwise all
/// lanes are interleaved. [host.dreamRunLogs] already orders newest-first.
List<DreamRunRow> dreamRunRows(
  TrailHost host, {
  String? lane,
  CadenceSchedule? schedule,
}) {
  final agentToLane = _agentToLane((schedule ?? CadenceSchedule.defaults()).lanes);
  final rows = <DreamRunRow>[];
  for (final log in host.dreamRunLogs()) {
    final procedureId = _procedureIdOf(log);
    final laneId = agentToLane[procedureId] ?? otherDreamLane;
    if (lane != null && lane != laneId) continue;
    final run = parseRunTree(log.readAsStringSync());
    if (run == null) continue;
    rows.add(DreamRunRow(
      runId: run.runId,
      procedureId: procedureId,
      laneId: laneId,
      recordedAt: log.statSync().modified,
      outcomeStatus: run.status,
      elapsedMs: run.elapsedMs,
      llmCallCount: llmCallCount(run),
      memoryAccessCount: memoryAccessCount(run),
    ));
  }
  return rows;
}

/// One drilled-in dream run by [runId] (§ 5A.4), or `null` when no turn-less log
/// with that id exists (→ `404`).
DreamRun? dreamRunFor(
  TrailHost host,
  String runId, {
  CadenceSchedule? schedule,
}) {
  final log = host.dreamRunLog(runId);
  if (log == null) return null;
  final run = parseRunTree(log.readAsStringSync());
  if (run == null) return null;
  final procedureId = _procedureIdOf(log);
  final agentToLane = _agentToLane((schedule ?? CadenceSchedule.defaults()).lanes);
  return DreamRun(
    runId: run.runId,
    procedureId: procedureId,
    laneId: agentToLane[procedureId] ?? otherDreamLane,
    run: run,
  );
}

/// The single newest turn-less dream-run log for [host] (§ 5A.5), optionally
/// confined to [lane] (matching `other` for an unclaimed agent), or `null` when
/// no dream run exists for the filter. The dreaming-side live-tail
/// ([tailNewestDreamRun]) follows this run — under Hard principle 10 (one
/// background task at a time) the newest run *is* the active one.
/// [host.dreamRunLogs] already orders newest-first.
File? newestDreamRunLog(
  TrailHost host, {
  String? lane,
  CadenceSchedule? schedule,
}) {
  final agentToLane = _agentToLane((schedule ?? CadenceSchedule.defaults()).lanes);
  for (final log in host.dreamRunLogs()) {
    if (lane == null) return log;
    final laneId = agentToLane[_procedureIdOf(log)] ?? otherDreamLane;
    if (laneId == lane) return log;
  }
  return null;
}

/// Maps each agent procedure id to the id of the lane that fires it, keeping the
/// **first** lane when an agent appears in more than one (not the case in the
/// defaults, but resolved deterministically). Lanes are walked in fire order.
Map<String, String> _agentToLane(List<DreamLaneSpec> lanes) {
  final map = <String, String>{};
  for (final lane in lanes) {
    for (final agent in lane.agents) {
      map.putIfAbsent(agent, () => lane.id);
    }
  }
  return map;
}

/// The procedure id a dream-run [log] belongs to — its parent directory name
/// (`procedures/<procedureId>/<runId>.log`).
String _procedureIdOf(File log) => p.basename(log.parent.path);
