/// @procedure
/// id: retrieve_for_prompt_v1
/// version: 1
/// summary: The retrieval conductor — runs a cheap non-LLM pass always plus
///   the LLM `recall_*` strategies within budget, then fuses every seed into
///   one `recall.multi` (RRF + MMR) and returns the assembled context.
/// successCriterion: Returns a `recall` map (nodes + report + provenance) fused
///   from the surviving strategies' seeds; with every LLM strategy failing the
///   conductor still returns a fused non-LLM result (PE-6), because the cheap
///   BM25 seed and the non-LLM `recall_symbolic_v1` always contribute.
/// budget: { wallClockMs: 90000, tokenSpend: 8000, toolCalls: 16, memoryWrites: 0 }
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: recall, type: Map }
/// requires: [ recallMulti, runProcedure ]
//
// retrieve_for_prompt_v1 — the four-strategy retrieval conductor
// (`tom_brain_procedure_prototype_specification.md` § 23.2; plan Extension-H
// step #30).
//
// The conductor orchestrates retrieval as a self-organising fan-out / fan-in:
//
//   1. Cheap non-LLM pass (always). A pure BM25 seed over the raw prompt text
//      — no substrate, no memory read — so the conductor *always* has at least
//      one seed even under a total LLM outage. `recall_symbolic_v1` (also
//      LLM-free) adds the second guaranteed contribution. Together these make
//      the fused recall survive an outage (PE-6).
//
//   2. LLM pass (within budget). The three model-backed strategies —
//      `recall_hyde_v1` (HyDE vector seeds), `recall_lexical_v1` (BM25 query +
//      synonyms), `recall_semantic_v1` (concept-centroid cheap path → symbolic
//      seeds, escalating to `category_selector`). Each is dispatched as its own
//      sub-procedure, so it gets its own `ProcedureRun` (PE-4), its own depth
//      budget (PE-3), and its own effort budget (PE-8). A strategy that fails
//      — a malformed model result degrading to no seeds, or a substrate outage
//      surfacing the run as `.failed()` — simply contributes nothing; the
//      conductor never lets one strategy's failure abort the retrieval.
//
//   3. Fusion. Every surviving seed is merged into one `mem.recallMulti`, which
//      runs RRF across modes and MMR for diversity inside the store and returns
//      the fused nodes with per-node provenance. The optional LLM
//      `retrieval_reranker` (§ 23.2) is a deferred prototype extension — RRF +
//      MMR is the non-optional fusion the conductor relies on, and wiring an
//      LLM rerank that reorders the fused node list (while keeping provenance
//      coherent) is out of this step's scope.
//
// ── Why sub-procedures are forwarded the conductor's own `inputs` ────
//
// Each `recall_*` strategy declares the same `text` input the conductor
// received, and a procedure may not construct a `ProcedureInputs` in-script
// (only the read surface is bridged — `procedure_inputs_bridge.dart`). So the
// conductor forwards its own immutable `inputs` bag straight to each
// `runProcedure(...)` call; the bag carries `text`, which is all every strategy
// needs. Immutability makes the sharing safe.
import 'package:tom_brain_procedure_prototype/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure_prototype/src/api/procedure_result.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');

  // ── 1. Cheap non-LLM pass (always; survives an LLM outage, PE-6) ──
  // A pure BM25 seed over the raw prompt text touches no substrate and no
  // memory read, so it is guaranteed to contribute under any failure.
  final allSeeds = <Object?>[
    <String, Object?>{'mode': 'bm25', 'text': text, 'weight': 1.0},
  ];

  // ── 2. Strategy sub-procedures (each its own ProcedureRun, PE-4) ──
  // recall_symbolic is the second non-LLM strategy; the three LLM strategies
  // degrade to no seeds (or a `.failed()` run) under an outage. The conductor
  // forwards its own `inputs` (carrying `text`) to each (see header).
  const strategies = <String>[
    'recall_symbolic_v1',
    'recall_hyde_v1',
    'recall_lexical_v1',
    'recall_semantic_v1',
  ];
  for (final strategy in strategies) {
    final result = await runProcedure(strategy, inputs);
    if (!result.isSuccess) continue;
    final seeds = result.output('seeds');
    if (seeds is List) allSeeds.addAll(seeds);
  }

  // ── 3. Fused multi-recall (RRF + MMR inside the store) ──
  final recall = await mem.recallMulti(allSeeds, k: 24);
  return <String, Object?>{'recall': recall};
}
