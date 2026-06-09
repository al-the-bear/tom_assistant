/// @procedure
/// id: prompt_analyzer_v1
/// version: 1
/// summary: Entry router — classify a user prompt as normal vs thinking and
///   select the branch procedure, without running it.
/// successCriterion: returns a branch decision (`branch` + `target`) for every
///   prompt — `normal` → answer_with_memory_v1, `thinking` →
///   answer_with_thinking_v1 — picking deterministically even when the
///   classification verdict is unparseable (defaults to `normal`).
/// budget: { wallClockMs: 60000 }
/// # One small classification LLM call (§ 4.0): a router decision is cheap and
/// # must not stall the request it gates. 60000 ms (60s) is a generous
/// # runaway-stop for a single `analyser` completion, not a throttle.
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: branch, type: String }
///   - { name: target, type: String }
///   - { name: verdict, type: String }
/// requires: [ llm ]
//
// prompt_analyzer_v1 — the thinking subsystem's entry router
// (`thinking_specification.md` § 4.0, G-T2; `tom_brain_completion_plan.md`
// Todo 5).
//
// § 4.0: "Not every prompt deserves the full recursive loop. prompt_analyzer_v1
// is the entry router: the procedure a user prompt reaches first. It makes a
// first classification LLM call (role: analyser) that decides between two
// branches" — normal (answer_with_memory_v1, the fast linear retrieve → answer
// → persist path) and thinking (answer_with_thinking_v1, the recursive loop).
//
// ── What this procedure does (and does NOT do) ──
//
// This body is the **classifier-and-branch-selector**: it reads the prompt,
// makes one `analyser`-role classification call, parses the verdict, and
// **returns** the chosen branch + target. It deliberately does **not**
// `runProcedure(...)` the chosen branch. Per the resolved route-flip
// (§ 4.0.1, option b): the native dispatcher consults this procedure for the
// decision (no token sink), reads its `target`, and itself launches that
// target **as the top-level streaming run** — within one foreground
// admission. A delegating router that invoked its branch via a nested
// `runProcedure` would break answer streaming, because the engine binds the
// per-run token sink **only to the top-level run** — a branch invoked under
// the router would stream nothing to the live caller. So this procedure stays
// a pure decision unit; the dispatcher owns the two-phase route.
//
// ── The two branch targets (§ 4.0.1) ──
//
// The `thinking` verdict maps to `answer_with_thinking_v1`, the real
// recursive loop (§ 4.1–4.7, Todo 6); it supersedes the `think_v1` no-op
// stub. The `normal` verdict maps to `answer_with_memory_v1`, the shipped
// fast path. Both branches are reachable only through this router's decision.
//
// ── How the verdict is decided (§ 4.0) ──
//
// The classification is one `analyser`-role completion. The prompt embeds the
// canonical deliberation cues as a **starting heuristic the LLM reasons over**,
// not a brittle keyword match: the analyser judges intent (a prompt that merely
// mentions "research" in passing is not necessarily a request to deliberate).
// The cues here are illustrative guidance for the model; the authoritative,
// domain-free cue *matcher* lives in `tom_core_agentic` (`classifyDeliberation
// Cue`) and is the deterministic tie-breaker the **native** router will wire in
// at Todo 6 — a d4rt body cannot import `tom_core_agentic`, so this procedure
// cannot call it. The model is asked to answer with exactly one verdict token.
//
// ── Determinism (gap-hunt § 5.5) ──
//
// The router must always pick a branch. `_branchFromCompletion` reads the
// verdict token out of the completion text (case-insensitive, first occurrence
// wins). When the completion names neither token — an unparseable or
// genuinely-ambiguous verdict — the body falls back to `normal`, the spec's
// default branch (§ 4.0: "An ordinary request. The default."). So an ambiguous
// prompt resolves the same way every time without a model-dependent coin-flip.
//
// ── Anchor (§ 4.0 / PE-7) ──
//
// The classification call is an `analyser`-role call whose `prompt` is supplied
// as the role-template *input* (never a pre-assembled wire prompt), so the
// assistant-dedication anchor is prepended at substrate assembly time. The
// router cannot issue an anchorless call; routing itself is performed in the
// user's service.
//
// ── Imports ──
//
// Only the two host-injected libraries this body touches: `procedure_inputs`
// (so `inputs.get('text')` dispatches onto the native bag) and `substrate_
// bridge` (so `sub.llm(...)` resolves). The SandboxValidator allow-lists
// exactly these and rejects every other import (PE-1).
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';

/// Branch decision tokens. Returned as the `branch` output and used to pick the
/// `target` procedure.
const String _branchNormal = 'normal';
const String _branchThinking = 'thinking';

/// The normal-branch target — the shipped fast retrieve → answer → persist
/// path.
const String _targetNormal = 'answer_with_memory_v1';

/// The thinking-branch target — the recursive deliberation loop
/// (§ 4.1–4.7, Todo 6). Supersedes the `think_v1` no-op stub.
const String _targetThinking = 'answer_with_thinking_v1';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');

  // One `analyser`-role classification call. The prompt is the role-template
  // input (anchor prepended at assembly), and asks for a single verdict token.
  final completion = await sub.llm(_classificationPrompt(text), role: 'analyser');
  final verdictText = completion['text'];

  final branch = _branchFromCompletion(verdictText is String ? verdictText : '');
  final target = branch == _branchThinking ? _targetThinking : _targetNormal;

  // The chosen branch is returned, not run here: the native dispatcher reads
  // `target` and launches it as the top-level streaming run (§ 4.0.1, b).
  return <String, Object?>{
    'branch': branch,
    'target': target,
    'verdict': branch,
  };
}

/// Builds the `analyser`-role classification prompt. The cues are a starting
/// heuristic the model reasons over (§ 4.0), not a strict keyword match. The
/// model is asked to answer with exactly one verdict token so the completion
/// parses deterministically.
String _classificationPrompt(Object? text) {
  return 'Route this user prompt to one of two processing branches.\n'
      '\n'
      '- NORMAL: an ordinary request, answered directly from memory.\n'
      '- THINKING: the user is asking you to deliberate before answering.\n'
      '\n'
      'Deliberation cues (a guide, not a strict keyword match): "think '
      'about", "ponder", "research", "reason about", "work through", '
      '"deliberate", "mull over", "reflect on", "figure out", "consider '
      'carefully". Judge intent — a prompt that merely mentions one of '
      'these words in passing is not necessarily a request to deliberate.\n'
      '\n'
      'Reply with EXACTLY one word and nothing else: THINKING or NORMAL.\n'
      '\n'
      'User prompt:\n'
      '$text';
}

/// Reads the branch out of the classification completion. Case-insensitive;
/// the first verdict token to appear wins (so a stray mention of the other
/// token later in a chatty completion does not flip the decision). When
/// neither token appears — an unparseable or ambiguous verdict — falls back to
/// `normal`, the spec's default branch (§ 4.0, determinism gap-hunt § 5.5).
String _branchFromCompletion(String completion) {
  final lower = completion.toLowerCase();
  final thinkingAt = lower.indexOf('thinking');
  final normalAt = lower.indexOf('normal');

  if (thinkingAt < 0 && normalAt < 0) return _branchNormal;
  if (thinkingAt < 0) return _branchNormal;
  if (normalAt < 0) return _branchThinking;
  return thinkingAt < normalAt ? _branchThinking : _branchNormal;
}
