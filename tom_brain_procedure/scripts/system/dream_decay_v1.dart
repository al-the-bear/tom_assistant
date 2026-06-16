/// @procedure
/// id: dream_decay_v1
/// version: 1
/// summary: Demote the coldest active nodes — those untouched past their
///   per-type half-life and rarely accessed — gradually, within a per-pass
///   budget, never deleting. LLM-free; the verdict is pure arithmetic over
///   the usage columns.
/// successCriterion: Every recalled active node older than its per-type
///   half-life threshold, accessed no more than minAccessCount times, and
///   colder than the coldnessFloorDays floor is demoted (coldest first, up
///   to maxPerPass), and the demoted ids are returned; a node inside the
///   floor, frequently accessed, or younger than its half-life is left
///   active.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: source, type: String, required: true }
///   - { name: nowMs, type: int, required: true }
///   - { name: halfLifeDays, type: Map, required: false }
///   - { name: defaultHalfLifeDays, type: int, required: false }
///   - { name: maxPerPass, type: int, required: false }
///   - { name: coldnessFloorDays, type: int, required: false }
///   - { name: minAccessCount, type: int, required: false }
///   - { name: scanLimit, type: int, required: false }
/// outputs:
///   - { name: demotedIds, type: List }
///   - { name: reviewed, type: int }
/// requires: [ recallOld, demote, note ]
//
// dream_decay_v1 — the usage-recalibration pass (memory § 9.7, deep lane;
// memory-optimization plan § 13). This is the *writer* that turns the
// read-time decay signal (§ 6.6) into persisted status changes: recency is
// *read* at every recall (the ranking re-score, § 6.2.1); this agent is the
// only place coldness becomes a demotion.
//
// ── What it does ─────────────────────────────────────────────────────
//
// It streams active nodes coldest-first (`recallOld` fixes the
// least-recently-accessed ordering, § 3.2.1) and, for each, decides by pure
// arithmetic over the usage columns — no LLM:
//
//   age = (nowMs − node.lastAccessMs) in days
//   eligible ⇔ status active
//            ∧ age ≥ coldnessFloorDays      (recently-touched nodes protected)
//            ∧ accessCount ≤ minAccessCount (only rarely-used nodes)
//            ∧ age ≥ halfLifeDaysFor(type)  (past its per-type half-life)
//
// Eligible nodes are demoted coldest-first until the `maxPerPass` budget is
// spent — gradual recalibration, not a purge. The per-type half-life and the
// three knobs come in as inputs (the deep-lane driver, § 14, forwards them
// from `DecayConfig`; a test supplies them directly), so the policy lives in
// config, not baked into the body. `nowMs` is the pass clock as epoch
// milliseconds — the body subtracts it from each node's `lastAccessMs`
// (the numeric usage column the memory bridge emits alongside the ISO
// `lastAccess`), so the whole verdict is integer arithmetic with no DateTime
// parsing in the sandboxed body.
//
// ── Never deletes (hard principle 6) ────────────────────────────────
//
// `demote` hides a node from default retrieval but keeps it addressable by id
// and present in backup — reversible via `mem.promote` (the answer layer
// re-activates a demoted node it finds useful, § 6.6). The demotion reason is
// `retentionHorizon` — the node aged past its usage horizon, distinct from the
// Pruner's `prunerDecision` (redundancy) and the supersession/migration
// reasons.
//
// ── Scope (memory § 9.5) — the Pruner cannot create ──────────────────
//
// dream_decay_v1 is a `Pruner`-class agent: read-everything, demote-only write
// scope. It registers with an *empty* write-scope set, so any attempt to
// persist a node, draw an edge, or push onto a stack would be rejected by the
// store's `AgentRegistry` with `AgentScopeViolation`. Demotion is a lifecycle
// transition, not a graph mutation, so it is the one mutation the registry
// leaves open to the Pruner. This body issues no creating write at all.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

