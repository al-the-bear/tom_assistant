/// @procedure
/// id: dream_procedure_metrics_v1
/// version: 1
/// summary: Recompute each Procedure's rolling success metrics from its
///   immutable run history and move its lifecycle stage (active ⇄ preferred,
///   or demote a repeatedly-failing one).
/// successCriterion: For every retrievable Procedure with finished runs, the
///   cached successRate / runCount / lastRunAt are refreshed from the
///   ProcedureRun history, and any earned active→preferred / lapsed
///   preferred→active / failing-demotion transition is applied.
/// budget: { wallClockMs: 60000, tokenSpend: 0, toolCalls: 0, memoryWrites: 256 }
/// inputs:
///   - { name: promoteSuccessRate, type: double, required: false }
///   - { name: promoteMinRuns, type: int, required: false }
///   - { name: demoteSuccessRate, type: double, required: false }
///   - { name: demoteMinRuns, type: int, required: false }
///   - { name: scanLimit, type: int, required: false }
/// outputs:
///   - { name: reviewed, type: int }
///   - { name: promoted, type: int }
///   - { name: demoted, type: int }
/// requires: [ recallMulti, updateProcedureMetrics, demote, note ]
//
// dream_procedure_metrics_v1 — the procedure metrics-pass agent (G-PR5;
// `procedure_specification.md` § 6.4 / § 7.1 / § 14; memory § 9 Synthesiser
// sleep cadence).
//
// ── Why a dedicated agent, not folded into dream_synthesise_v1 ───────
//
// The Synthesiser's job is Claims → Conclusion; its write scope is narrow
// (node:Conclusion, edge:derived_from) on purpose. Procedure promotion is an
// unrelated concern with a different write surface (the in-place metric cache
// + node-lifecycle demote), so it lives in its own agent that runs *alongside*
// the Synthesiser in the same sleep cadence (§ 6.4). Keeping it separate keeps
// each agent's write scope minimal and its success criterion single.
//
// ── What it does, per retrievable Procedure ─────────────────────────
//
//   1. Read the procedure's run history — a symbolic recall over ProcedureRun
//      nodes filtered on `procedureId == <logical id>` (mirrors the typed
//      `ProcedureRunsOf` query, § 10.3, but assembled as a recallMulti seed
//      because that is the only enumerate-by-attribute path a d4rt body has).
//   2. Compute the rolling metrics from the *finished* runs: runCount (runs
//      with a finishedAt), successRate (fraction whose terminal status token is
//      `accepted` — the prototype's success token, spec's abstract "succeeded"),
//      and lastRunAt (the newest finished run's timestamp; ISO-8601 `…Z`
//      timestamps sort lexically, so the max string is the latest instant —
//      no DateTime parsing needed in the body).
//   3. Decide the stage, in precedence order:
//        - demote (failing): runCount ≥ demoteMinRuns and successRate ≤
//          demoteSuccessRate → node-lifecycle `demote` (drops out of default
//          retrieval, stays queryable by id and present in backup; never
//          deleted — hard principle 6);
//        - promote: stage `active`, runCount ≥ promoteMinRuns and successRate ≥
//          promoteSuccessRate → `preferred` (earned trust);
//        - lapse: stage `preferred` and successRate < promoteSuccessRate →
//          back to `active` (trust is not permanent);
//        - else: no stage change, only the counters are refreshed.
//   4. Write back the cached counters (and any active ⇄ preferred stage token)
//      through the narrow `updateProcedureMetrics` memory write; demotion goes
//      through the shared `demote`.
//
// ── Why the cache write is sound (hard principle 6) ─────────────────
//
// The immutable record is the ProcedureRun history, which is never touched and
// from which these metrics are always recomputable. The Procedure node's
// status / successRate / runCount / lastRunAt are a derived cache in the
// explicitly-mutable procedural layer; refreshing them touches no episodic
// (immutable) memory. `updateProcedureMetrics` refuses any non-Procedure node,
// so the cache write can never be turned against a Claim/Event.
//
// ── Scope ───────────────────────────────────────────────────────────
//
// Both writes this agent issues — `updateProcedureMetrics` (cache) and `demote`
// (lifecycle) — mutate status/cache, not the node/edge graph, so neither
// carries an agent write scope and the agent registers with an *empty*
// write-scope set (like the Pruner, memory § 9.5). Any attempt to persist a
// node or draw an edge would be rejected with AgentScopeViolation; this body
// issues neither, so it stays accepted.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  // Inline policy — a d4rt body cannot reach the tom_core_agentic thresholds,
  // so the arithmetic and its defaults live here; each is overridable per
  // invocation (the metrics-pass schedule can tune them without a re-deploy).
  final promoteSuccessRate = _doubleArg(inputs, 'promoteSuccessRate', 0.8);
  final promoteMinRuns = _intArg(inputs, 'promoteMinRuns', 5);
  final demoteSuccessRate = _doubleArg(inputs, 'demoteSuccessRate', 0.3);
  final demoteMinRuns = _intArg(inputs, 'demoteMinRuns', 5);
  final scanLimit = _intArg(inputs, 'scanLimit', 256);

  // 1. Enumerate the Procedure nodes. A symbolic type-filter seed is the only
  //    enumerate-by-type path a d4rt body has (recall does not take a filter).
  final procResult = await mem.recallMulti(
    <Object?>[
      <String, Object?>{
        'mode': 'symbolic',
        'filter': <String, Object?>{
          'typeNames': <String>['Procedure'],
        },
      },
    ],
    k: scanLimit,
  );

  var reviewed = 0;
  var promoted = 0;
  var demotedCount = 0;

  final procNodes = procResult['nodes'];
  if (procNodes is List) {
    for (final procNode in procNodes) {
      if (procNode is! Map || procNode['typeName'] != 'Procedure') continue;
      final nodeId = procNode['id'];
      final values = procNode['values'];
      if (nodeId is! String || values is! Map) continue;

      final logicalId = values['name'];
      final stage = values['status'];
      if (logicalId is! String) continue;
      // Only retrievable stages are subject to the pass. authored/draft are
      // pre-run, demoted is already out — none should be (re)promoted here.
      if (stage != 'active' && stage != 'preferred') continue;

      // 2. Read this procedure's run history and fold the finished runs.
      final runResult = await mem.recallMulti(
        <Object?>[
          <String, Object?>{
            'mode': 'symbolic',
            'filter': <String, Object?>{
              'typeNames': <String>['ProcedureRun'],
              'attributes': <Object?>[
                <String, Object?>{
                  'field': 'procedureId',
                  'op': 'eq',
                  'value': logicalId,
                },
              ],
            },
          },
        ],
        k: scanLimit,
      );

      var runCount = 0;
      var successCount = 0;
      String? lastRunAt;
      final runNodes = runResult['nodes'];
      if (runNodes is List) {
        for (final runNode in runNodes) {
          if (runNode is! Map || runNode['typeName'] != 'ProcedureRun') {
            continue;
          }
          final runValues = runNode['values'];
          if (runValues is! Map) continue;
          final finishedAt = runValues['finishedAt'];
          // A run without a finishedAt is the in-flight start marker — not yet
          // part of the history the metrics are computed from.
          if (finishedAt is! String || finishedAt.isEmpty) continue;
          runCount++;
          if (runValues['status'] == 'accepted') successCount++;
          if (lastRunAt == null || finishedAt.compareTo(lastRunAt) > 0) {
            lastRunAt = finishedAt;
          }
        }
      }

      // No finished runs yet → no metric to compute and nothing to decide.
      if (runCount == 0) continue;
      reviewed++;
      final successRate = successCount / runCount;

      // 3. Decide the stage. Demotion takes precedence over promotion.
      if (runCount >= demoteMinRuns && successRate <= demoteSuccessRate) {
        // Refresh the counters for the audit trail, then drop it out of default
        // retrieval. `demote` keeps it queryable by id and in backup.
        await mem.updateProcedureMetrics(
          nodeId,
          successRate: successRate,
          runCount: runCount,
          lastRunAt: lastRunAt,
        );
        await mem.demote(nodeId, 'prunerDecision');
        demotedCount++;
        continue;
      }

      String? newStage;
      if (stage == 'active' &&
          runCount >= promoteMinRuns &&
          successRate >= promoteSuccessRate) {
        newStage = 'preferred';
        promoted++;
      } else if (stage == 'preferred' && successRate < promoteSuccessRate) {
        // Trust is not permanent — a preferred procedure whose rolling rate has
        // fallen back below the bar returns to plain active.
        newStage = 'active';
      }

      // 4. Write back the counters, plus the active ⇄ preferred stage token when
      //    it changed. A null status leaves the stage untouched.
      await mem.updateProcedureMetrics(
        nodeId,
        status: newStage,
        successRate: successRate,
        runCount: runCount,
        lastRunAt: lastRunAt,
      );
    }
  }

  note('progress', {
    'agent': 'dream_procedure_metrics_v1',
    'reviewed': reviewed,
    'promoted': promoted,
    'demoted': demotedCount,
  });

  // The metrics pass creates no nodes — it only refreshes a derived cache and
  // moves lifecycle stages, so there are no produced nodes to thread.
  return <String, Object?>{
    'reviewed': reviewed,
    'promoted': promoted,
    'demoted': demotedCount,
    'producedNodeIds': <Object?>[],
  };
}

/// Reads a double-valued input named [name], or [fallback] when absent /
/// non-numeric — the body's inline policy is robust to a missing override.
double _doubleArg(ProcedureInputs inputs, String name, double fallback) {
  if (!inputs.has(name)) return fallback;
  final v = inputs.get(name);
  return v is num ? v.toDouble() : fallback;
}

/// Reads an int-valued input named [name], or [fallback] when absent /
/// non-numeric.
int _intArg(ProcedureInputs inputs, String name, int fallback) {
  if (!inputs.has(name)) return fallback;
  final v = inputs.get(name);
  return v is num ? v.toInt() : fallback;
}
