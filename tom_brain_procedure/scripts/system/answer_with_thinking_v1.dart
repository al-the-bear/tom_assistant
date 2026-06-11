/// @procedure
/// id: answer_with_thinking_v1
/// version: 1
/// summary: The recursive thinking branch — analyse, sub-reason, synthesise,
///   self-critique, and re-enter on rejection within a bounded budget, then
///   persist the exchange.
/// successCriterion: a deliberation-cued prompt is answered through the
///   recursive loop — the loop dispatches its analyse/sub-think sub-prompts,
///   runs an `evaluator` critique each pass, re-enters on REJECT, and
///   terminates on the first ACCEPT or on budget exhaustion; on exhaustion the
///   best-effort (last) draft is returned with `incomplete = true` rather than
///   silence, and an Event + Conclusion (+ derived_from edges to the cited
///   recalled nodes) are persisted either way.
/// budget: { wallClockMs: 14400000 }
/// # Only a wall-clock deadline (§ 5.4): a foreground user prompt is virtually
/// # unlimited on every count dimension, exactly as `answer_with_memory_v1`.
/// # 14400000 ms (240 min) is the spec's external default — a runaway-stop for
/// # a genuinely hung run, not a throttle. The recursive re-entry is bounded
/// # separately by `maxIterations` (a caller override defaulting very high in the
/// # body, § 4.1), so the loop terminates long before the wall clock fires; the
/// # deadline is the orthogonal backstop for a single hung substrate call
/// # (gap-hunt § 6.5).
/// inputs:
///   - { name: text, type: String, required: true }
///   - { name: priorTurns, type: List, required: false }
///   - { name: maxIterations, type: int, required: false }
/// outputs:
///   - { name: answer, type: String }
///   - { name: incomplete, type: bool }
/// requires: [ runProcedure, embed, llm, persist, edge ]
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
// branch uses in a bounded analyse → sub-reason → synthesise → self-critique →
// re-enter loop. One pass through the `while` is one deliberation iteration:
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
//   D  critique   — `sub.llm(role: 'evaluator')` judges the draft and returns a
//                    verdict; `_isAccept` parses ACCEPT vs REJECT.
//   E  re-enter   — on REJECT the rejected draft + critique are carried forward
//                    as `rejectionContext` and the loop re-enters stage A; on
//                    ACCEPT the loop exits with the accepted draft.
//
// ── Bounded re-entry + the never-silent contract (§ 4.1, gap-hunt § 6.5) ─
//
// The loop runs at most `maxIterations` passes — a caller override defaulting
// very high (effectively unlimited) so a real prompt is never artificially
// cut short; a caller (or test) may pass a small `maxIterations` to bound it.
// The bound is resolved inline here, not an import: a d4rt body cannot import
// `tom_core_agentic`, so the
// domain-free re-entry/budget vocabulary lives there for the *native* callers
// while the loop itself enforces the cap inline. Termination is one of two:
//
//   • ACCEPT — the loop exits the moment a critique accepts; `incomplete` is
//     false and the accepted draft is the answer.
//   • exhaustion — every pass rejected. The loop stops at the cap and returns
//     the *last* (most-informed) draft as the best-effort answer with
//     `incomplete = true`. A foreground prompt is therefore NEVER answered with
//     silence (gap-hunt § 6.5): the `incomplete` flag tells the consumer (and
//     the dreaming process) the question is still open, but an answer is always
//     produced. The wall-clock budget is the orthogonal backstop for a single
//     hung substrate call; the iteration cap is what bounds the deliberation.
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
// and `primitives_native` (the engine-native `runProcedure`). There is no
// `tool_bridge` import: the synthesis stage forbids tools. Every completion is
// an `sub.llm` call that names a `role` and supplies the prompt as the role
// template's *input* — never a pre-assembled wire prompt — so the
// assistant-dedication anchor is always prepended at substrate assembly time.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/api/procedure_result.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
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

  // Bounded re-entry (§ 4.1): a caller-overridable deliberation cap. The default
  // is set very high so a foreground prompt is effectively unbounded on the
  // re-entry count (only the wall-clock deadline backstops a genuinely hung
  // run); a caller (or test) may pass `maxIterations` to bound it. A d4rt body
  // cannot import the domain-free `tom_core_agentic` re-entry vocabulary, so the
  // loop enforces the cap inline.
  final maxArg = inputs.getOrNull('maxIterations');
  final maxIterations = maxArg is int ? maxArg : 800;
  var iteration = 0;
  var accepted = false;
  var draft = '';
  var rejectionContext = '';

  // The exit condition folds the accept test into the loop guard rather than
  // using `break`: the d4rt interpreter does not honour a `break` inside this
  // async `while` (it surfaces "Break statement outside of a loop"), so the
  // loop runs while there is budget left AND no draft has been accepted.
  while (iteration < maxIterations && !accepted) {
    iteration++;

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

    // Stage D — self-critique. The verdict drives accept/re-enter.
    final critiqueCompletion = await sub.llm(
      _critiquePrompt(text, draft),
      role: 'evaluator',
    );
    final verdict = critiqueCompletion['text'];

    if (_isAccept(verdict)) {
      // Accepted: the loop guard (`!accepted`) exits before the next pass.
      accepted = true;
    } else {
      // Stage E — re-entry: carry the rejected draft + its critique forward so
      // the next analysis knows what to fix.
      rejectionContext = _rejectionContext(draft, verdict);
    }
  }

  // Best-effort termination: the accepted draft, or (on exhaustion) the last,
  // most-informed draft. Never silence (gap-hunt § 6.5).
  final answer = draft;
  final incomplete = !accepted;

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
      'rationale': incomplete
          ? 'Best-effort answer; the recursive loop exhausted its re-entry '
              'budget without the evaluator accepting (incomplete).'
          : 'Answered through the recursive thinking loop.',
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
  return '${rejectionContext}${history}Write the best possible answer to the '
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
