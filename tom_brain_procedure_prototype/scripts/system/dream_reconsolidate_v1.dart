/// @procedure
/// id: dream_reconsolidate_v1
/// version: 1
/// summary: Record a Contradiction between conflicting Claims and demote one.
/// successCriterion: A Contradiction node is persisted (its summary embedded),
///   a contradicts edge ties it to each conflicting Claim, the superseded Claim
///   is demoted, and the Contradiction id is returned.
/// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 24, memoryWrites: 64 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: contradictionId, type: String }
/// requires: [ recall, llm, embed, persist, edge, demote, note ]
//
// dream_reconsolidate_v1 — the Reconsolidator cognitive agent (memory § 9, the
// eight dreaming agents; `prototype_implementation_plan_2.md` item 22).
//
// Reconsolidation is the move that keeps memory coherent: it reads the recalled
// Claims, asks the substrate (role `reconsolidator`) to name the conflict
// between them, records that conflict as a `Contradiction` node tied to the
// Claims it concerns (`contradicts` edges), and demotes the superseded Claim so
// retrieval stops surfacing it. Demotion is reversible and the original Claim
// is never deleted (memory § 9.5, "no event is ever truly lost") — it is hidden
// from recall, with the Contradiction recording *why*.
//
// ── Scope (memory § 9.5) ────────────────────────────────────────────
//
// The engine binds this agent's identity onto the memory bridge, so every
// write carries it and the store's `AgentRegistry` confines the run to its
// declared write scopes — `node:Contradiction` and `edge:contradicts`. Demotion
// is not graph mutation, so it passes scope enforcement (the registry guards
// node / edge / stack writes, not lifecycle transitions); the agent's *only*
// node-creation lane is `Contradiction`.
//
// ── Why the Contradiction is embedded here ──────────────────────────
//
// The bootstrap `Contradiction` type embeds its `summary`; the store stores the
// vector the writer supplies rather than embedding lazily, so the body computes
// the embedding through `sub.embed` and hands it to `persist`.
import 'package:tom_brain_procedure_prototype/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Recall the Claims to reconcile.
  final recall = await mem.recall(source, modes: ['bm25', 'vector'], k: 32);
  final claimIds = <String>[];
  final statements = <String>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map && node['typeName'] == 'Claim') {
        final id = node['id'];
        final values = node['values'];
        if (id is String && values is Map) {
          claimIds.add(id);
          final statement = values['statement'];
          if (statement is String) statements.add(statement);
        }
      }
    }
  }

  // Reconsolidation needs at least two Claims to find a conflict between. With
  // fewer there is nothing to reconcile.
  if (claimIds.length < 2) {
    note('progress', {'agent': 'dream_reconsolidate_v1', 'contradictions': 0});
    return <String, Object?>{'contradictionId': null};
  }

  // 2. Name the conflict. The body supplies only the role id and the joined
  //    statements as the role-template prompt (PE-7 — never a raw wire prompt).
  const producer = 'dream_reconsolidate_v1';
  final completion = await sub.llm(
    'These recorded claims may conflict. Summarise the contradiction between '
    'them: ${statements.join(" | ")}',
    role: 'reconsolidator',
  );
  final summary = completion['text'];
  final embedding = await sub.embed('$summary');
  final contradictionId = await mem.persist(
    'Contradiction',
    {'summary': summary},
    producer: producer,
    embedding: embedding['vec'],
  );

  // 3. Tie the Contradiction to the Claims it concerns.
  for (final claimId in claimIds) {
    await mem.edge(contradictionId, 'contradicts', claimId, producer: producer);
  }

  // 4. Demote the superseded Claim — the last one recalled is treated as the
  //    stale assertion the others supersede. It is hidden from recall, not
  //    deleted (reversible; memory § 9.5).
  await mem.demote(claimIds.last, 'supersession');

  note('progress', {
    'agent': 'dream_reconsolidate_v1',
    'claimsReconciled': claimIds.length,
    'demoted': 1,
  });

  // Contradiction carries no `produced_by` outgoing edge in the bootstrap
  // schema, so it is not returned as a produced node (that would fail with
  // EdgeNotPermitted); the id is the run's structured output only.
  return <String, Object?>{
    'contradictionId': contradictionId,
  };
}
