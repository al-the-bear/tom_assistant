/// @procedure
/// id: dream_synthesise_v1
/// version: 1
/// summary: Synthesise recalled Claims into a Conclusion linked back to them.
/// successCriterion: A Conclusion node is persisted (its statement + rationale
///   embedded) and a derived_from edge ties it to each recalled Claim, and the
///   Conclusion id is returned.
/// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 24, memoryWrites: 64 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: conclusionId, type: String }
/// requires: [ recall, llm, embed, persist, edge, note ]
//
// dream_synthesise_v1 — the Synthesiser cognitive agent (memory § 9, the eight
// dreaming agents; `prototype_implementation_plan_2.md` item 22).
//
// Where the Extractor turns raw episodes into atomic Claims and the Connector
// links those Claims, the Synthesiser is the move from many assertions to a
// single position: it reads the Claims recalled around a topic and asks the
// substrate (role `synthesiser`) to fold them into one Conclusion — a
// synthesised answer with its rationale — then ties that Conclusion back to the
// Claims it rests on with `derived_from` edges (the Conclusion's evidence
// trail).
//
// ── Scope (memory § 9.5) ────────────────────────────────────────────
//
// The engine binds this agent's identity onto the memory bridge, so every
// write carries it and the store's `AgentRegistry` confines the run to its
// declared write scopes — `node:Conclusion` and `edge:derived_from`. A write to
// any other node type or edge kind is rejected with `AgentScopeViolation`
// before the row is written.
//
// ── Why the Conclusion is embedded here ─────────────────────────────
//
// The bootstrap `Conclusion` type embeds its `statement` + `rationale`; the
// store stores the vector the writer supplies rather than embedding lazily, so
// the body computes the embedding through `sub.embed` and hands it to
// `persist`, keeping the Conclusion immediately recallable.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Recall the Claims to synthesise from.
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

  // Nothing to synthesise — no Claims recalled. Return an empty result rather
  // than persisting an evidence-free Conclusion.
  if (claimIds.isEmpty) {
    note('progress', {'agent': 'dream_synthesise_v1', 'conclusions': 0});
    return <String, Object?>{'conclusionId': null};
  }

  // 2. Fold the recalled statements into one synthesised Conclusion. The body
  //    supplies only the role id and the joined statements as the role-template
  //    prompt (PE-7 — never a raw wire prompt).
  const producer = 'dream_synthesise_v1';
  final completion = await sub.llm(
    'Synthesise these recorded claims into one conclusion: '
    '${statements.join(" | ")}',
    role: 'synthesiser',
  );
  final statement = completion['text'];
  final rationale = 'Synthesised from ${claimIds.length} recalled claim(s).';
  final embedding = await sub.embed('$statement $rationale');
  final conclusionId = await mem.persist(
    'Conclusion',
    {'statement': statement, 'rationale': rationale},
    producer: producer,
    embedding: embedding['vec'],
  );

  // 3. Tie the Conclusion to the Claims it rests on (its evidence trail).
  for (final claimId in claimIds) {
    await mem.edge(conclusionId, 'derived_from', claimId, producer: producer);
  }

  note('progress', {
    'agent': 'dream_synthesise_v1',
    'claimsSynthesised': claimIds.length,
  });

  // The Conclusion is this run's produced node — the engine threads it into the
  // recorder's `produced_by` edges (Conclusion allows `produced_by` outgoing).
  return <String, Object?>{
    'conclusionId': conclusionId,
    'producedNodeIds': [conclusionId],
  };
}
