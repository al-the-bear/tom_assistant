/// @procedure
/// id: answer_with_thinking_v1
/// version: 1
/// summary: The recursive thinking branch — analyse, sub-reason, synthesise,
///   self-critique, and re-enter until the critique accepts AND the model
///   confirms (presented its live todo list) that no work remains, then persist
///   the exchange.
/// successCriterion: a deliberation-cued prompt is answered through the
///   recursive loop — the loop dispatches its analyse/sub-think sub-prompts via
///   `sub.run`, runs an `evaluator` critique each pass (the investigation of the
///   last answer), re-enters directly on REJECT, and on ACCEPT asks the model —
///   in its normal `assistant_to_user` profile, presenting the live todo list —
///   whether it is `DONE` or wants to `CONTINUE`, terminating only on `DONE`; an
///   Event + Conclusion (+ derived_from edges to the cited recalled nodes) are
///   persisted on exit.
/// budget: { wallClockMs: 14400000 }
/// # Only a wall-clock deadline (§ 5.4): a foreground user prompt is virtually
/// # unlimited on every count dimension, exactly as `answer_with_memory_v1`.
/// # 14400000 ms (240 min) is the spec's external default — the **only**
/// # non-confirmation exit, a runaway-stop for a genuinely hung run, enforced
/// # externally by the engine (the body cannot read the clock; agent-loop
/// # completion plan § 3.3). Re-entry is bounded by the completion-confirmation
/// # contract, not a count cap: the loop re-enters while the critique rejects, or
/// # while an accepted draft's completion-confirmation says `CONTINUE`.
/// inputs:
///   - { name: text, type: String, required: true }
///   - { name: priorTurns, type: List, required: false }
/// outputs:
///   - { name: answer, type: String }
///   - { name: incomplete, type: bool }
/// requires: [ runProcedure, run, render, embed, persist, edge, tool.invoke ]
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
//                    so there is tracked open work; the loop then re-enters
//                    directly. On ACCEPT the loop marks the todos *it* pushed
//                    done (the accepted draft resolved them) and runs the
//                    completion-confirmation gate (below).
//
// ── Completion-confirmation termination + the never-silent contract (§ 3) ────
//
// There is **no iteration cap**. A REJECT always re-enters directly (the
// critique is the inner gate). On ACCEPT the loop runs the **completion
// confirmation** (§ 3.1 revision 2026-06-14): it asks the model — in its normal
// `assistant_to_user` profile, presenting the live todo list (the `todo_list`
// fragment, rendered through `sub.render` over the live `todo.list` result) —
// whether this is the final answer (`DONE`) or work still remains
// (`CONTINUE`). `_isFinished` reads the first word: `CONTINUE` re-enters (the
// draft + the are-you-done exchange join `history`), anything else (`DONE`, an
// empty or unparseable reply — the never-hang default) finishes. The
// confirmation turn streams to the **thinking** channel (§ 9.2), so its verdict
// is an out-of-band notice that never leaks into the answer. The single
// non-confirmation exit is the wall-clock runaway-stop (§ 3.3), enforced
// externally by the engine: the body cannot read the clock, so it loops purely
// on `!finished`.
//
// The body always exits with a critique-accepted, confirmed-complete answer, so
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

/// The DONE/CONTINUE completion-confirmation prompt the loop runs after an ACCEPT
/// (plan step 11). Registered under the thinking sub-procedure but sharing the
/// `answer_with_memory` template files, and `channel: thinking` (§ 9.2) so its
/// verdict never reaches the user.
const String _completionCheckPromptId =
    '$_thinkingBase.completion_check';

