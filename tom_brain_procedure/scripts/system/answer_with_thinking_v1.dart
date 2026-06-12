/// @procedure
/// id: answer_with_thinking_v1
/// version: 1
/// summary: The recursive thinking branch — analyse, sub-reason, synthesise,
///   self-critique, and re-enter until every session todo is done and the
///   critique accepts (todo-based termination), then persist the exchange.
/// successCriterion: a deliberation-cued prompt is answered through the
///   recursive loop — the loop dispatches its analyse/sub-think sub-prompts,
///   runs an `evaluator` critique each pass (the investigation of the last
///   answer), pushes the critique's missing pieces as session todos on REJECT,
///   and terminates only once every session todo is done AND the critique
///   accepts; an Event + Conclusion (+ derived_from edges to the cited recalled
///   nodes) are persisted on exit.
/// budget: { wallClockMs: 14400000 }
/// # Only a wall-clock deadline (§ 5.4): a foreground user prompt is virtually
/// # unlimited on every count dimension, exactly as `answer_with_memory_v1`.
/// # 14400000 ms (240 min) is the spec's external default — the **only** non-todo
/// # exit, a runaway-stop for a genuinely hung run, enforced externally by the
/// # engine (the body cannot read the clock; agent-loop completion plan § 3.3).
/// # Re-entry is bounded by the todo-based termination contract, not a count cap:
/// # the loop re-enters until the session todo store is empty and the critique
/// # accepts.
/// inputs:
///   - { name: text, type: String, required: true }
///   - { name: priorTurns, type: List, required: false }
/// outputs:
///   - { name: answer, type: String }
///   - { name: incomplete, type: bool }
/// requires: [ runProcedure, embed, llm, persist, edge, tool.list, tool.invoke ]
//
// answer_with_thinking_v1 — the thinking branch of the entry router
// (`tom_brain_completion_plan.md` Todo 6, gaps G-T1 / G-T4 / C-2;
// `thinking_specification.md` § 4.1–4.7). It supersedes the `think_v1` no-op
// stub: the router's `thinking` verdict now reaches a real recursive loop.
//
// ── How it is reached (§ 4.0.1, route-flip option b) ────────────────────
//
// This procedure is never selected directly. The dispatcher routes every
// `user_prompt` to the entry router `prompt_analyzer_v1`, reads its `target`
// output, and — when that target is `answer_with_thinking_v1` — launches *this*
// procedure as the top-level streaming run (its own foreground admission). The
// `normal` verdict reaches `answer_with_memory_v1` instead; the two branches
// are reachable only through the router's two-phase dispatch.
//
// ── The recursive loop (§ 4.1) ──────────────────────────────────────────
//
// A single forward pass is a reflex, not a thought (the quest's core belief).
// This body is the engineered process: it wraps the same substrate the normal
// branch uses in an analyse → sub-reason → synthesise → self-critique →
// re-enter loop terminated by the **todo-based contract** (agent-loop
// completion plan § 3), not a count cap. One pass through the `while` is one
// deliberation iteration:
//
//   A  analyse    — `sub.llm(role: 'analyser')` reads the prompt (and, on a
//                    re-entry, the prior rejected draft + its critique) and
//                    states what the answer must address.
//   B  sub-reason — `sub.llm(role: 'sub_thinker')` works the sub-questions the
//                    analysis surfaced. Memory recall (the other half of stage
//                    B, § 4.2) is dispatched *once* before the loop via the
//                    `retrieve_for_prompt_v1` conductor: the recalled context is
//                    stable across iterations; only the draft and the critique
//                    change, so re-recalling each pass would spend budget for an
//                    identical result.
//   C  synthesise — `sub.llm(role: 'assistant_to_user')` drafts the answer from
//                    the recall + analysis + sub-reasoning (+ the rejection
//                    context on a re-entry). Deliberately *no* `tools` argument:
//                    the synthesis is pure composition, and withholding the tool
//                    catalogue keeps the streamed terminal answer clean (§ 4.4).
//                    The loop body — not this stage — owns the `todo.*` calls.
//   D  critique   — `sub.llm(role: 'evaluator')` judges the draft and returns a
//                    verdict; `_isAccept` parses ACCEPT vs REJECT. This critique
//                    IS the "investigate the last answer" gate (§ 3 / § 5.2):
//                    its verdict feeds the todo-based termination, and on REJECT
//                    its missing pieces become concrete session todos.
//   E  re-enter   — on REJECT the rejected draft + critique are carried forward
//                    as `rejectionContext` AND pushed as a new session todo
//                    (`tool.invoke('todo.add', …)`) so there is tracked open
//                    work; on ACCEPT the loop marks the todos *it* pushed done
//                    (the accepted draft resolved them). The loop re-enters
//                    while any session todo is open or the critique rejected.
//
// ── Todo-based termination + the never-silent contract (§ 3, gap-hunt § 6.5) ─
//
// There is **no iteration cap**. Each pass computes, after the critique,
// `open = _openTodoCount()` (the live session todo store via `tool.invoke`) and
// `accepted = _isAccept(verdict)`, and the loop is finished iff
// `open == 0 && accepted` — every tracked piece of work is done AND the
// investigation accepts the draft. The single non-todo exit is the wall-clock
// runaway-stop (§ 3.3), enforced externally by the engine: the body cannot read
// the clock, so it loops purely on `!finished`. Because the session todo store
// is the source of truth, a REJECT that pushes a missing-piece todo cannot be
// "accepted away" until that work is cleared — investigation feeds termination.
//
// The body always exits with a critique-accepted, todo-clear answer, so
// `incomplete` is always `false` here (the only `incomplete = true` source is
// the external wall-clock runaway-stop, which is not observable in the body —
// agent-loop plan § 3.4). A foreground prompt is therefore never answered with
// silence: an answer is always produced, jointly authored by the run and the
// recalled memory.
//
// ── Persisting the exchange (§ 4.1, mirrors `answer_with_memory_v1`) ─────
//
// Whichever way the loop terminated, the exchange is persisted: the inbound
// prompt as an immutable `Event`, the answer as a `Conclusion`, and a
// `derived_from` edge from the Conclusion to each recalled node it cited. The
// body has no run id, so its writes carry the procedure id as the producer
// (Q-D.39.3); the authoritative `produced_by` edge (Conclusion → ProcedureRun)
// is the recorder's job, fed by the reserved `producedNodeIds` channel the
// engine splits off the returned map and strips before surfacing outputs (D.39,
// `producedNodeIdsOutputKey`). Embeddings are supplied before each persist
// because the real store does not embed lazily (every embedding-policy node
// type requires a dimension-correct vector from the writer).
//
// ── Imports / anchor (PE-1 / PE-7) ──────────────────────────────────────
//
// Only the host-injected libraries this body touches are imported, and the
// SandboxValidator allow-lists exactly these: `procedure_inputs` (so
// `inputs.get(...)` dispatches onto the native bag), `procedure_result` (so the
// recall conductor's `retrieval.output('recall')` resolves), `memory_bridge`
// (`mem.persist` / `mem.edge`), `substrate_bridge` (`sub.llm` / `sub.embed`),
// `tool_bridge` (`tool.list` / `tool.invoke` — the `todo.*` family the
// todo-based termination reads and writes; the engine binds the per-run `tool`
// global on every run), and `primitives_native` (the engine-native
// `runProcedure`). The synthesis stage still forbids tools — it passes no
// `tools:` argument to `sub.llm` — so the catalogue is never offered to the
// model; the loop *body* owns the `todo.*` calls directly. Every completion is
// an `sub.llm` call that names a `role` and supplies the prompt as the role
// template's *input* — never a pre-assembled wire prompt — so the
// assistant-dedication anchor is always prepended at substrate assembly time.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/tool_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');
  final priorTurns = inputs.has('priorTurns') ? inputs.get('priorTurns') : null;

  // Stage B (memory half) — recall once before the loop via the retrieval
  // conductor (§ 4.2; Extension-H step #30). The recalled context is stable
  // across iterations, so it is dispatched once and reused; `inputs` already
  // carries `text` and is forwarded straight through.
  final retrieval = await runProcedure('retrieve_for_prompt_v1', inputs);
  final recall = retrieval.output('recall');

  // Todo-based termination (§ 3): no iteration cap. The loop re-enters until the
  // live session todo store is empty AND the critique accepts the draft. The ids
  // of the todos this loop pushed (one per REJECT, holding the critique's missing
  // pieces) are tracked so an eventual ACCEPT can mark exactly those done — never
  // any pre-existing session todo the act stage owns.
  var draft = '';
  var rejectionContext = '';
  final pushedTodoIds = <String>[];
  var finished = false;

  // The exit condition is folded into the loop guard rather than using `break`:
  // the d4rt interpreter does not honour a `break` inside this async `while` (it
  // surfaces "Break statement outside of a loop"), so the loop runs while not
  // `finished`.
  while (!finished) {
    // Stage A — analyse the prompt (carrying the prior rejection on a re-entry).
    final analysisCompletion = await sub.llm(
      _analysisPrompt(text, recall, rejectionContext),
      role: 'analyser',
    );
    final analysis = analysisCompletion['text'];

    // Stage B (reasoning half) — work the sub-questions the analysis surfaced.
    final subCompletion = await sub.llm(
      _subThinkPrompt(text, analysis),
      role: 'sub_thinker',
    );
    final subReasoning = subCompletion['text'];

    // Stage C — synthesise the draft answer. No `tools`: synthesis is pure
    // composition (§ 4.4), and withholding the catalogue keeps the streamed
    // terminal answer clean.
    final draftCompletion = await sub.llm(
      _synthesisPrompt(
        text, recall, analysis, subReasoning, priorTurns, rejectionContext),
      role: 'assistant_to_user',
    );
    draft = draftCompletion['text'];

    // Stage D — self-critique: the investigation of the last answer. Its verdict
    // drives accept/re-enter and feeds the todo-based termination.
    final critiqueCompletion = await sub.llm(
      _critiquePrompt(text, draft),
      role: 'evaluator',
    );
    final verdict = critiqueCompletion['text'];
    final accepted = _isAccept(verdict);

    if (accepted) {
      // The accepted draft resolved the missing pieces this loop pushed — mark
      // exactly those done so the todo-based termination can fire. (Any other
      // open session todo, owned by the act stage, still blocks termination.)
      // The awaited update is hoisted into the loop body, not an argument
      // position, to stay clear of d4rt's `x = f(await g())` mis-scoping.
      for (final id in pushedTodoIds) {
        await tool.invoke(
          'todo.update', <String, Object?>{'id': id, 'done': true});
      }
    } else {
      // Stage E — re-entry: carry the rejected draft + its critique forward so
      // the next analysis knows what to fix, AND push the critique's missing
      // pieces as a concrete session todo so termination cannot fire until that
      // work is cleared. This is how "investigate the last answer" feeds the
      // todo-based termination (§ 5.2).
      rejectionContext = _rejectionContext(draft, verdict);
      final pushedId = await _pushMissingPieceTodo(verdict);
      if (pushedId.isNotEmpty) {
        pushedTodoIds.add(pushedId);
      }
    }

    // Termination: finished iff no session todo is open AND the investigation
    // accepted the draft. The wall-clock runaway-stop (§ 3.3) is the only
    // non-todo exit and is enforced externally — not observable here.
    final open = await _openTodoCount();
    finished = open == 0 && accepted;
  }

  // The body only exits when finished — a critique-accepted, todo-clear answer.
  // `incomplete` is therefore always false here; the only `incomplete = true`
  // source is the external wall-clock runaway-stop (§ 3.4), not observable in
  // the body. Never silence (gap-hunt § 6.5).
  final answer = draft;
  const incomplete = false;

  // Persist the exchange (§ 4.1). The body has no run id, so writes carry the
  // procedure id as the producer (Q-D.39.3).
  final producer = 'answer_with_thinking_v1';

  // The real store does not embed lazily — embed before each persist. The
  // prompt embedding feeds the Event (whose `summary` is the prompt); the
  // answer embedding feeds the Conclusion.
  final promptEmbedding = await sub.embed(text);
  await mem.persist(
    'Event',
    {'summary': text, 'payload': <String, Object?>{}},
    producer: producer,
    embedding: promptEmbedding['vec'],
  );

  final answerEmbedding = await sub.embed(answer);
  final conclusionId = await mem.persist(
    'Conclusion',
    {
      'statement': answer,
      'rationale': 'Answered through the recursive thinking loop — every '
          'session todo done and the self-critique accepted the draft.',
    },
    producer: producer,
    embedding: answerEmbedding['vec'],
  );

  // derived_from: the Conclusion was derived from each recalled node it cited.
  // A skipped persist returns the empty-id sentinel; gate the edge loop on a
  // real id (mirrors `answer_with_memory_v1`).
  if (conclusionId.isNotEmpty) {
    final cited = _citedNodeIds(recall);
    for (final nodeId in cited) {
      await mem.edge(conclusionId, 'derived_from', nodeId, producer: producer);
    }
  }

  // `producedNodeIds` is the reserved transport channel the engine consumes to
  // draw the run's `produced_by` edge, then strips before surfacing outputs.
  return <String, Object?>{
    'answer': answer,
    'incomplete': incomplete,
    'producedNodeIds': [conclusionId],
  };
}

