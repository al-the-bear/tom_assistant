/// @procedure
/// id: answer_with_memory_v1
/// version: 1
/// summary: Recall relevant memory, answer the user via the registered prompt,
///   persist the exchange.
/// successCriterion: A streamed answer is delivered and an Event + Conclusion
///   + edges are persisted (the recall → answer → persist loop; the body is
///   built across D.37–D.42 and migrated onto `sub.run` in increment 6).
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
///   - { name: incomplete, type: bool }
/// requires: [ runProcedure, run, llm, embed, classify, persist, edge, stack.push, note, tool.invoke ]
//
// answer_with_memory_v1 — the prototype's one real system procedure
// (`prototype_implementation_plan.md` D.10 / D.36–D.42;
// `tom_brain_procedure_specification.md` § 4.4, § 11;
// `prompt_configuration.md` increment 6).
//
// ── What increment 6 changed (the normal-path migration) ────────────
//
// Before increment 6 step 2 hand-wrote its own prompt assembly (recall /
// history / tool-catalogue / todo-discipline rendering) and its own
// send→parse→execute→re-send `while` loop. Increment 6 deletes all of that:
//   - the prompt assembly moves into the registered prompt
//     `assist_user.answer_with_memory.assembly` (its template + the injected
//     `PromptResolver` resolve `${recall}` / `${history}` / `${text}` /
//     `${open_todo_reminder}`; the engine renders `${tools.catalogue}` from the
//     prompt's resolved tool set, § 7.4); and
//   - the inner tool loop moves into the shared `tool_loop_v1.dart` script,
//     which `sub.run` delegates to (§ 7.2).
// The body now calls `sub.run(promptId, inputs:)` once per outer iteration; the
// inline `_assemblePrompt` / `_renderToolCatalogue` / `_renderArgsSchema` /
// `_renderPriorTurns` / `_todoDisciplineBlock` / `_runToolCalls` /
// `_appendToolResults` / `_appendToolCallError` builders are gone (§ 11). The
// migration is total (principle 1 / PE-9): there is no inline fallback.
//
// ── What stays with this procedure (the outer orchestration, § 7.2) ──
//
// `tool_loop_v1` owns only the mechanical inner cycle bounded by
// `max_tool_loops`. The **outer** orchestration — todo-based termination —
// stays here, exactly as § 7.2 prescribes ("the outer orchestration
// (todo-based termination, thinking critique/re-entry) stays in each calling
// procedure"). Each outer iteration runs `sub.run` to completion (a plain
// answer, or `max_tool_loops` exhaustion); the body then consults the live
// session todo store and, while open todos remain, re-enters `sub.run` with an
// `open_todo_reminder` folded into the prompt and the accumulating answer
// carried forward so the next pass sees what was already drafted. The sole
// non-todo exit is the wall-clock runaway-stop, enforced externally by the
// engine (§ 3.3), so the body itself loops purely on `!finished`.
//
// The bootstrap "zero-work exit" hazard (§ 3.2) cannot arise: termination is
// only evaluated *after* a completed `sub.run` answer, so the loop always
// produces at least one answer before it can finish — a trivial prompt that
// seeds no todos answers once (open == 0) and exits.
//
// ── The persist / classify / note steps are unchanged ───────────────
//
// D.39 (persist the exchange), D.40 (cold-classification interest push) and
// D.41 (automation-candidate note) are pure side-effects over the recall +
// answer the body already holds; the migration does not touch them. Their
// rationale, the `produced_by`-edge ownership split (the engine draws it from
// `producedNodeIds`), the write-provenance note (Q-D.39.3), the cold-path
// centroid-distance detection (Q-D.40.1) and the cheap identical-shape
// repetition check (Q-D.41.1) all carry over verbatim from the pre-migration
// body and are summarised inline at each step below.
//
// ── Why the `produced_by` edge is the engine's job, not the body's ──
//
// The plan asks for a `produced_by` edge from the answer to the `ProcedureRun`
// node, but the body cannot draw it: the authoritative final `ProcedureRun`
// node does not exist yet — the `RunRecorder` persists it at `complete()`,
// *after* the body returns (the two-node split, recorder Q-C.31.1). So the body
// persists the nodes and reports the `Conclusion` id under the reserved
// `producedNodeIds` output key; the engine threads that list into the
// completion and the recorder draws the edge. Only the `Conclusion` is
// reported — the `Event` records the inbound prompt and is not a "produced
// result" (Q-D.39.1 / Q-D.39.2).
//
// ── Token streaming and `Access.deliver` (Q-D.38.1; P1.3 #8) ────────
//
// This body does not change to stream — it streams *automatically*. The engine
// binds a per-run token sink to the substrate bridge's `onToken`, threaded by
// the dispatcher route from `Access.deliver`, so each substrate chunk
// `tool_loop_v1`'s `sub.send` pulls is forwarded to the live caller as it
// arrives. The per-call stream routing (§ 9.2) sends a tool-deciding turn's
// `call:NAME{…}` text to the **thinking** channel and a plain-answer turn's
// tokens to the **answer** channel, so the user reads only the final answer.
//
// ── How the body reaches its inputs and the bridges ─────────────────
//
// The engine hands the entry point a native `ProcedureInputs` and binds the
// memory + substrate + tool bridges + engine-native primitives as globals keyed
// to the library each is registered under. A d4rt script reaches each by
// importing that library:
//   - `…/src/api/procedure_inputs.dart` names `ProcedureInputs` so
//     `inputs.get('text')` dispatches onto the native bag (D.37);
//   - `…/src/api/procedure_result.dart` names `ProcedureResult` so the recall
//     conductor's `retrieval.output('recall')` resolves (step #30);
//   - `…/src/bridges/memory_bridge.dart` brings `mem` into scope so
//     `mem.persist` / `mem.edge` / `mem.classify` / `mem.stackPush` resolve;
//   - `…/src/bridges/substrate_bridge.dart` brings `sub` into scope so
//     `sub.run(...)` (the answering entry point) and `sub.embed(...)` (the
//     persist/classify embeddings) resolve;
//   - `…/src/bridges/tool_bridge.dart` brings `tool` into scope so the
//     outer-loop termination probe `tool.invoke('todo.list', …)` resolves;
//   - `…/src/primitives_native/primitives_native.dart` brings the bare
//     `runProcedure(...)` global (step 1's conductor dispatch) and the bare
//     `note(...)` global (D.41) into scope.
// These imports are the only surface this body touches; the static
// `SandboxValidator` allow-lists exactly these host-injected library URIs and
// rejects every other import (PE-1).
//
// The anchor invariant (PE-7 / principle 5) holds structurally: `sub.run` names
// a registered prompt whose role assembles persona + the assistant-dedication
// anchor at the substrate's assembly time — it can never hand the substrate a
// pre-assembled wire prompt. The transcript `tool_loop_v1` builds is supplied
// as the role template's `prompt` *input*, never as the wire prompt.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/tool_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