/// The `todo_list` fragment (plan step 11): `sub.render` turns the live
/// `todo.list` result into the `[x]`/`[ ]` checklist the completion check
/// presents.
const String _todoListPromptId = '$_thinkingBase.todo_list';

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

  // Termination (§ 3, revision 2026-06-14): no iteration cap. The self-critique
  // (stage D) is the inner gate — a REJECT always re-enters directly — and the
  // **completion-confirmation** is the final gate: once the critique accepts, the
  // loop asks the model, in its normal `assistant_to_user` profile and presenting
  // the live todo list, whether it is really done (`DONE`) or wants to continue
  // (`CONTINUE`). The ids of the todos this loop pushed (one per REJECT, holding
  // the critique's missing pieces) are tracked so an ACCEPT can mark exactly
  // those done before the confirmation sees the list — never any pre-existing
  // session todo the act stage owns.
  //
  // `history` accumulates the conversation across iterations — the dispatcher's
  // `priorTurns`, plus, on each `CONTINUE`, the draft and the are-you-done
  // exchange — and is folded into the stage templates via `priorTurns`.
  final history = <Object?>[];
  history.addAll(priorTurnsList);
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
        'priorTurns': List<Object?>.of(history),
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
        'priorTurns': List<Object?>.of(history),
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
      // exactly those done so the completion-confirmation sees a cleared list
      // for the work this loop tracked. (Any other open session todo, owned by
      // the act stage, still surfaces in the confirmation's todo list.) The
      // awaited update is hoisted into the loop body, not an argument position,
      // to stay clear of d4rt's `x = f(await g())` mis-scoping.
      for (final id in pushedTodoIds) {
        await tool.invoke(
            'todo.update', <String, Object?>{'id': id, 'done': true});
      }

      // Completion confirmation (§ 3.1 revision): the critique accepted the
      // draft, so ask the model — in its normal `assistant_to_user` profile and
      // presenting the live todo list — whether this is the final answer
      // (`DONE`) or work still remains (`CONTINUE`). The confirmation streams to
      // the thinking channel (§ 9.2), so its verdict never leaks into the
      // answer. On `CONTINUE` the accepted draft and the are-you-done exchange
      // join `history` and the loop re-enters; on `DONE` (the never-hang
      // default) it exits.
      // Both the live todo list and the confirmation question are registered
      // templates now (plan step 11), rendered through the no-LLM `sub.render`
      // seam; the DONE/CONTINUE turn itself runs via `sub.run` over the
      // `completion_check` prompt (registered `channel: thinking`).
      final todos = await _todoEntries();
      final todoList =
          await sub.render(_todoListPromptId, inputs: {'todos': todos});
      final question = await sub.render(_completionCheckPromptId,
          inputs: <String, Object?>{'text': text, 'todo_list': todoList});
      final completion = await sub.run(_completionCheckPromptId,
          inputs: <String, Object?>{'text': text, 'todo_list': todoList});
      final replyText = completion['answer'];
      final reply = replyText is String ? replyText : '';
      finished = _isFinished(reply);
      if (!finished) {
        history.add(<String, Object?>{'user': text, 'assistant': draft});
        history.add(<String, Object?>{'user': question, 'assistant': reply});
      }
    } else {
      // Stage E — re-entry: append the rejected draft + its critique to the
      // accumulating rejection history so the next pass's re-entry template
      // knows what to fix, AND push the critique's missing pieces as a concrete
      // session todo so the work is tracked. A rejected draft always re-enters
      // directly — the completion-confirmation gate runs only on an accepted
      // draft — so `finished` stays false (§ 5.2).
      rejectionHistory = _appendRejection(
          rejectionHistory, iteration + 1, draft, verdict);
      final pushedId = await _pushMissingPieceTodo(verdict);
      if (pushedId.isNotEmpty) {
        pushedTodoIds.add(pushedId);
      }
      finished = false;
    }

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

/// Reads the live session todo store as the raw `{id, text, done}` entry list,
/// the input the `todo_list` fragment renders into a checklist (plan step 11).
/// `tool.invoke('todo.list', {})` returns `{ok, result: {todos: […]}}`; a
/// malformed or absent listing yields the empty list, which the fragment renders
/// as the empty string.
//
// Keep in sync with answer_with_memory_v1.
Future<List<Object?>> _todoEntries() async {
  final Object? listed = await tool.invoke('todo.list', <String, Object?>{});
  if (listed is! Map) return const <Object?>[];
  final result = listed['result'];
  if (result is! Map) return const <Object?>[];
  final todos = result['todos'];
  return todos is List ? todos : const <Object?>[];
}

/// Whether the confirmation [reply] declares the work finished (§ 3.1 revision).
/// `CONTINUE` (as the first word, case-insensitive) keeps the loop running;
/// everything else — `DONE`, an empty reply, or any unparseable text — finishes
/// the loop. Defaulting ambiguity to finished is the never-hang guarantee: an
/// unclear confirmation never spins the loop forever (the wall-clock runaway-stop
/// is the only other exit, § 3.3).
//
// Keep in sync with answer_with_memory_v1.
bool _isFinished(String reply) {
  return !reply.trim().toUpperCase().startsWith('CONTINUE');
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