/// Whether the evaluator's verdict is an acceptance. Conservative: anything
/// that is not an explicit ACCEPT — a REJECT, or an unparseable / non-string
/// verdict — keeps the loop deliberating (it re-enters, bounded by the budget),
/// so an ambiguous critique never short-circuits the deliberation.
bool _isAccept(Object? verdict) {
  if (verdict is! String) return false;
  return verdict.toUpperCase().contains('ACCEPT');
}

/// Counts the open (`done != true`) entries in the live session todo store via
/// the `todo.list` tool — the source of truth the loop terminates on (§ 3.1).
/// `tool.invoke('todo.list', {})` returns `{ok, result: {todos: […]}}`, each
/// todo a `{id, text, done}` map. A malformed or failed listing counts as zero
/// open (never a hang); the loop then terminates on the accepted draft in hand.
//
// Keep in sync with answer_with_memory_v1.
Future<int> _openTodoCount() async {
  final Object? listed = await tool.invoke('todo.list', <String, Object?>{});
  if (listed is! Map) return 0;
  final result = listed['result'];
  if (result is! Map) return 0;
  final todos = result['todos'];
  if (todos is! List) return 0;
  var open = 0;
  for (final entry in todos) {
    if (entry is Map && entry['done'] != true) open += 1;
  }
  return open;
}

