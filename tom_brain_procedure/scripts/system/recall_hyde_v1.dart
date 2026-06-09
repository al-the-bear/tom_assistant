/// @procedure
/// id: recall_hyde_v1
/// version: 1
/// summary: Build HyDE vector recall seeds — `recall_planner` → hypothetical
///   `hypothesis_writer` answers → embed the *answers* → vector seeds.
/// successCriterion: Returns a `seeds` list of vector `RecallSeed` maps whose
///   embeddings are over the hypothetical *answers* (never the questions), so
///   the seeds land near real answers in vector space (HyDE); degrades to an
///   empty list when either role result is unusable (PE-6).
/// budget: { wallClockMs: 45000, tokenSpend: 4000, toolCalls: 8, memoryWrites: 0 }
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: seeds, type: List }
/// requires: [ retrievalRole, embed ]
//
// recall_hyde_v1 — the HyDE (Hypothetical Document Embeddings) leg of the
// four-strategy retrieval set (`tom_brain_procedure_specification.md`
// § 23.2; plan Extension-H step #30).
//
// HyDE's premise: a question and its answer sit in *different* regions of
// embedding space, so embedding the raw question retrieves poorly. Instead we
// ask the model to imagine the answer, then embed *that* — the hypothetical
// answer lands near the real answers we want to recall. Two roles compose the
// hypothesis:
//
//   1. `recall_planner` decomposes the prompt into clarifying sub-questions;
//   2. `hypothesis_writer` drafts hypothetical answers to them.
//
// Only the **answers** are embedded (§ 23.2, the Test-clause obligation). The
// questions feed the hypothesis-writer *prompt* — they shape what the model
// drafts — but they are never themselves embedded, because a question
// embedding is exactly what HyDE avoids. Each hypothetical answer becomes one
// vector seed carrying its pre-computed embedding (skipping a memory-side
// embed callout).
//
// Graceful degrade (PE-6): `sub.retrievalRole` returns `{ok: false}` for a
// malformed model result, and we return whatever seeds we have so far (an
// empty list before the first usable result). A genuine substrate outage
// throws, surfacing the run as `.failed()` to the conductor, which drops this
// strategy's seeds and proceeds on the surviving non-LLM strategies.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');
  final seeds = <Object?>[];

  // Step 1 — decompose the prompt into clarifying sub-questions.
  final planned = await sub.retrievalRole('recall_planner', text);
  if (planned['ok'] != true) return <String, Object?>{'seeds': seeds};
  final plannedOutput = planned['output'];
  final questions = plannedOutput is Map ? plannedOutput['questions'] : null;

  // Step 2 — draft hypothetical answers. The questions shape the prompt but
  // are never embedded (HyDE).
  final hydePrompt = _composeHypothesisPrompt(text, questions);
  final hypothesised = await sub.retrievalRole('hypothesis_writer', hydePrompt);
  if (hypothesised['ok'] != true) return <String, Object?>{'seeds': seeds};
  final hypothesisedOutput = hypothesised['output'];
  final answers =
      hypothesisedOutput is Map ? hypothesisedOutput['answers'] : null;

  // Step 3 — embed each hypothetical *answer* into a vector seed.
  if (answers is List) {
    for (final answer in answers) {
      if (answer is String && answer.isNotEmpty) {
        final embedding = await sub.embed(answer);
        seeds.add(<String, Object?>{
          'mode': 'vector',
          'embedding': embedding['vec'],
          'weight': 1.0,
        });
      }
    }
  }

  return <String, Object?>{'seeds': seeds};
}

/// Builds the `hypothesis_writer` prompt from the original [text] and the
/// planner's clarifying [questions]. The questions are woven into the prompt
/// the model answers — they are *not* embedded; only the resulting answers are
/// (HyDE).
String _composeHypothesisPrompt(Object? text, Object? questions) {
  final buffer = StringBuffer()
    ..writeln('User prompt:')
    ..writeln(text);
  if (questions is List && questions.isNotEmpty) {
    buffer.writeln();
    buffer.writeln('Write a hypothetical answer to each clarifying question:');
    for (final question in questions) {
      buffer.writeln('- $question');
    }
  }
  return buffer.toString();
}
