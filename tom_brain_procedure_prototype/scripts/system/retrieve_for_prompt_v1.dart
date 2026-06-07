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
///   - { name: retrievalConfig, type: Map, required: false }
/// outputs:
///   - { name: recall, type: Map }
/// requires: [ recallMulti, runProcedure ]
//
// retrieve_for_prompt_v1 — the four-strategy retrieval conductor
// (`tom_brain_procedure_prototype_specification.md` § 23.2, § 23.4; plan
// Extension-H steps #30 + #31).
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
// ── The injected `retrievalConfig` (§ 23.4, step #31) ────────────────
//
// A sandboxed d4rt procedure cannot read files, so the resolved
// `memory_retrieval/` config (defaults ← surface ← call_type) is projected to
// the conductor's coarse surface by `MemoryRetrievalConfig.toConductorMap()`
// and injected as the optional `retrievalConfig` input (a plain map). When it
// is **absent**, the conductor falls back to the legacy full fan-out (one
// inline BM25 seed + all four `recall_*` sub-procedures) — exactly the step
// #30 behaviour, preserving h30 parity. When it is **present** it gates and
// parameterises everything:
//
//   * `seeds.vector.prompt` / `seeds.bm25.prompt_terms` — each inline seed runs
//     only when `enabled`, carrying its configured `weight` / `k`. With only
//     `vector.prompt` enabled this is a single vector seed over the prompt —
//     today's naive recall reproduced byte-for-byte (§ 23.4 superset property).
//   * `subProcedures.<recall_*>` — each sub-procedure is dispatched only when
//     its gate is true; a disabled gate means that strategy contributes no
//     seeds. Enabling more strategies only adds seeds — never removes one.
//   * `fusion.rrfK` / `diversity.lambda` / `budget.k` — flow straight into the
//     fused `recallMulti` (RRF smoothing, MMR trade-off, post-fusion cap).
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
  final cfg = inputs.getOrNull('retrievalConfig');

  // ── 1. Inline seeds (the cheap, always-available pass; PE-6) ──
  // With no config we keep the legacy single BM25 seed over the raw prompt —
  // it touches no substrate and no memory read, so it survives any outage.
  // With a config we honour its inline-seed gates / weights / caps instead.
  final allSeeds = <Object?>[];
  if (cfg is Map) {
    final seeds = cfg['seeds'];
    if (seeds is Map) {
      final vp = _seedOf(seeds['vector.prompt']);
      if (vp != null && vp['enabled'] == true) {
        allSeeds.add(_inlineSeed('vector', text, vp));
      }
      final bp = _seedOf(seeds['bm25.prompt_terms']);
      if (bp != null && bp['enabled'] == true) {
        allSeeds.add(_inlineSeed('bm25', text, bp));
      }
    }
  } else {
    allSeeds.add(<String, Object?>{'mode': 'bm25', 'text': text, 'weight': 1.0});
  }

  // ── 2. Strategy sub-procedures (each its own ProcedureRun, PE-4) ──
  // recall_symbolic is the second non-LLM strategy; the three LLM strategies
  // degrade to no seeds (or a `.failed()` run) under an outage. The conductor
  // forwards its own `inputs` (carrying `text`) to each (see header).
  //
  // Gating: with no config at all (`enabled == null`) every sub-procedure runs
  // (legacy fan-out — h30 parity). With a config present, a sub-procedure runs
  // only when its `subProcedures` gate is explicitly true; a config that omits
  // the `subProcedures` block enables none (the capability is off, not legacy).
  const strategies = <String>[
    'recall_symbolic_v1',
    'recall_hyde_v1',
    'recall_lexical_v1',
    'recall_semantic_v1',
  ];
  final enabled = _enabledSubs(cfg, strategies);
  for (final strategy in strategies) {
    if (enabled != null && !enabled.contains(strategy)) continue;
    final result = await runProcedure(strategy, inputs);
    if (!result.isSuccess) continue;
    final seeds = result.output('seeds');
    if (seeds is List) allSeeds.addAll(seeds);
  }

  // ── 3. Fused multi-recall (RRF + MMR inside the store) ──
  // The fusion / diversity / final-k knobs flow from the resolved config; with
  // no config the documented defaults (rrfK 60, lambda 0.7, k 24) apply.
  final fusionK = _intIn(cfg, 'fusion', 'rrfK', 60);
  final lambda = _doubleIn(cfg, 'diversity', 'lambda', 0.7);
  final finalK = _intIn(cfg, 'budget', 'k', 24);
  final recall =
      await mem.recallMulti(allSeeds, k: finalK, rrfK: fusionK, lambda: lambda);
  return <String, Object?>{'recall': recall};
}

/// The sub-procedures enabled by [cfg], or `null` when there is no config at
/// all (the legacy "run every sub-procedure" signal). A config present but
/// without a `subProcedures` block returns the empty list — none enabled.
List<String>? _enabledSubs(Object? cfg, List<String> known) {
  if (cfg is! Map) return null;
  final out = <String>[];
  final sp = cfg['subProcedures'];
  if (sp is Map) {
    for (final strategy in known) {
      if (sp[strategy] == true) out.add(strategy);
    }
  }
  return out;
}

/// Coerces one inline-seed config entry to a map, or `null` when absent.
Map<Object?, Object?>? _seedOf(Object? raw) =>
    raw is Map<Object?, Object?> ? raw : null;

/// Builds a `recallMulti` seed map for an inline strategy over [text],
/// honouring the configured `weight` and optional per-seed `k`.
Map<String, Object?> _inlineSeed(
  String mode,
  Object? text,
  Map<Object?, Object?> entry,
) {
  final weight = entry['weight'];
  final k = entry['k'];
  return <String, Object?>{
    'mode': mode,
    'text': text,
    'weight': weight is num ? weight : 1.0,
    if (k is num) 'k': k,
  };
}

/// Reads `cfg[block][field]` as an int, or [fallback] when the block/field is
/// missing or non-numeric.
int _intIn(Object? cfg, String block, String field, int fallback) {
  if (cfg is! Map) return fallback;
  final b = cfg[block];
  if (b is! Map) return fallback;
  final v = b[field];
  return v is num ? v.toInt() : fallback;
}

/// Reads `cfg[block][field]` as a double, or [fallback] when the block/field is
/// missing or non-numeric.
double _doubleIn(Object? cfg, String block, String field, double fallback) {
  if (cfg is! Map) return fallback;
  final b = cfg[block];
  if (b is! Map) return fallback;
  final v = b[field];
  return v is num ? v.toDouble() : fallback;
}
