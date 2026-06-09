/// @procedure
/// id: recall_lexical_v1
/// version: 1
/// summary: Build lexical (BM25) recall seeds from the LLM `query_term_writer`
///   role — the keyword leg of the four-strategy retrieval set.
/// successCriterion: Returns a `seeds` list of bm25 `RecallSeed` maps (the
///   rewritten query plus one seed per synonym); degrades to an empty list
///   when the role result is unusable (PE-6), so a malformed model output
///   never crashes retrieval.
/// budget: { wallClockMs: 30000, tokenSpend: 2000, toolCalls: 2, memoryWrites: 0 }
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: seeds, type: List }
/// requires: [ retrievalRole ]
//
// recall_lexical_v1 — the lexical leg of the four-strategy retrieval set
// (`tom_brain_procedure_specification.md` § 23.2; plan Extension-H
// step #30).
//
// It runs the `query_term_writer` retrieval role to rewrite the raw prompt
// into a focused keyword query plus synonyms, then assembles BM25 seeds from
// them: one `text` seed over the rewritten query and one `terms` seed per
// synonym. The role call routes through `sub.retrievalRole`, which already
// degrades a malformed model result to `{ok: false}` (substrate § 6.2a) rather
// than crashing — this procedure honours that by returning an empty seed list
// when the role did not produce a usable output, so the conductor simply gets
// no lexical contribution rather than a failed sub (PE-6). A genuine substrate
// outage propagates as a thrown failure, surfacing the run as `.failed()` to
// the conductor, which then drops this strategy's seeds.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');
  final seeds = <Object?>[];

  // Rewrite the prompt into a keyword query + synonyms. A malformed/unusable
  // model result degrades to `ok: false` — we then contribute no seeds.
  final result = await sub.retrievalRole('query_term_writer', text);
  if (result['ok'] != true) return <String, Object?>{'seeds': seeds};

  final output = result['output'];
  if (output is! Map) return <String, Object?>{'seeds': seeds};

  // The rewritten query is the primary BM25 seed.
  final query = output['query'];
  if (query is String && query.isNotEmpty) {
    seeds.add(<String, Object?>{
      'mode': 'bm25',
      'text': query,
      'weight': 1.0,
    });
  }

  // Each synonym becomes a lower-weighted single-term BM25 seed.
  final synonyms = output['synonyms'];
  if (synonyms is List) {
    for (final synonym in synonyms) {
      if (synonym is String && synonym.isNotEmpty) {
        seeds.add(<String, Object?>{
          'mode': 'bm25',
          'terms': <Object?>[synonym],
          'weight': 0.6,
        });
      }
    }
  }

  return <String, Object?>{'seeds': seeds};
}
