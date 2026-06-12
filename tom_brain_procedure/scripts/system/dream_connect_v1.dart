/// @procedure
/// id: dream_connect_v1
/// version: 1
/// summary: Link recalled Claims into the graph with derived_from + mentions.
/// successCriterion: For the recalled Claims, a derived_from edge ties each
///   linked Claim to the episodic Events it derived from, and a mentions edge
///   ties each Claim to the next, and the drawn edge ids are returned.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: edgeIds, type: List }
/// requires: [ recall, run, runProcedure, edge, note ]
//
// dream_connect_v1 — the Connector cognitive agent (memory § 9, the eight
// dreaming agents; `prototype_implementation_plan_2.md` item 21).
//
// The Connector is the second stage of the dreaming pipeline: it reads the
// Claims the Extractor (`dream_extract_v1`) distilled, together with the
// episodic Events they came from, and weaves them into the knowledge graph.
// It draws two edge kinds:
//   - `derived_from`: a Claim is derived from the episodic Events recalled
//     alongside it — the provenance link back to experience. The substrate
//     judges, per Claim, whether the link holds (role `connector`); a Claim
//     the substrate does not affirm is left unlinked.
//   - `mentions`: consecutive Claims mention one another — the lateral link
//     that lets graph-walk recall move between related assertions.
//
// ── Scope (memory § 9) ──────────────────────────────────────────────
//
// The Connector is a *scoped* agent: the engine binds its identity
// (`dream_connect_v1`) onto the memory bridge, so every edge this body draws
// carries it and the store's `AgentRegistry` confines the run to its declared
// write scopes — `edge:derived_from` and `edge:mentions`. An attempt to draw
// any other edge kind, or a write under an unregistered identity, is rejected
// by the store with `AgentScopeViolation` before the edge is written. The
// Connector writes no nodes; it only links existing ones.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Recall the Claims (and the Events they came from) to weave together.
  final recall = await mem.recall(source, modes: ['bm25', 'vector'], k: 32);
  final claims = <Map>[];
  final eventIds = <String>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map) {
        if (node['typeName'] == 'Claim') {
          claims.add(node);
        } else if (node['typeName'] == 'Event') {
          final id = node['id'];
          if (id is String) {
            eventIds.add(id);
          }
        }
      }
    }
  }

  const producer = 'dream_connect_v1';
  final edgeIds = <String>[];

  // 2. derived_from: each Claim the substrate affirms is linked back to the
  //    episodic Events recalled alongside it. The substrate is consulted per
  //    Claim through the registered `dreaming.connect.affirm_derivation` prompt
  //    (`prompt_configuration.md` §10) — its template + `connector` role
  //    assemble the wire prompt around the claim `${statement}` (PE-7 — never a
  //    raw wire prompt); the yes/no verdict arrives under `answer`.
  for (final claim in claims) {
    final claimId = claim['id'];
    final values = claim['values'];
    final statement = values is Map ? values['statement'] : '';
    final judgement = await sub.run(
      'dreaming.connect.affirm_derivation',
      inputs: <String, Object?>{'statement': statement},
    );
    final verdict = judgement['answer'];
    final affirmed =
        verdict is String && verdict.toLowerCase().contains('yes');
    if (claimId is String && affirmed) {
      for (final eventId in eventIds) {
        final id = await mem.edge(
          claimId,
          'derived_from',
          eventId,
          producer: producer,
        );
        edgeIds.add(id);
      }
    }
  }

  // 3. mentions: consecutive Claims mention one another (the lateral link).
  for (var i = 0; i < claims.length - 1; i++) {
    final from = claims[i]['id'];
    final to = claims[i + 1]['id'];
    if (from is String && to is String) {
      final id = await mem.edge(from, 'mentions', to, producer: producer);
      edgeIds.add(id);
    }
  }

  // 4. Record the dreaming delta on the run trail.
  note('progress', {
    'agent': 'dream_connect_v1',
    'edgesDrawn': edgeIds.length,
  });

  return <String, Object?>{
    'edgeIds': edgeIds,
  };
}
