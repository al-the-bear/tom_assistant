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
/// requires: [ recall, llm, persist, edge ]
//
// answer_with_memory_v1 — the prototype's one real system procedure
// (`prototype_implementation_plan.md` D.10 / D.36–D.42;
// `tom_brain_procedure_prototype_specification.md` § 4.4, § 11).
//
// D.37 (plan): "Step 1 — recall: `recall(text: access.envelope.text,
// modes: {bm25, vector}, k: 8)`."
// D.38 (plan): "Step 2 — answer: `llm(prompt: assembled-from-recall +
// access.envelope.text, role: 'assistant_to_user')`. Stream tokens back via
// the `Access.deliver` callback."
// D.39 (plan): "Persist the exchange: an `Event` node for the inbound prompt;
// a `Conclusion` node for the answer; a `produced_by` edge to the
// `ProcedureRun`; a `derived_from` edge from the conclusion to each recalled
// node it cited." This is the third body step: after the answer is produced,
// the body persists the exchange as two memory nodes (the inbound prompt as an
// `Event`, the answer as a `Conclusion`), draws a `derived_from` edge from the
// `Conclusion` to every recalled node that fed the prompt, and reports the
// `Conclusion` id back to the engine so the run recorder draws the
// `produced_by` edge to the run record. The remaining steps (interest push
// D.40, automation note D.41, tests D.42) land next.
//
// ── Why the `produced_by` edge is the engine's job, not the body's ──
//
// The plan asks for a `produced_by` edge from the answer to the `ProcedureRun`
// node, but the body cannot draw it: the authoritative final `ProcedureRun`
// node does not exist yet — the `RunRecorder` persists it at `complete()`,
// *after* the body returns (the two-node split, recorder Q-C.31.1). The
// recorder already owns the mechanism: every node id in a run's
// `RunCompletion.producedNodeIds` receives a `produced_by` edge to the run
// record. So the body persists the nodes and reports the `Conclusion` id under
// the reserved `producedNodeIds` output key; the engine threads that list into
// the completion and the recorder draws the edge. The reserved key is stripped
// from the procedure's declared outputs (the engine — `producedNodeIdsOutputKey`),
// so `answer` stays the only surfaced output. Only the `Conclusion` (the
// produced answer) is reported — the `Event` records the inbound prompt and is
// not a "produced result" (and the bootstrap `Event` schema does not carry a
// `produced_by` edge); see Q-D.39.1 / Q-D.39.2.
//
// ── Write provenance (Q-D.39.3) ─────────────────────────────────────
//
// The body has no run id (no `runId` global is injected into a script — it
// only ever sees `inputs` / `mem` / `sub`), so its `persist` / `edge` writes
// carry the procedure id as the producer. The run linkage is still recorded:
// the recorder's `produced_by` edge ties the `Conclusion` to the run, and the
// recorder's own writes carry the full `engine:<procedureId>:<runId>`
// provenance.
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
// `mem.persist(...)` and `mem.edge(...)` (D.39) resolve through the same
// `memory_bridge.dart` import.
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
// 4–5 — `requires` must match the body's actual calls). As of D.39:
//   - `text` is `required: true` — step 1 reads it for `recall`, step 2
//     folds it into the assembled prompt, step 3 persists it as the `Event`;
//   - `requires` is `[recall, llm, persist, edge]` — the four bridged
//     primitives the body calls (memory recall + substrate completion +
//     node persist + edge creation);
//   - the only declared output is `answer` (the concatenated LLM answer
//     text). The body also returns the reserved `producedNodeIds` key, which
//     the engine consumes (to draw the run's `produced_by` edge) and strips
//     before surfacing the result — it is a body→engine transport channel,
//     not a declared output.
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
  final answer = completion['text'];

  // D.39 — persist the exchange. The body has no run id, so its writes carry
  // the procedure id as the producer (Q-D.39.3).
  final producer = 'answer_with_memory_v1';

  // The inbound prompt becomes an immutable Event.
  await mem.persist(
    'Event',
    {'summary': text},
    producer: producer,
  );

  // The answer becomes a Conclusion.
  final conclusionId = await mem.persist(
    'Conclusion',
    {'statement': answer, 'rationale': 'Answered from recalled memory.'},
    producer: producer,
  );

  // derived_from: the Conclusion was derived from each recalled node it cited.
  final cited = _citedNodeIds(recall);
  for (final nodeId in cited) {
    await mem.edge(conclusionId, 'derived_from', nodeId, producer: producer);
  }

  // The engine reads `producedNodeIds` to drive the run recorder's
  // `produced_by` edge (Conclusion → ProcedureRun), then strips the key so
  // `answer` stays the only surfaced output.
  return <String, Object?>{
    'answer': answer,
    'producedNodeIds': [conclusionId],
  };
}

/// Collects the ids of the recalled nodes that fed the answer prompt — the
/// nodes the Conclusion is `derived_from`.
List<String> _citedNodeIds(Map recall) {
  final ids = <String>[];
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map) {
        final id = node['id'];
        if (id is String) {
          ids.add(id);
        }
      }
    }
  }
  return ids;
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
