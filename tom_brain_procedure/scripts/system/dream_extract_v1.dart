/// @procedure
/// id: dream_extract_v1
/// version: 1
/// summary: Extract atomic Claim nodes from a seeded episodic trail.
/// successCriterion: For every recalled Event, an atomic Claim is persisted
///   (its statement embedded), and the persisted Claim ids are returned.
/// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 24, memoryWrites: 32 }
/// inputs:
///   - { name: source, type: String, required: true }
/// outputs:
///   - { name: claimIds, type: List }
/// requires: [ recall, llm, embed, persist, note, yield_if_foreground_waiting ]
//
// dream_extract_v1 — the Extractor cognitive agent (memory § 9, the eight
// dreaming agents; `prototype_implementation_plan_2.md` item 21).
//
// The Extractor reads recent episodic memory (the "seeded trail" of `Event`
// nodes the consolidation cadence hands it) and distils each event into an
// atomic factual `Claim` — the move from raw experience to a reusable
// assertion. It is the first stage of the dreaming pipeline: the Connector
// (`dream_connect_v1`) then links the claims it produced into the graph.
//
// ── Scope (memory § 9) ──────────────────────────────────────────────
//
// The Extractor is a *scoped* agent: the engine binds its agent identity
// (`dream_extract_v1`) onto the memory bridge, so every write this body
// issues carries that identity and the store's `AgentRegistry` confines it
// to the agent's declared write scopes — `node:Claim`. A write to any other
// node type, or under an unregistered identity, is rejected by the store
// with `AgentScopeViolation` before the row is written. The Extractor only
// ever persists `Claim`s, so it stays in its lane.
//
// ── Why each Claim is embedded here ─────────────────────────────────
//
// The bootstrap `Claim` type requires an embedding (its `statement` is the
// embedding source). The memory store does not call the substrate itself —
// it stores the vector the writer supplies — so the body computes the
// statement's embedding through `sub.embed` and hands it to `persist`. That
// keeps the claim immediately recallable by vector mode (the Connector's
// recall depends on it) without a second consolidation pass.
//
// ── How the substrate is used (extraction) ──────────────────────────
//
// Each event summary is handed to the substrate under the `extractor` role,
// which returns the atomic claim text. The body supplies only the role id and
// the event text as the role-template `prompt` input — it never assembles a
// raw wire prompt, so the assistant-dedication anchor (PE-7) is always
// prepended at the substrate. The returned text becomes the claim statement.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final source = inputs.get('source');

  // 1. Recall the seeded episodic trail — the recent Events to distil.
  final recall = await mem.recall(source, modes: ['bm25', 'vector'], k: 16);

  // 2. For each recalled Event, extract one atomic Claim, embed its
  //    statement, and persist it. The producer is the procedure id (the body
  //    has no run id, Q-D.39.3); the agent identity that scopes the write is
  //    bound on the bridge by the engine, not passed here.
  const producer = 'dream_extract_v1';
  final claimIds = <String>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      // Cooperative preemption checkpoint (PE-5; memory § 9). Dreaming is
      // background work: a foreground (user) prompt that arrives mid-run parks
      // the Extractor *here*, between events, and resumes it once the
      // foreground drains — so extraction never holds the engine against a
      // waiting user, yet no event's work is lost or run twice.
      await yield_if_foreground_waiting();
      if (node is Map && node['typeName'] == 'Event') {
        final values = node['values'];
        if (values is Map) {
          final summary = values['summary'];
          final completion = await sub.llm(
            'Extract one atomic, self-contained factual claim from this '
            'recorded event: $summary',
            role: 'extractor',
          );
          final statement = completion['text'];
          final embedding = await sub.embed(statement);
          final claimId = await mem.persist(
            'Claim',
            {'statement': statement},
            producer: producer,
            embedding: embedding['vec'],
          );
          claimIds.add(claimId);
        }
      }
    }
  }

  // 3. Record the dreaming delta on the run trail.
  note('progress', {
    'agent': 'dream_extract_v1',
    'claimsExtracted': claimIds.length,
  });

  // The extracted Claims are this run's produced nodes — the engine threads
  // them into the run recorder's `produced_by` edges.
  return <String, Object?>{
    'claimIds': claimIds,
    'producedNodeIds': claimIds,
  };
}
