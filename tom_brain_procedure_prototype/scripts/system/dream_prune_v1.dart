/// @procedure
/// id: dream_prune_v1
/// version: 1
/// summary: Demote redundant Claims, keeping the first as canonical.
/// successCriterion: Every recalled Claim the substrate judges redundant
///   (beyond the first, canonical one) is demoted, and the demoted Claim ids
///   are returned.
/// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 24, memoryWrites: 64 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: demotedIds, type: List }
/// requires: [ recall, llm, demote, note ]
//
// dream_prune_v1 — the Pruner cognitive agent (memory § 9.5, the eight dreaming
// agents; `prototype_implementation_plan_2.md` item 22).
//
// The Pruner keeps memory from drowning in duplicates: it reads the recalled
// Claims, keeps the first as the canonical keeper, and asks the substrate (role
// `pruner`) whether each subsequent Claim is redundant against it. A Claim the
// substrate judges redundant is demoted — hidden from recall, never deleted
// (reversible; memory § 9.5, "no event is ever truly lost").
//
// ── Scope (memory § 9.5) — the Pruner cannot create ──────────────────
//
// "A Pruner cannot create new nodes, only demote." The agent registers with an
// *empty* write-scope set, so any attempt to persist a node, draw an edge, or
// push onto a stack would be rejected by the store's `AgentRegistry` with
// `AgentScopeViolation`. Demotion is a lifecycle transition, not a graph
// mutation, so it is the one mutation the registry leaves open to the Pruner —
// exactly the spec's "only demote" lane. This body issues no creating write at
// all, so it stays accepted.
import 'package:tom_brain_procedure_prototype/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Recall the Claims to prune.
  final recall = await mem.recall(source, modes: ['bm25', 'vector'], k: 32);
  final claims = <Map>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map && node['typeName'] == 'Claim') {
        claims.add(node);
      }
    }
  }

  // 2. Keep the first Claim as canonical; judge each subsequent Claim against
  //    the canonical statement and demote the redundant ones. The substrate is
  //    consulted per Claim under the `pruner` role; the body supplies only the
  //    role id and the claim text (PE-7 — never a raw wire prompt).
  const producer = 'dream_prune_v1';
  final demotedIds = <String>[];
  if (claims.isNotEmpty) {
    final canonicalValues = claims.first['values'];
    final canonical =
        canonicalValues is Map ? canonicalValues['statement'] : '';
    for (var i = 1; i < claims.length; i++) {
      final claimId = claims[i]['id'];
      final values = claims[i]['values'];
      final statement = values is Map ? values['statement'] : '';
      final judgement = await sub.llm(
        'Is this claim redundant against the canonical claim? Answer yes or '
        'no. Canonical: $canonical Claim: $statement',
        role: 'pruner',
      );
      final verdict = judgement['text'];
      final redundant = verdict is String &&
          (verdict.toLowerCase().contains('redundant') ||
              verdict.toLowerCase().contains('yes'));
      if (claimId is String && redundant) {
        await mem.demote(claimId, 'prunerDecision');
        demotedIds.add(claimId);
      }
    }
  }

  note('progress', {'agent': 'dream_prune_v1', 'demoted': demotedIds.length});

  // The Pruner produces no nodes — it only demotes; `producedNodeIds` is never
  // returned. The demoted ids are the run's structured output.
  return <String, Object?>{
    'demotedIds': demotedIds,
  };
}
