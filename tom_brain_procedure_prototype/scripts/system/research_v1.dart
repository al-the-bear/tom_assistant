/// @procedure
/// id: research_v1
/// version: 1
/// summary: Research a topic on the web and record a sourced Claim.
/// successCriterion: A web search + fetch yields a Source node (its title
///   embedded) and a Claim node (its statement embedded) tied by an
///   evidence_for edge, and the Claim id is returned.
/// budget: { wallClockMs: 90000, tokenSpend: 8000, toolCalls: 24, memoryWrites: 32 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: claimId, type: String }
/// requires: [ search, fetch, llm, embed, persist, edge, note ]
//
// research_v1 — the Researcher cognitive agent (memory § 9, the eight dreaming
// agents; `prototype_implementation_plan_2.md` item 22). It is the one agent
// that reaches outside memory: it searches the web for the topic, fetches the
// top result, asks the substrate (role `researcher`) to distil the fetched page
// into one factual Claim, and records that Claim together with the `Source` it
// came from — tied by an `evidence_for` edge so the Claim always carries its
// provenance back to the page that justifies it.
//
// ── Scope (memory § 9.5) ────────────────────────────────────────────
//
// The engine binds this agent's identity onto the memory bridge, so every
// write carries it and the store's `AgentRegistry` confines the run to its
// declared write scopes — `node:Source`, `node:Claim`, and
// `edge:evidence_for`. A write outside that set is rejected with
// `AgentScopeViolation` before the row is written.
//
// ── Why each node is embedded here ──────────────────────────────────
//
// The bootstrap `Source` and `Claim` types embed their text fields (the
// Source's `title`, the Claim's `statement`); the store stores the vector the
// writer supplies rather than embedding lazily, so the body computes each
// embedding through `sub.embed` and hands it to `persist`.
import 'package:tom_brain_procedure_prototype/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Search the web for the topic and take the top hit.
  final search = await sub.search('$source');
  final hits = search['hits'];
  if (hits is! List || hits.isEmpty) {
    note('progress', {'agent': 'research_v1', 'claims': 0});
    return <String, Object?>{'claimId': null};
  }
  final top = hits.first;
  final url = top is Map ? top['url'] : null;
  final title = top is Map ? top['title'] : '';
  if (url is! String) {
    note('progress', {'agent': 'research_v1', 'claims': 0});
    return <String, Object?>{'claimId': null};
  }

  // 2. Fetch the page.
  final fetched = await sub.fetch(url);
  final body = fetched['text'];

  // 3. Distil one factual Claim from the fetched page. The body supplies only
  //    the role id and the fetched text as the role-template prompt (PE-7 —
  //    never a raw wire prompt).
  const producer = 'research_v1';
  final completion = await sub.llm(
    'Extract one atomic, self-contained factual claim from this fetched '
    'page: $body',
    role: 'researcher',
  );
  final statement = completion['text'];

  // 4. Record the Source (its title embedded) and the Claim (its statement
  //    embedded), then tie them together.
  final sourceEmbedding = await sub.embed('$title');
  final sourceId = await mem.persist(
    'Source',
    {'uri': url, 'title': title},
    producer: producer,
    embedding: sourceEmbedding['vec'],
  );
  final claimEmbedding = await sub.embed('$statement');
  final claimId = await mem.persist(
    'Claim',
    {'statement': statement},
    producer: producer,
    embedding: claimEmbedding['vec'],
  );
  await mem.edge(sourceId, 'evidence_for', claimId, producer: producer);

  note('progress', {'agent': 'research_v1', 'claims': 1});

  // The Claim is this run's produced node — the engine threads it into the
  // recorder's `produced_by` edges (Claim allows `produced_by` outgoing). The
  // Source does *not* allow `produced_by` outgoing, so it is deliberately left
  // out of `producedNodeIds` (returning it would fail with EdgeNotPermitted).
  return <String, Object?>{
    'claimId': claimId,
    'producedNodeIds': [claimId],
  };
}
