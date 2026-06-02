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
/// requires: [ recall, llm, persist, edge, stack.push, note ]
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
// `produced_by` edge to the run record.
// D.40 (plan): "Push an `InterestItem` to `interests` if the prompt embedding
// lands far from any existing centroid (cold-classification path)." This is
// the fourth body step: when the four-mode recall (vector mode included)
// surfaced nothing, the prompt landed far from anything memory already knows —
// the brain is curious about a topic it has no memory of — so the body records
// an `InterestItem` and pushes it onto the `interests` bootstrap stack.
// D.41 (plan): "Emit a `note('automation_candidate', …)` if the prompt matches
// a recent identical-shape prompt (cheap repetition check)." This is the fifth
// body step: step 3 persists every inbound prompt as an `Event` whose
// `summary` is the prompt text, so when the user asks the *same* thing again
// the four-mode recall (step 1) surfaces that prior `Event`. The body reads
// that off the recall it already ran and, on a match, emits an
// `automation_candidate` note on the run trail — the wire the dispatcher's
// harvester (D.31) keys on to consider turning a repeated prompt into a
// procedure. D.42 then proves the whole body composes end-to-end (the
// consolidated post-condition bundle, `d42_answer_with_memory_consolidated_test.dart`).
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
// ── How the cold-classification path is detected (Q-D.40.1) ─────────
//
// The plan phrases the trigger as "the prompt embedding lands far from any
// existing centroid (cold-classification path)". The body does not re-embed
// the prompt or call `classify`: the spec § 4.4 header pins this procedure's
// `requires` to `[recall, llm, persist, edge, note, stack.push]` — neither
// `embed` nor `classify` is in that set, and `classify` is not even part of
// the bridged primitive surface (`BridgedPrimitiveCatalog`). The cold signal
// is therefore read off the recall the body already ran: recall step 1 runs
// the four-mode pipeline *including vector mode*, which embeds the prompt and
// looks for neighbours. When that recall surfaces **no nodes at all**, the
// prompt embedding found nothing close in memory — the operational proxy for
// "far from any existing centroid". A topic memory knows nothing about is
// exactly what the brain should grow curious about, so the body persists an
// `InterestItem` (`topic` = the prompt, `why` = the cold-path reason) and
// pushes it onto the `interests` bootstrap stack. See Q-D.40.1.
//
// ── Why the `InterestItem` is not reported in `producedNodeIds` (Q-D.40.2) ──
//
// Unlike the `Conclusion`, the `InterestItem` is *not* added to the reserved
// `producedNodeIds` channel: the bootstrap `InterestItem` schema's
// `allowed_incoming` is `[satisfied_by, mentions, derived_from]` — it does not
// permit `produced_by`, so asking the recorder to draw a `produced_by` edge to
// it would be rejected by the edge-permission table. The interest is recorded
// and stacked; its run linkage is the trail, not a `produced_by` edge.
//
// ── How the identical-shape repetition is detected (Q-D.41.1) ───────
//
// The plan asks for the note "if the prompt matches a recent identical-shape
// prompt (cheap repetition check)". Step 3 already persists every inbound
// prompt as an immutable `Event` whose `summary` is the prompt text. So the
// cheapest possible identical-shape signal is: did the four-mode recall in
// step 1 surface a prior `Event` whose `summary` equals *this* prompt? That
// is exactly an earlier turn where the user asked the same thing. The body
// reads it off the recall it already holds — `_isRepeatPrompt(recall, text)`
// scans the recalled nodes for an `Event` with a matching `summary` — so no
// second memory query is spent (the "cheap" in the spec). The new `Event` for
// *this* turn is persisted in step 3, which runs *after* recall, so it can
// never be the node that matches (no self-match). When a match is found the
// body emits `note('automation_candidate', {why, signature})`; the dispatcher
// harvester (D.31) reads that category off the trail. See Q-D.41.1.
//
// Cold path and repeat path are mutually exclusive in practice: the cold-path
// interest (D.40) fires only when recall returned *nothing*, while a repeat
// requires recall to have surfaced the prior `Event`.
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
// `mem.persist(...)` and `mem.edge(...)` (D.39) and `mem.stackPush(...)`
// (D.40) resolve through the same `memory_bridge.dart` import.
//   - `…/src/primitives_native/primitives_native.dart` brings the bare
//     engine-native `note(...)` global into scope so `note('automation_'
//     'candidate', …)` resolves (D.41). `note` is registered as a top-level
//     function, not a bridge method, so it is reached by import, not via a
//     `mem.`/`sub.` receiver (`native_primitives_installer.dart`).
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
// 4–5 — `requires` must match the body's actual calls). As of D.41:
//   - `text` is `required: true` — step 1 reads it for `recall`, step 2
//     folds it into the assembled prompt, step 3 persists it as the `Event`,
//     step 4 records it as the `InterestItem.topic` on the cold path, step 5
//     uses it as the identical-shape repetition key and the note signature;
//   - `requires` is `[recall, llm, persist, edge, stack.push, note]` — the
//     bridged primitives the body calls (memory recall + substrate completion
//     + node persist + edge creation + the cold-path `interests` stack push +
//     the repetition `automation_candidate` trail note). The list is a set;
//     order is immaterial (the validator compares membership, § 7 row 5);
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
import 'package:tom_brain_procedure_prototype/src/primitives_native/primitives_native.dart';

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

  // D.40 — cold-classification interest push. When the four-mode recall
  // (vector mode included) surfaced nothing, the prompt landed far from any
  // existing memory/centroid: the brain is curious about a topic it knows
  // nothing about, so it records an InterestItem and pushes it onto the
  // `interests` bootstrap stack. The InterestItem is intentionally not added
  // to `producedNodeIds` — its schema does not permit an incoming
  // `produced_by` edge (Q-D.40.2).
  if (_isColdRecall(recall)) {
    final interestId = await mem.persist(
      'InterestItem',
      {
        'topic': text,
        'why': 'The prompt matched no existing memory on recall '
            '(cold-classification path).',
      },
      producer: producer,
    );
    await mem.stackPush('interests', interestId, producer: producer);
  }

  // D.41 — automation-candidate note. The recall in step 1 already ran the
  // four-mode pipeline; if it surfaced a prior `Event` whose `summary` is
  // *identical* to this prompt, the user has asked this exact thing before —
  // an "identical-shape" repetition the dreaming/harvester layer may want to
  // turn into a procedure. The body surfaces that signal with a
  // `note('automation_candidate', …)` on the run trail (the wire the
  // dispatcher's harvester keys on, spec § 5.1 / § 11 step 5). This is a
  // cheap repetition check — it reads the recall in hand, it does not
  // re-query memory (Q-D.41.1).
  if (_isRepeatPrompt(recall, text)) {
    note('automation_candidate', {
      'why': 'The inbound prompt is identical to a prior prompt already in '
          'memory (cheap repetition check) — a candidate for automation.',
      'signature': text,
    });
  }

  // The engine reads `producedNodeIds` to drive the run recorder's
  // `produced_by` edge (Conclusion → ProcedureRun), then strips the key so
  // `answer` stays the only surfaced output.
  return <String, Object?>{
    'answer': answer,
    'producedNodeIds': [conclusionId],
  };
}

/// Whether the recall came back empty — the operational proxy for "the prompt
/// embedding landed far from any existing centroid" (the cold-classification
/// path). The four-mode recall runs vector mode, so an empty result means the
/// prompt found no close neighbour in memory. See Q-D.40.1.
bool _isColdRecall(Map recall) {
  final nodes = recall['nodes'];
  if (nodes is List) {
    return nodes.isEmpty;
  }
  return true;
}

/// Whether the recall surfaced a prior `Event` carrying *exactly* this
/// prompt — the cheap "identical-shape repetition" check (D.41). Step 3
/// persists every inbound prompt as an `Event` whose `summary` is the prompt
/// text, so an earlier identical prompt resurfaces here as a recalled `Event`
/// node with a matching `summary`. Reading it off the recall already in hand
/// keeps the check cheap — no second memory query (Q-D.41.1).
bool _isRepeatPrompt(Map recall, Object? text) {
  final nodes = recall['nodes'];
  if (nodes is List) {
    for (final node in nodes) {
      if (node is Map && node['typeName'] == 'Event') {
        final values = node['values'];
        if (values is Map && values['summary'] == text) {
          return true;
        }
      }
    }
  }
  return false;
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