/// The registered prompt the answering step runs (§ 7.4). Resolving it yields
/// the role + LLM route + tool set + `max_tool_loops` and the loaded,
/// placeholder-resolved template body; `sub.run` renders `${tools.catalogue}`
/// and delegates the tool loop to `tool_loop_v1`.
const String _answerPromptId = 'assist_user.answer_with_memory.assembly';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');

  // Step 1 — recall via the retrieval conductor (Extension-H step #30, spec
  // § 23.2). The conductor runs the cheap non-LLM pass plus the LLM `recall_*`
  // strategies within budget and fuses every seed into one `recall.multi`,
  // returning `{nodes, report, provenance}`. `inputs` is forwarded straight
  // through (it already carries `text`).
  final retrieval = await runProcedure('retrieve_for_prompt_v1', inputs);
  final recall = retrieval.output('recall');

  // The dispatcher route threads the answering session's earlier turns under
  // `priorTurns` (access spec § 7.2 / § 21.5), each a `{user, assistant}` map.
  // Absent on a cold first turn, so default to empty.
  final priorTurns = inputs.has('priorTurns') ? inputs.get('priorTurns') : null;

  // Step 2 — answer the user through the registered prompt, running the inner
  // tool-calling loop (`tool_loop_v1`, delegated by `sub.run`) under
  // **LLM-driven completion confirmation** as the outer loop (§ 7.2 /
  // agent-loop completion plan § 3, revision 2026-06-14). Each `sub.run`
  // resolves the prompt afresh: the template renders the recall, the prior
  // turns, the user prompt and — on a re-entry — a continue reminder, then the
  // inner loop runs to a plain answer (or `max_tool_loops` exhaustion).
  //
  // Termination is no longer a mechanical open-todo count: after each draft the
  // loop asks the model — in its **normal `assistant_to_user` profile**, the same
  // persona/session that answers the user — whether this is the final answer
  // (`DONE`) or whether work still remains (`CONTINUE`), **presenting the live
  // todo list as evidence**. The confirmation turn streams to the *thinking*
  // channel (§ 9.2), so its `DONE`/`CONTINUE` text is an out-of-band notice and
  // never leaks into the user-visible answer. On `CONTINUE` the draft and the
  // are-you-done exchange are folded into `history` and the loop re-enters; on
  // `DONE` (or any non-`CONTINUE`, the never-hang default) it exits.
  //
  // `history` accumulates the drafts and confirmation exchanges across outer
  // iterations so a re-entry sees what was already said and why it is continuing
  // (the "accumulating iteration history" of § 6); it starts as the
  // dispatcher-threaded `priorTurns` and grows per pass.
  final history = <Object?>[];
  if (priorTurns is List) history.addAll(priorTurns);

  var answer = '';
  var finished = false;
  var reminder = '';
  while (!finished) {
    final completion = await sub.run(
      _answerPromptId,
      inputs: <String, Object?>{
        'text': text,
        'recall': recall,
        'priorTurns': List<Object?>.of(history),
        'open_todo_reminder': reminder,
      },
    );
    final answerText = completion['answer'];
    if (answerText is String && answerText.isNotEmpty) {
      answer = answerText;
    }

    // Completion confirmation — ask the model, presenting its live todo list,
    // whether the work is done. The reply text is captured both to decide
    // termination and to record the exchange in history on a continue.
    final todoList = await _renderTodoList();
    final question = _confirmationQuestion(text, todoList);
    final reply = await _confirmCompletion(question);
    finished = _isFinished(reply);
    if (!finished) {
      // The model wants to keep going. Record the draft and the are-you-done
      // exchange as ordinary chat turns, fold a continue reminder into the next
      // pass's prompt, then re-enter (§ 3.1 revision).
      history.add(<String, Object?>{'user': text, 'assistant': answer});
      history.add(<String, Object?>{'user': question, 'assistant': reply});
      reminder = _continueReminderText();
    }
  }

  // D.39 — persist the exchange. The body has no run id, so its writes carry
  // the procedure id as the producer (Q-D.39.3).
  final producer = 'answer_with_memory_v1';

  // The real memory store does not embed lazily — every node type that declares
  // an embedding policy requires the *writer* to supply a dimension-correct
  // vector. The prompt is embedded once here and reused for the Event (whose
  // `summary` is the prompt), the cold-path classification (step 4) and the
  // cold-path InterestItem (whose `topic` is the prompt); only the Conclusion
  // needs its own embedding (over the answer).
  final promptEmbedding = await sub.embed(text);

  // The inbound prompt becomes an immutable Event. `occurred_at` is omitted —
  // the store's `createdAt` stamp carries the wall-clock.
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
  // A skipped Conclusion persist returns the empty-id sentinel; drawing edges
  // from it would be meaningless, so the loop is gated on a real id.
  if (conclusionId.isNotEmpty) {
    final cited = _citedNodeIds(recall);
    for (final nodeId in cited) {
      await mem.edge(conclusionId, 'derived_from', nodeId, producer: producer);
    }
  }

  // D.40 — cold-classification interest push. Classify the prompt vector
  // against memory's node-type centroids. A `'unknown'` decision means the
  // embedding is below `minConfidence` from every centroid (or no centroid
  // exists yet) — the prompt landed far from anything memory already knows, so
  // it records an InterestItem and pushes it onto the `interests` stack. The
  // InterestItem is intentionally not added to `producedNodeIds` — its schema
  // does not permit an incoming `produced_by` edge (Q-D.40.2).
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

  // D.41 — automation-candidate note. If step 1's recall surfaced a prior
  // `Event` whose `summary` is *identical* to this prompt, the user has asked
  // this exact thing before — an "identical-shape" repetition the dreaming
  // layer may want to automate. This is a cheap repetition check — it reads the
  // recall in hand, it does not re-query memory (Q-D.41.1).
  if (_isRepeatPrompt(recall, text)) {
    note('automation_candidate', {
      'why': 'The inbound prompt is identical to a prior prompt already in '
          'memory (cheap repetition check) — a candidate for automation.',
      'signature': text,
    });
  }

  // The engine reads `producedNodeIds` to drive the run recorder's
  // `produced_by` edge (Conclusion → ProcedureRun), then strips the key so
  // `answer` and `incomplete` stay the surfaced outputs. `incomplete` is always
  // `false` on this path: the only non-todo exit (the wall-clock runaway-stop,
  // § 3.3) is enforced externally by the engine, not observable here.
  return <String, Object?>{
    'answer': answer,
    'incomplete': false,
    'producedNodeIds': [conclusionId],
  };
}