/// One day in milliseconds — the unit the usage-column arithmetic is in.
const int _msPerDay = 86400000;

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get<String>('source');
  // The pass clock as epoch ms. Required: the body has no access to a wall
  // clock inside the sandbox, so the caller (deep-lane driver / test) stamps
  // the instant the verdict is measured against.
  final nowMs = inputs.get<int>('nowMs');

  // Inline policy with config-supplied overrides (defaults mirror
  // DecayConfig / DecayDemoteConfig in tom_brain_shared, § 14). A d4rt body
  // cannot reach the native config, so the deep-lane driver forwards these.
  final defaultHalfLifeDays = _intArg(inputs, 'defaultHalfLifeDays', 90);
  final maxPerPass = _intArg(inputs, 'maxPerPass', 200);
  final coldnessFloorDays = _intArg(inputs, 'coldnessFloorDays', 30);
  final minAccessCount = _intArg(inputs, 'minAccessCount', 1);
  final scanLimit = _intArg(inputs, 'scanLimit', 256);
  final halfLifeByType = _mapArg(inputs, 'halfLifeDays');

  // Stream candidates coldest-first: `recallOld` fixes ranking `oldest`
  // (least-recently-accessed first), so iterating in order and stopping at the
  // budget demotes the coldest nodes — the gradual recalibration § 9.7 asks
  // for. Recall returns only active nodes; the `status` guard below is belt
  // and braces.
  final recall = await mem.recallOld(source, k: scanLimit);

  var reviewed = 0;
  final demotedIds = <String>[];

  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (demotedIds.length >= maxPerPass) break;
      if (node is! Map) continue;
      if (node['status'] != 'active') continue;

      final nodeId = node['id'];
      final typeName = node['typeName'];
      final lastAccessMs = node['lastAccessMs'];
      final accessCount = node['accessCount'];
      if (nodeId is! String ||
          typeName is! String ||
          lastAccessMs is! int ||
          accessCount is! int) {
        continue;
      }

      reviewed++;

      // Pure arithmetic over the usage columns — no LLM, no DateTime parsing.
      final ageDays = (nowMs - lastAccessMs) ~/ _msPerDay;

      // Floor: a node touched within coldnessFloorDays is protected, whatever
      // its type — the deep pass never demotes recently-used memory.
      if (ageDays < coldnessFloorDays) continue;

      // Only rarely-used nodes: a frequently-recalled node stays even when old.
      if (accessCount > minAccessCount) continue;

      // Past its per-type half-life? (override map, else the typed default).
      final halfLife = halfLifeByType[typeName] ?? defaultHalfLifeDays;
      if (ageDays < halfLife) continue;

      // Demote — reversible, never deleted (hard principle 6). The usage
      // horizon, not redundancy, is why, so the reason is `retentionHorizon`.
      await mem.demote(nodeId, 'retentionHorizon');
      demotedIds.add(nodeId);
    }
  }

  note('progress', {
    'agent': 'dream_decay_v1',
    'reviewed': reviewed,
    'demoted': demotedIds.length,
  });

  // The decay pass creates no nodes — it only demotes; the demoted ids are the
  // run's structured output.
  return <String, Object?>{
    'demotedIds': demotedIds,
    'reviewed': reviewed,
  };
}

/// Reads an int-valued input named [name], or [fallback] when absent /
/// non-numeric — the body's inline policy is robust to a missing override.
int _intArg(ProcedureInputs inputs, String name, int fallback) {
  if (!inputs.has(name)) return fallback;
  final v = inputs.get(name);
  return v is num ? v.toInt() : fallback;
}

/// Reads the per-type half-life override map, coercing keys to String and
/// values to int. A missing block, a non-map, or a non-numeric value yields an
/// empty map (every type then falls to `defaultHalfLifeDays`).
Map<String, int> _mapArg(ProcedureInputs inputs, String name) {
  if (!inputs.has(name)) return <String, int>{};
  final v = inputs.get(name);
  if (v is! Map) return <String, int>{};
  final out = <String, int>{};
  v.forEach((key, value) {
    if (key is String && value is num) out[key] = value.toInt();
  });
  return out;
}