/// Pushes the critique's "missing pieces" as one session todo (`todo.add`) and
/// returns its store-assigned id (or `''` on a malformed result). This is the
/// mechanism by which "investigate the last answer" feeds the todo-based
/// termination (§ 5.2): a REJECT records concrete open work that the loop must
/// clear before it can finish.
Future<String> _pushMissingPieceTodo(Object? verdict) async {
  final Object? added = await tool.invoke(
    'todo.add', <String, Object?>{'text': _missingPieceText(verdict)});
  if (added is! Map) return '';
  final result = added['result'];
  if (result is! Map) return '';
  final id = result['id'];
  return id is String ? id : '';
}

/// Renders the evaluator verdict as a todo title: strips the leading
/// ACCEPT/REJECT token (and any separator after it) so the todo reads as the
/// concrete missing piece, falling back to a generic title when the critique
/// gave no detail. Plain string ops only (no RegExp) to stay d4rt-safe.
String _missingPieceText(Object? verdict) {
  var detail = verdict is String ? verdict.trim() : '';
  final upper = detail.toUpperCase();
  // 'REJECT' and 'ACCEPT' are both 6 characters.
  if (upper.startsWith('REJECT') || upper.startsWith('ACCEPT')) {
    detail = detail.substring(6).trim();
  }
  while (detail.isNotEmpty &&
      (detail.startsWith(':') ||
          detail.startsWith('-') ||
          detail.startsWith('.'))) {
    detail = detail.substring(1).trim();
  }
  if (detail.isEmpty) {
    detail = 'address the self-critique on the last draft';
  }
  return 'Fix rejected draft: $detail';
}

