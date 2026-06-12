/// @procedure
/// id: answer_with_thinking_v1
/// version: 1
/// summary: The recursive thinking branch — analyse, sub-reason, synthesise,
///   self-critique, and re-enter until every session todo is done and the
///   critique accepts (todo-based termination), then persist the exchange.
/// successCriterion: a deliberation-cued prompt is answered through the
///   recursive loop — the loop dispatches its analyse/sub-think sub-prompts via
///   `sub.run`, runs an `evaluator` critique each pass (the investigation of the
///   last answer), pushes the critique's missing pieces as session todos on
///   REJECT, and terminates only once every session todo is done AND the
///   critique accepts; an Event + Conclusion (+ derived_from edges to the cited
///   recalled nodes) are persisted on exit.
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
/// requires: [ runProcedure, run, embed, persist, edge, tool.invoke ]
//
// answer_with_thinking_v1 — the thinking branch of the entry router
// (`tom_brain_completion_plan.md` Todo 6, gaps G-T1 / G-T4 / C-2;
// `thinking_specification.md` § 4.1–4.7; `prompt_configuration.md` §9 /
// increment 7). It supersedes the `think_v1` no-op stub: the router's `thinking`
// verdict now reaches a real recursive loop.
//
// ── What increment 7 changed (the thinking-path restructure, §9) ─────────
//
// Before increment 7 each of the four deliberation stages built its own prompt
// with an inline string builder (`_analysisPrompt` / `_subThinkPrompt` /
// `_synthesisPrompt` / `_critiquePrompt`) and called `sub.llm(role:)` with the
// pre-assembled wire prompt. Increment 7 deletes every one of those builders and
// runs each stage through a **registered prompt** instead:
// `sub.run('assist_user.answer_with_thinking.<stage>', inputs:)`. The prompt's
// template + the injected `PromptResolver` own the assembly (`${recall}` /
// `${analysis}` / `${sub_reasoning}` / `${rejection_context}` / `${history}` /
// `${text}`); the engine renders `${tools.catalogue}` from the prompt's resolved
// tool set, and the shared `tool_loop_v1` script owns the inner tool loop (§7).
// The migration is total (principle 1 / PE-9): there is no inline fallback.
//
// The §9 restructure makes the synthesis stage an **ordinary tool-enabled
// prompt** — the "normal prompt" the thinking loop wraps. `synthesis` carries
// `tools: all` and the same `${tools.catalogue}` rendering as
// `answer_with_memory.assembly`, so the draft can recall/inspect through the
// real tool loop exactly as the normal branch does. The thinking procedure owns
// only the **outer** critique / re-entry loop; the inner send→parse→execute→
// re-send cycle lives in `tool_loop_v1` (§7.2).
//
// ── The recursive loop (§9 / § 4.1) ──────────────────────────────────────
//
// A single forward pass is a reflex, not a thought (the quest's core belief).
// One pass through the `while` is one deliberation iteration:
//
//   A  analyse    — `sub.run('…analysis' | '…analysis_reentry')` reads the
//                    prompt (and, on a re-entry, the accumulated rejection
//                    history) and states what the answer must address. The
//                    re-entry template is selected once `iteration > 0`.
//   B  sub-reason — `sub.run('…sub_think')` works the sub-questions the analysis
//                    surfaced. Memory recall (the other half of stage B, § 4.2)
//                    is dispatched *once* before the loop via the
//                    `retrieve_for_prompt_v1` conductor: the recalled context is
//                    stable across iterations; only the draft and the critique
//                    change, so re-recalling each pass would spend budget for an
//                    identical result.
//   C  synthesise — `sub.run('…synthesis' | '…synthesis_reentry')` drafts the
//                    answer from the recall + analysis + sub-reasoning (+ the
//                    accumulated rejection history on a re-entry). This is the
//                    tool-enabled "normal prompt"; the re-entry template folds in
//                    the increasing history and is selected once `iteration > 0`.
//   D  critique   — `sub.run('…critique')` judges the draft and returns a
//                    verdict; `_isAccept` parses ACCEPT vs REJECT. This critique
//                    IS the "investigate the last answer" gate (§ 3 / § 5.2):
//                    its verdict feeds the todo-based termination, and on REJECT
//                    its missing pieces become concrete session todos.
//   E  re-enter   — on REJECT the rejected draft + critique are **appended** to
//                    the accumulating `rejectionHistory` (the increasing history
//                    the re-entry templates fold in via `${rejection_context}`)
//                    AND pushed as a new session todo (`tool.invoke('todo.add')`)
//                    so there is tracked open work; on ACCEPT the loop marks the
//                    todos *it* pushed done (the accepted draft resolved them).
//                    The loop re-enters while any session todo is open or the
//                    critique rejected.
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
// (`mem.persist` / `mem.edge`), `substrate_bridge` (`sub.run` / `sub.embed`),
// `tool_bridge` (`tool.invoke` — the `todo.*` family the todo-based termination
// reads and writes; the engine binds the per-run `tool` global on every run),
// and `primitives_native` (the engine-native `runProcedure`). Every completion
// is a `sub.run` call that names a registered prompt whose role assembles
// persona + the assistant-dedication anchor at the substrate's assembly time —
// it can never hand the substrate a pre-assembled wire prompt (principle 5).
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/tool_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

