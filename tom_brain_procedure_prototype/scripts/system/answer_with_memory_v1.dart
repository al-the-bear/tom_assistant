/// @procedure
/// id: answer_with_memory_v1
/// version: 1
/// summary: Recall relevant memory, answer the user, persist the exchange.
/// successCriterion: A streamed answer is delivered and an Event + Conclusion
///   + edges are persisted (the recall → answer → persist loop; the body is
///   built across D.37–D.42).
/// budget: { wallClockMs: 14400000 }
/// # Only a wall-clock deadline (§ 5.4): a user request is virtually unlimited
/// # on every count dimension. 14400000 ms (240 min) is the spec's external
/// # default (§ 5.4) — a runaway-stop for a genuinely hung run, not a throttle.
/// # A runaway *memory-write* loop is handled non-fatally by the per-run
/// # MemoryWriteGuard (§ 5.4.1), never by a fatal count cap.
/// inputs:
///   - { name: text, type: String, required: true }
///   - { name: priorTurns, type: List, required: false }
/// outputs:
///   - { name: answer, type: String }
/// requires: [ runProcedure, embed, classify, llm, persist, edge, stack.push, note, tool.list, tool.invoke ]
//
// answer_with_memory_v1 — the prototype's one real system procedure
// (`prototype_implementation_plan.md` D.10 / D.36–D.42;
// `tom_brain_procedure_prototype_specification.md` § 4.4, § 11).
//
// D.37 (plan): "Step 1 — recall." As of Extension-H step #30 this no longer
// calls `mem.recall` directly: it dispatches the `retrieve_for_prompt_v1`
// conductor (spec § 23.2), which runs the cheap non-LLM pass plus the LLM
// `recall_*` strategies within budget and fuses every seed into one
// `recall.multi`. The conductor returns the same `{nodes, report, provenance}`
// shape the old direct recall produced, so steps 2–5 are unchanged. The
// migration is total (PE-9) — the direct `mem.recall` call is gone, not shimmed.
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
// the fourth body step, and it implements the plan literally: the body embeds
// the prompt (`sub.embed`) and classifies that vector against memory's node-
// type centroids (`mem.classify`). A `decision == 'unknown'` is memory's own
// signal that the embedding sits below `minConfidence` from every centroid —
// or that no centroid exists yet (cold start) — i.e. the prompt is genuinely
// far from anything memory already knows. The brain is curious about a topic
// it has no memory of, so the body records an `InterestItem` and pushes it
// onto the `interests` bootstrap stack.
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
// existing centroid (cold-classification path)", and the body implements
// exactly that — it does **not** infer the cold signal from an empty recall.
// Step 4 embeds the prompt with `sub.embed` and hands the resulting vector to
// `mem.classify(embedding, target: 'nodeType')`, the LLM-free centroid-
// distance classifier (memory § 7.2). The classifier returns one of three
// decisions; `'unknown'` is precisely "the input is below `minConfidence`
// against every centroid, or no centroid for the target exists yet (cold
// start)" — the spec's literal "far from any existing centroid". On that
// decision the body persists an `InterestItem` (`topic` = the prompt, `why`
// = the cold-path reason) and pushes it onto the `interests` bootstrap stack.
//
// This is the centroid-distance mechanism the spec calls for, not the earlier
// empty-recall proxy: an empty recall and a cold classification are different
// facts (a prompt can recall neighbours by BM25/vector yet still sit far from
// every *centroid*, and vice-versa). `embed` (a substrate tool callout) and
// `classify` (a memory read) are therefore in this procedure's `requires`
// header (§ 4.4) and on the bridged primitive surface
// (`BridgedPrimitiveCatalog`). See Q-D.40.1.
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
// Cold path and repeat path read independent signals: the cold-path interest
// (D.40) fires on a centroid-distance `classify` decision of `'unknown'`,
// while a repeat (D.41) fires when recall surfaced a prior `Event` with this
// exact `summary`. They are not coupled — a prompt could in principle classify
// `'unknown'` yet also recall a prior identical `Event` (e.g. before any
// centroid was learned) — and the body evaluates each on its own merits.
//
// ── Token streaming and `Access.deliver` (Q-D.38.1; P1.3 #8) ────────
//
// This body does not change to stream — it streams *automatically*. The
// engine binds a per-run token sink to the substrate bridge's `onToken`
// (`engine.invoke(tokenSink: …)`, threaded by the dispatcher route from
// `Access.deliver`), so each substrate chunk this body's `sub.llm(...)` call
// pulls is forwarded to the live caller as it arrives — while `sub.llm` still
// returns the *concatenated* `answer` text (Q-C.13.1) the body hands back as
// its `answer` output. On the external/user path the route streams those
// deltas and closes with an empty final marker; on an internal / free-time
// run no sink is bound and `sub.llm` falls back to buffer-only. A body that
// needs to stream text it authors *outside* an `sub.llm` call uses the `emit`
// primitive, which shares the same per-run sink; this body has no such text.
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
//   - `…/src/api/procedure_result.dart` names the `ProcedureResult` type the
//     conductor dispatch returns so `retrieval.output('recall')` resolves
//     (`procedure_result_bridge.dart`, step #30);
//   - `…/src/bridges/memory_bridge.dart` brings the `mem` global into scope
//     so `mem.persist(...)` / `mem.edge(...)` / `mem.classify(...)` /
//     `mem.stackPush(...)` resolve (`brain_bridges_registrar.dart`);
//   - `…/src/bridges/substrate_bridge.dart` brings the `sub` global into
//     scope so `sub.llm(...)` / `sub.embed(...)` resolve (D.38).
//   - `…/src/primitives_native/primitives_native.dart` brings the bare
//     engine-native `runProcedure(...)` global into scope so step 1's conductor
//     dispatch resolves (step #30), and the `note(...)` global so
//     `note('automation_candidate', …)` resolves (D.41). Both are registered as
//     top-level functions, not bridge methods, so they are reached by import,
//     not via a `mem.`/`sub.` receiver (`native_primitives_installer.dart`).
// These imports are the only surface this body touches; everything else is
// denied (PE-1). The static `SandboxValidator` allow-lists exactly these
// host-injected library URIs and rejects every other `import` (plus `export`
// and the SDK-gateway identifiers); the engine runs that gate on every
// resolved procedure before the host is built (E.3.5 reconciled the old
// blanket import ban with this import-to-reach-`mem`/`sub` convention,
// Q-D.37.1). So this body passes the gate precisely because its imports are
// the allow-listed ones.
//
// ── Header fields tracked to the body ───────────────────────────────
//
// The machine-validated header fields track the body, not the summary, so
// the artifact stays internally coherent (`ContractValidator`, § 7 rows
// 4–5 — `requires` must match the body's actual calls). As of D.41:
//   - `text` is `required: true` — step 1 forwards it (via `inputs`) to the
//     retrieval conductor, step 2 folds it into the assembled prompt, step 3
//     persists it as the `Event`, step 4 embeds it (`sub.embed`) to classify it
//     and records it as the `InterestItem.topic` on the cold path, step 5 uses
//     it as the identical-shape repetition key and the note signature;
//   - `requires` is `[runProcedure, embed, classify, llm, persist, edge,
//     stack.push, note]` — the bridged primitives the body calls (the retrieval
//     conductor dispatch + the cold-path embed/classify pair + substrate
//     completion + node persist + edge creation + the cold-path `interests`
//     stack push + the repetition `automation_candidate` trail note). The list
//     is a set; order is immaterial (the validator compares membership,
//     § 7 row 5);
//   - the only declared output is `answer` (the concatenated LLM answer
//     text). The body also returns the reserved `producedNodeIds` key, which
//     the engine consumes (to draw the run's `produced_by` edge) and strips
//     before surfacing the result — it is a body→engine transport channel,
//     not a declared output.
//
// `ProcedureResult`'s *read* surface is bridged into d4rt as of step #30
// (`procedure_result_bridge.dart`) so this body can inspect the conductor
// dispatch's result (`retrieval.output('recall')`); the result *construction*
// is still the engine's job, so the entry point returns a plain `Map` the
// engine coerces into a succeeded result. The strict
// `Future<ProcedureResult> run(ProcedureInputs inputs) async` entry shape
// arrives once the engine coerces a returned result wrapper.
//
// The anchor invariant (PE-7) holds structurally: `sub.llm` is the only
// completion path and it names a `role` + supplies `inputs` — it can never
// hand the substrate a pre-assembled wire prompt, so the assistant-dedication
// anchor is always prepended at the substrate's assembly time. The prompt
// this body builds is the role template's `prompt` *input*, not the wire
// prompt.
import 'package:tom_brain_procedure_prototype/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure_prototype/src/api/procedure_result.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/tool_bridge.dart';
import 'package:tom_brain_procedure_prototype/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');

  // Step 1 — recall via the retrieval conductor (Extension-H step #30, spec
  // § 23.2). The conductor runs the cheap non-LLM pass plus the LLM `recall_*`
  // strategies within budget and fuses every seed into one `recall.multi`,
  // returning `{nodes, report, provenance}` — the same shape `mem.recall` used
  // to return, so the downstream prompt assembly / citation / repeat checks are
  // unchanged. The migration is total (PE-9): the old direct `mem.recall` call
  // is gone, not shimmed. The conductor is dispatched as its own sub-procedure
  // (its own ProcedureRun, depth budget, effort budget), and `inputs` is
  // forwarded straight through (it already carries `text`).
  final retrieval = await runProcedure('retrieve_for_prompt_v1', inputs);
  final recall = retrieval.output('recall');

  // Step 2 (local-history slice) — the dispatcher route threads the answering
  // session's earlier turns in under `priorTurns` (access spec § 7.2 / § 21.5),
  // each a `{user, assistant}` map. Absent on a cold first turn, so default to
  // empty — the prompt is then exactly what it was before (PE-9). This is the
  // minimal local-history assembly the prototype owns until `call_llm_v1`
  // (§ 21.5) takes over the full assembler.
  final priorTurns = inputs.has('priorTurns') ? inputs.get('priorTurns') : null;
  // The dispatcher route threads the default tool catalogue in under
  // `toolCatalogue` (procedure spec § 21.4) so a memoryless substrate can name
  // the tools it has in the *awareness* block of the assembled prompt. The
  // block is prose only — what the model may actually *call* comes from the
  // live `tool.list()` surface below (the engine binds the `tool` global on
  // every run). Absent on hosts that pass no catalogue, so default to empty
  // (PE-9: the awareness block is then unchanged from before).
  final toolCatalogue =
      inputs.has('toolCatalogue') ? inputs.get('toolCatalogue') : null;

  // Step 2 — answer the user, running the complete tool-calling loop
  // (procedure spec § 21.2 / § 11 step 2). The live `tool.list()` surface is
  // the source of truth for what the model may call: it is policy-narrowed to
  // exactly the tools this run exposes, so a tool offered to the substrate is a
  // tool `tool.invoke` will accept. Each turn offers that catalogue; when the
  // model proposes tool calls we run them through `tool.invoke`, fold the
  // results back into the running transcript, and re-enter — until the model
  // answers with no tool call (or the turn cap is hit). The final answer
  // streams to the live caller through the engine's per-run token sink: under
  // the OpenAI protocol a tool-deciding turn emits no answer text, so only the
  // terminal answer reaches the user; the intermediate turns stream nothing.
  const maxToolTurns = 6;
  final liveTools = await tool.list();
  var transcript = _assemblePrompt(recall, text, priorTurns, toolCatalogue);
  Map completion = const <String, Object?>{'text': ''};
  for (var turn = 0; turn < maxToolTurns; turn++) {
    // On the last allowed turn, withhold the catalogue so the model must
    // answer — no further round-trip is possible — which also keeps the
    // streamed terminal answer clean.
    final offerTools = turn < maxToolTurns - 1;
    completion = await sub.llm(
      transcript,
      role: 'assistant_to_user',
      tools: offerTools ? liveTools : null,
    );
    final toolCalls = completion['toolCalls'];
    if (toolCalls is! List || toolCalls.isEmpty) break;
    // The awaited value is hoisted into its own local before the assignment:
    // d4rt mis-scopes the assignment target of `x = f(x, await g())` (an
    // `await` inside the argument list of a call whose result feeds back into
    // `x`), so the awaited call must settle into a local first.
    final toolResults = await _runToolCalls(toolCalls);
    transcript = _appendToolResults(transcript, toolResults);
  }
  final answer = completion['text'];

  // D.39 — persist the exchange. The body has no run id, so its writes carry
  // the procedure id as the producer (Q-D.39.3).
  final producer = 'answer_with_memory_v1';

  // The real memory store does not embed lazily (#24; node_persister.dart
  // EmbeddingPolicyViolation.missingEmbedding) — every node type that declares
  // an embedding policy requires the *writer* to supply a dimension-correct
  // vector. Event, Conclusion and InterestItem all declare one, so the body
  // embeds before each persist. The prompt is embedded once here and reused
  // for the Event (whose `summary` is the prompt), the cold-path
  // classification (step 4) and the cold-path InterestItem (whose `topic` is
  // the prompt); only the Conclusion needs its own embedding (over the answer).
  final promptEmbedding = await sub.embed(text);

  // The inbound prompt becomes an immutable Event. `payload` is empty for a
  // bare prompt; `occurred_at` is omitted — the cognition layer has no clock
  // primitive, so the store's `createdAt` stamp carries the wall-clock (the
  // bootstrap `Event.occurred_at` is nullable for exactly this reason).
  await mem.persist(
    'Event',
    {'summary': text, 'payload': <String, Object?>{}},
    producer: producer,
    embedding: promptEmbedding['vec'],
  );

  // The answer becomes a Conclusion, embedded over the answer statement.
  final answerEmbedding = await sub.embed(answer);
  final conclusionId = await mem.persist(
    'Conclusion',
    {'statement': answer, 'rationale': 'Answered from recalled memory.'},
    producer: producer,
    embedding: answerEmbedding['vec'],
  );

  // derived_from: the Conclusion was derived from each recalled node it cited.
  // This procedure declares no count caps in its header budget (spec § 5.4): a
  // user request runs virtually unlimited, so the successCriterion ("an Event +
  // Conclusion + edges are persisted") is never refused by the fatal
  // `BudgetLedger`. The non-fatal `MemoryWriteGuard` is the only backstop — it
  // dedups a repeated edge and caps a runaway loop, skipping (never failing) the
  // excess. The answer was already produced and streamed above (Q-D.39), so a
  // partial write never silences it.
  //
  // A skipped Conclusion persist returns the empty-id sentinel; drawing edges
  // from it would be meaningless, so the loop is gated on a real id.
  if (conclusionId.isNotEmpty) {
    final cited = _citedNodeIds(recall);
    for (final nodeId in cited) {
      await mem.edge(conclusionId, 'derived_from', nodeId, producer: producer);
    }
  }

  // D.40 — cold-classification interest push. Embed the prompt and classify
  // the vector against memory's node-type centroids. A `'unknown'` decision
  // means the embedding is below `minConfidence` from every centroid (or no
  // centroid exists yet) — the prompt landed far from anything memory already
  // knows. The brain is curious about a topic it knows nothing about, so it
  // records an InterestItem and pushes it onto the `interests` bootstrap
  // stack. The InterestItem is intentionally not added to `producedNodeIds` —
  // its schema does not permit an incoming `produced_by` edge (Q-D.40.2).
  final classification =
      await mem.classify(promptEmbedding['vec'], target: 'nodeType');
  if (classification['decision'] == 'unknown') {
    final interestId = await mem.persist(
      'InterestItem',
      {
        'topic': text,
        'why': 'The prompt embedding landed far from every existing centroid '
            '(cold-classification path).',
      },
      producer: producer,
      embedding: promptEmbedding['vec'],
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

/// Executes each proposed tool call through the live `tool.invoke` surface
/// and returns one record per call for folding back into the transcript.
///
/// `tool.invoke` already returns its own `{ok: false, error}` for the three
/// pre-flight failures (unknown tool, policy-denied, args fail the input
/// schema), so those never throw here. A tool that *throws while running*
/// (e.g. an unavailable downstream surface) is caught and turned into the same
/// `{ok: false, error}` shape so one failing tool never aborts the whole
/// answer — the model sees the error and can recover on the next turn. The
/// broad catch is safe: this procedure declares no count caps (§ 5.4), so
/// `tool.invoke`'s pre-charge can never raise `ProcedureBudgetExceeded`; the
/// only thing reaching the catch is a genuine tool-run failure.
///
/// Each `toolCalls` entry is `{id, name, arguments}` (substrate bridge wire
/// shape); a non-map entry or one with a non-String `name` is skipped (PE-1:
/// the proposal came across an untrusted boundary).
Future<List> _runToolCalls(List toolCalls) async {
  final results = [];
  for (final call in toolCalls) {
    if (call is! Map) continue;
    final name = call['name'];
    if (name is! String) continue;
    final args = <String, Object?>{};
    final rawArgs = call['arguments'];
    if (rawArgs is Map) {
      rawArgs.forEach((key, value) => args['$key'] = value);
    }
    Object? outcome;
    try {
      outcome = await tool.invoke(name, args);
    } catch (e) {
      outcome = <String, Object?>{'ok': false, 'error': '$e'};
    }
    results.add(<String, Object?>{
      'name': name,
      'args': args,
      'outcome': outcome,
    });
  }
  return results;
}

/// Folds a turn's tool results back into the running transcript as a "Tool
/// results" block so the next completion can answer (or call again). An empty
/// result list leaves the transcript unchanged (the loop would not have called
/// this without at least one proposed call, but the guard keeps the function
/// total).
String _appendToolResults(String transcript, List results) {
  if (results.isEmpty) return transcript;
  var block = 'Tool results:\n';
  for (final record in results) {
    if (record is! Map) continue;
    block += '- ${record['name']}(${record['args']}) → ${record['outcome']}\n';
  }
  return '$transcript\n$block';
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

/// Builds the role-template `prompt` input from the prior conversation turns,
/// the recalled memory, and the inbound prompt. The earlier turns of this
/// conversation (`priorTurns`, access spec § 7.2 / § 21.5) are rendered first
/// as `User:` / `Assistant:` lines so the substrate sees what was already said;
/// then each recalled node's `text` value becomes a context line; then the
/// user's live prompt. An empty / absent history and an empty recall each drop
/// their block, so a cold first turn sends only the user prompt (PE-9).
String _assemblePrompt(
    Map recall, Object? text, Object? priorTurns, Object? toolCatalogue) {
  final tools = _renderToolCatalogue(toolCatalogue);
  final history = _renderPriorTurns(priorTurns);

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
  return '$tools$history${preamble}User prompt:\n$text';
}

/// Renders the default tool catalogue as a "Tools available to you" block, or
/// `''` when there is none. Each descriptor is a `{name, group, description}`
/// map (procedure spec § 21.4); the block names the tools and tells the model
/// the exact, parseable call format to use.
///
/// The format instruction is load-bearing: without it a substrate guesses its
/// own provider's chat-template dialect (the live Gemma-on-oMLX bug emitted
/// `<|tool_call>call:web.search{…}<tool_call|>`), and even though the bridge's
/// multi-dialect recovery now reads many of those, a single canonical example
/// makes the model emit a *clean* call far more reliably. The instructed shape
/// — `call:NAME{arg: value}` on its own — is exactly what
/// `parseToolCallsFromText` lowers; emitting only the call line (no
/// surrounding prose) keeps the streamed tool-deciding turn clean.
String _renderToolCatalogue(Object? toolCatalogue) {
  if (toolCatalogue is! List || toolCatalogue.isEmpty) return '';
  var rendered = '';
  for (final tool in toolCatalogue) {
    if (tool is! Map) continue;
    final name = tool['name'];
    if (name == null || '$name'.isEmpty) continue;
    final group = tool['group'];
    final description = tool['description'];
    final groupSuffix =
        (group != null && '$group'.isNotEmpty) ? ' ($group)' : '';
    final descSuffix =
        (description != null && '$description'.isNotEmpty) ? ': $description' : '';
    rendered += '- $name$groupSuffix$descSuffix\n';
  }
  if (rendered.isEmpty) return '';
  final howToCall = 'To use a tool, reply with ONLY a single call line and no '
      'other text, using the exact tool name from the list above:\n'
      '  call:TOOL_NAME{arg1: "value", arg2: 123}\n'
      'For a tool with no arguments use empty braces: call:TOOL_NAME{}\n'
      'Example: call:memory.read{query: "project history"}\n'
      'If you do not need a tool, just answer the user in plain prose.\n';
  return 'Tools available to you:\n$rendered\n$howToCall\n';
}

/// Renders the prior conversation turns as `User:` / `Assistant:` lines (the
/// § 22.4 history-compactor convention), or `''` when there are none. Each
/// turn is a `{user, assistant}` map; a turn with no answer yet (the live turn,
/// should it ever be included) renders user-only.
String _renderPriorTurns(Object? priorTurns) {
  if (priorTurns is! List || priorTurns.isEmpty) return '';
  var rendered = '';
  for (final turn in priorTurns) {
    if (turn is! Map) continue;
    final user = turn['user'];
    final assistant = turn['assistant'];
    if (user != null && '$user'.isNotEmpty) {
      rendered += 'User: $user\n';
    }
    if (assistant != null && '$assistant'.isNotEmpty) {
      rendered += 'Assistant: $assistant\n';
    }
  }
  return rendered.isEmpty ? '' : 'Conversation so far:\n$rendered\n';
}