/// Builds the `analyser`-role prompt (stage A). On a re-entry the prior
/// rejection context is folded in so the analysis targets what the critique
/// faulted.
String _analysisPrompt(Object? text, Map recall, String rejectionContext) {
  final context = _renderRecall(recall);
  return '${rejectionContext}Analyse what a complete, correct answer to the '
      'user prompt below must address. List the key sub-questions and the '
      'facts the answer depends on. Be concise.\n'
      '\n'
      '${context}User prompt:\n$text';
}

/// Builds the `sub_thinker`-role prompt (stage B reasoning half): work the
/// sub-questions the analysis surfaced.
String _subThinkPrompt(Object? text, Object? analysis) {
  return 'Reason through the sub-questions below to gather what the final '
      'answer needs. Think step by step; do not write the final answer yet.\n'
      '\n'
      'Analysis:\n$analysis\n'
      '\n'
      'User prompt:\n$text';
}

/// Builds the `assistant_to_user`-role synthesis prompt (stage C). Folds the
/// prior turns, the recalled memory, the analysis, the sub-reasoning, and (on a
/// re-entry) the rejection context into one composition instruction.
String _synthesisPrompt(
  Object? text,
  Map recall,
  Object? analysis,
  Object? subReasoning,
  Object? priorTurns,
  String rejectionContext,
) {
  final history = _renderPriorTurns(priorTurns);
  final context = _renderRecall(recall);
  return '$rejectionContext${history}Write the best possible answer to the '
      'user prompt, using your analysis and sub-reasoning and the recalled '
      'memory. Answer in plain prose.\n'
      '\n'
      'Analysis:\n$analysis\n'
      '\n'
      'Sub-reasoning:\n$subReasoning\n'
      '\n'
      '${context}User prompt:\n$text';
}