/// The registered-prompt id prefix for the thinking stages (§5.1). Each stage
/// appends its `<prompt_name>` — `analysis` / `analysis_reentry` / `sub_think` /
/// `synthesis` / `synthesis_reentry` / `critique`.
const String _thinkingBase = 'assist_user.answer_with_thinking';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');
  final priorTurns = inputs.has('priorTurns') ? inputs.get('priorTurns') : null;
  final priorTurnsList = priorTurns is List ? priorTurns : const <Object?>[];

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
  // The increasing rejection history (§9): each REJECT appends the rejected
  // draft + its critique here, and the re-entry templates fold it in via
  // `${rejection_context}`. This is loop *data*, not a prompt builder — the
  // instructional prose lives in the `*_reentry` templates.
  var rejectionHistory = '';
  final pushedTodoIds = <String>[];
  var iteration = 0;
  var finished = false;

  // The exit condition is folded into the loop guard rather than using `break`:
  // the d4rt interpreter does not honour a `break` inside this async `while` (it
  // surfaces "Break statement outside of a loop"), so the loop runs while not
  // `finished`.
  while (!finished) {
    final reentry = iteration > 0;

    // Stage A — analyse the prompt. The re-entry template (selected once
    // `iteration > 0`) folds in the accumulated rejection history.
    final analysisId = reentry ? 'analysis_reentry' : 'analysis';
    final analysisCompletion = await sub.run(
      '$_thinkingBase.$analysisId',
      inputs: <String, Object?>{
        'text': text,
        'recall': recall,
        'priorTurns': List<Object?>.of(priorTurnsList),
        'rejection_context': rejectionHistory,
      },
    );
    final analysis = analysisCompletion['answer'];

    // Stage B (reasoning half) — work the sub-questions the analysis surfaced.
    final subCompletion = await sub.run(
      '$_thinkingBase.sub_think',
      inputs: <String, Object?>{'text': text, 'analysis': analysis},
    );
    final subReasoning = subCompletion['answer'];

    // Stage C — synthesise the draft answer. The synthesis prompt is the
    // tool-enabled "normal prompt" (§9): it carries `tools: all`, so the draft
    // runs through the shared tool loop exactly as the normal branch does. The
    // re-entry template folds in the increasing history.
    final synthesisId = reentry ? 'synthesis_reentry' : 'synthesis';
    final draftCompletion = await sub.run(
      '$_thinkingBase.$synthesisId',
      inputs: <String, Object?>{
        'text': text,
        'recall': recall,
        'priorTurns': List<Object?>.of(priorTurnsList),
        'rejection_context': rejectionHistory,
        'analysis': analysis,
        'sub_reasoning': subReasoning,
      },
    );
    final draftText = draftCompletion['answer'];
    if (draftText is String && draftText.isNotEmpty) {
      draft = draftText;
    }

    // Stage D — self-critique: the investigation of the last answer. Its verdict
    // drives accept/re-enter and feeds the todo-based termination.
    final critiqueCompletion = await sub.run(
      '$_thinkingBase.critique',
      inputs: <String, Object?>{'text': text, 'draft': draft},
    );
    final verdict = critiqueCompletion['answer'];
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
      // Stage E — re-entry: append the rejected draft + its critique to the
      // accumulating rejection history so the next pass's re-entry template
      // knows what to fix, AND push the critique's missing pieces as a concrete
      // session todo so termination cannot fire until that work is cleared. This
      // is how "investigate the last answer" feeds the todo-based termination
      // (§ 5.2).
      rejectionHistory = _appendRejection(
          rejectionHistory, iteration + 1, draft, verdict);
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
    iteration = iteration + 1;
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

/// Appends one rejected attempt (its [draft] and the evaluator [verdict]) to the
/// accumulating rejection [history] — the increasing history the `*_reentry`
/// templates fold in via `${rejection_context}` (§9). Pure data formatting (no
/// prompt instructions; those live in the templates), so the inline prompt
/// builders the migration deletes do not creep back in.
String _appendRejection(
    String history, int attempt, String draft, Object? verdict) {
  return '${history}Attempt $attempt:\nDraft:\n$draft\nCritique:\n$verdict\n\n';
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

/// Collects the ids of the recalled nodes that fed the answer — the nodes the
/// Conclusion is `derived_from` (mirrors `answer_with_memory_v1`).
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