/// Whether the recall surfaced a prior `Event` carrying *exactly* this prompt —
/// the cheap "identical-shape repetition" check (D.41). Step 3 persists every
/// inbound prompt as an `Event` whose `summary` is the prompt text, so an
/// earlier identical prompt resurfaces here as a recalled `Event` node with a
/// matching `summary`. Reading it off the recall already in hand keeps the
/// check cheap — no second memory query (Q-D.41.1).
bool _isRepeatPrompt(Object? recall, Object? text) {
  if (recall is! Map) return false;
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

/// Renders the live session todo store as a human-readable checklist for the
/// completion-confirmation turn (§ 3.1 revision). `tool.invoke('todo.list', {})`
/// returns `{ok, result: {todos: […]}}`, each todo a `{id, text, done}` map;
/// each is rendered as `[x]`/`[ ] <text>`. A malformed or empty listing renders
/// the explicit "empty" line, so the confirmation turn always has a concrete
/// task list to reason over (never a silent gap).
//
// Keep in sync with answer_with_thinking_v1.
Future<String> _renderTodoList() async {
  final Object? listed = await tool.invoke('todo.list', <String, Object?>{});
  if (listed is! Map) return _emptyTodoList;
  final result = listed['result'];
  if (result is! Map) return _emptyTodoList;
  final todos = result['todos'];
  if (todos is! List || todos.isEmpty) return _emptyTodoList;
  final lines = <String>[];
  for (final entry in todos) {
    if (entry is! Map) continue;
    final box = entry['done'] == true ? '[x]' : '[ ]';
    lines.add('$box ${entry['text']}');
  }
  return lines.isEmpty ? _emptyTodoList : lines.join('\n');
}

/// The rendered task list shown when the session store holds no todos.
const String _emptyTodoList = '(your task list is currently empty)';

/// Builds the completion-confirmation prompt (§ 3.1 revision): it presents the
/// user request and the live [todoList] and asks the model — in its normal
/// `assistant_to_user` profile — to declare `DONE` or `CONTINUE`. The first-word
/// contract makes `_isFinished` cheap and unambiguous.
//
// Keep in sync with answer_with_thinking_v1.
String _confirmationQuestion(Object? text, String todoList) {
  return 'You have just produced an answer for the user. Before it is delivered, '
      'confirm whether your work is complete.\n\n'
      'The user asked:\n$text\n\n'
      'Your current task list:\n$todoList\n\n'
      'If your latest answer fully satisfies the request and no task still needs '
      'doing, reply with DONE as the first word. If there is still work to do '
      '(an open task, or the answer is incomplete), reply with CONTINUE as the '
      'first word, then one sentence on what remains.';
}

/// Issues the confirmation turn through the substrate in the normal
/// `assistant_to_user` profile, routed to the **thinking** channel (§ 9.2) so its
/// `DONE`/`CONTINUE` text surfaces as an out-of-band notice and never reaches the
/// user-visible answer. Returns the reply text (`''` on a non-string result).
//
// Keep in sync with answer_with_thinking_v1.
Future<String> _confirmCompletion(String question) async {
  final Object? completion =
      await sub.llm(question, role: 'assistant_to_user', channel: 'thinking');
  if (completion is! Map) return '';
  final reply = completion['text'];
  return reply is String ? reply : '';
}

/// Whether the confirmation [reply] declares the work finished (§ 3.1 revision).
/// `CONTINUE` (as the first word, case-insensitive) keeps the loop running;
/// everything else — `DONE`, an empty reply, or any unparseable text — finishes
/// the loop. Defaulting ambiguity to finished is the never-hang guarantee: an
/// unclear confirmation never spins the loop forever (the wall-clock runaway-stop
/// is the only other exit, § 3.3).
//
// Keep in sync with answer_with_thinking_v1.
bool _isFinished(String reply) {
  return !reply.trim().toUpperCase().startsWith('CONTINUE');
}

/// The reminder folded into the next pass's prompt (via the `open_todo_reminder`
/// template binding) after the model asked to continue, so the next answer pass
/// knows it is resuming unfinished work rather than starting fresh.
String _continueReminderText() {
  return 'You indicated your previous answer was not yet complete. Review your '
      'task list, continue the outstanding work, and mark each task done with '
      'todo.update as you finish it.';
}

/// Collects the ids of the recalled nodes that fed the answer prompt — the
/// nodes the Conclusion is `derived_from`.
List<String> _citedNodeIds(Object? recall) {
  final ids = <String>[];
  if (recall is! Map) return ids;
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
