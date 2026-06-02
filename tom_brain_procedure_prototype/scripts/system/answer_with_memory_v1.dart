/// @procedure
/// id: answer_with_memory_v1
/// version: 1
/// summary: Recall relevant memory, answer the user, persist the exchange.
/// successCriterion: A streamed answer is delivered and an Event + Conclusion
///   + edges are persisted (the recall → answer → persist loop; the body is
///   built across D.37–D.42).
/// budget: { wallClockMs: 60000, tokenSpend: 8000, toolCalls: 12, memoryWrites: 6 }
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: answer, type: String }
/// requires: [ recall, llm ]
//
// answer_with_memory_v1 — the prototype's one real system procedure
// (`prototype_implementation_plan.md` D.10 / D.36–D.42;
// `tom_brain_procedure_prototype_specification.md` § 4.4, § 11).
//
// D.37 (plan): "Step 1 — recall: `recall(text: access.envelope.text,
// modes: {bm25, vector}, k: 8)`."
// D.38 (plan): "Step 2 — answer: `llm(prompt: assembled-from-recall +
// access.envelope.text, role: 'assistant_to_user')`. Stream tokens back via
// the `Access.deliver` callback." This is the second body step: after recall,
// the body assembles a prompt out of the recalled memory plus the inbound
// prompt and runs it through the substrate's `llm` under the user-facing
// role, returning the generated answer. The remaining steps (persist, edges,
// interest push, automation note) land across D.39–D.42, each promoting the
// body and the header fields that describe it.
//
// ── Token streaming and `Access.deliver` (Q-D.38.1) ─────────────────
//
// The plan's "stream tokens back via the `Access.deliver` callback" is a
// Phase E (`tom_brain_access`) concern: the `Access` object — its session,
// persona, and `deliver` outbound callback — does not exist in the procedure
// prototype, which only ever sees a `ProcedureInputs` bag. The substrate
// bridge's `llm` already drains the substrate stream and returns the
// *concatenated* answer text (Q-C.13.1), so the prototype's body produces the
// whole answer as the `answer` output; per-token delivery to a live caller is
// wired when the dispatcher/access layer threads a deliver sink through the
// run (Q-D.38.1).
//
// ── How the body reaches its inputs and the bridges ─────────────────
//
// The engine hands the entry point a native `ProcedureInputs` and binds the
// memory + substrate bridges as the `mem` / `sub` globals keyed to the bridge
// library URIs (`D4rtDcliHost`). A d4rt script reaches each by importing the
// library it is registered under:
//   - `…/src/api/procedure_inputs.dart` names the `ProcedureInputs` type so
//     `inputs.get('text')` dispatches onto the native bag
//     (`procedure_inputs_bridge.dart`, D.37);
//   - `…/src/bridges/memory_bridge.dart` brings the `mem` global into scope
//     so `mem.recall(...)` resolves (`brain_bridges_registrar.dart`);
//   - `…/src/bridges/substrate_bridge.dart` brings the `sub` global into
//     scope so `sub.llm(...)` resolves (D.38).
// These imports are the only surface this body touches; everything else is
// denied (PE-1). (The static `SandboxValidator` rejects *all* imports per
// spec § 4.2; that ban contradicts the host's import-to-reach-`mem`/`sub`
// convention and is not yet reconciled — see Q-D.37.1. The validator is not
// wired into the engine run path, so the body runs as written.)
//
// ── Header fields tracked to the body ───────────────────────────────
//
// The machine-validated header fields track the body, not the summary, so
// the artifact stays internally coherent (`ContractValidator`, § 7 rows
// 4–5 — `requires` must match the body's actual calls). As of D.38:
//   - `text` is `required: true` — step 1 reads it for `recall`, step 2
//     folds it into the assembled prompt;
//   - `requires` is `[recall, llm]` — the two bridged primitives the body
//     calls (memory recall + substrate completion);
//   - the output is `answer` (the concatenated LLM answer text).
//
// `ProcedureResult` is not bridged into d4rt (Q-C.38.2), so the entry point
// returns a plain `Map` the engine coerces into a succeeded result; the
// strict `Future<ProcedureResult> run(ProcedureInputs inputs) async` shape
// arrives once ProcedureResult is bridged.
//
// The anchor invariant (PE-7) holds structurally: `sub.llm` is the only
// completion path and it names a `role` + supplies `inputs` — it can never
// hand the substrate a pre-assembled wire prompt, so the assistant-dedication
// anchor is always prepended at the substrate's assembly time. The prompt
// this body builds is the role template's `prompt` *input*, not the wire
// prompt.
import 'package:tom_brain_procedure_prototype/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');
  final recall = await mem.recall(text, modes: ['bm25', 'vector'], k: 8);
  final prompt = _assemblePrompt(recall, text);
  final completion = await sub.llm(prompt, role: 'assistant_to_user');
  return <String, Object?>{'answer': completion['text']};
}

/// Builds the role-template `prompt` input from the recalled memory and the
/// inbound prompt: each recalled node's `text` value becomes a context line,
/// followed by the user's prompt. When recall returned nothing, the context
/// block is omitted and only the user prompt is sent.
String _assemblePrompt(Map recall, Object? text) {
  var context = '';
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map) {
        final values = node['values'];
        if (values is Map && values['text'] != null) {
          context += '- ${values['text']}\n';
        }
      }
    }
  }
  final preamble = context.isEmpty ? '' : 'Relevant recalled memory:\n$context\n';
  return '${preamble}User prompt:\n$text';
}