/// Builds the `evaluator`-role critique prompt (stage D). Asks for a verdict
/// the body can parse: a leading ACCEPT or REJECT.
String _critiquePrompt(Object? text, String draft) {
  return 'Critique the draft answer below against the user prompt. Decide '
      'whether it is complete and correct enough to send.\n'
      '\n'
      'Reply with ACCEPT or REJECT on the first line, then a one-line reason. '
      'Use REJECT if the draft is incomplete, wrong, or evasive.\n'
      '\n'
      'User prompt:\n$text\n'
      '\n'
      'Draft answer:\n$draft';
}

/// Renders the rejected draft + its critique as a re-entry preamble (stage E),
/// or `''` when there is no prior rejection (the first pass).
String _rejectionContext(String draft, Object? verdict) {
  return 'A previous attempt was rejected by self-critique. Address the '
      'critique; do not repeat the same mistakes.\n'
      'Previous draft:\n$draft\n'
      'Critique:\n$verdict\n'
      '\n';
}

/// Renders the recalled nodes' `text` values as a "Relevant recalled memory"
/// block, or `''` when the recall is empty (mirrors `answer_with_memory_v1`).
String _renderRecall(Map recall) {
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
  return context.isEmpty ? '' : 'Relevant recalled memory:\n$context\n';
}

/// Renders the prior conversation turns as `User:` / `Assistant:` lines, or
/// `''` when there are none (the § 22.4 history convention; mirrors
/// `answer_with_memory_v1`).
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

/// Collects the ids of the recalled nodes that fed the answer — the nodes the
/// Conclusion is `derived_from` (mirrors `answer_with_memory_v1`).
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
