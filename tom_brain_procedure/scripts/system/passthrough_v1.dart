/// @procedure
/// id: passthrough_v1
/// version: 1
/// summary: Memory-free relay — one substrate call carrying the user's text
///   through the active role, streamed back; no recall, no orchestration, no
///   persistence.
/// successCriterion: returns the upstream completion under `answer` after
///   exactly one `sub.run`, having touched no memory primitive.
/// budget: { wallClockMs: 14400000, toolCalls: 0, memoryWrites: 0 }
/// # A single relay call (§ 5.2): not no engine, but no memory and no
/// # orchestration (SC-3). The budget header expresses that structurally — the
/// # only count dimensions available are tool calls and memory writes, both
/// # pinned to 0 (the relay makes neither), so any tool call or memory write is
/// # a runaway-stop. There is no llmCalls dimension; "one LLM call" is enforced
/// # by the body itself issuing exactly one `sub.run`. wallClockMs is the
/// # spec's external default (§ 5.4) a profile `budget` may further tighten —
/// # the runaway-stop for a genuinely hung relay, not a throttle.
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: answer, type: String }
/// requires: [ run ]
//
// passthrough_v1 — the no-memory relay (`session_configuration.md` § 5.2;
// SC-3 / SC-5; plan step 7).
//
// § 5.2: "passthrough means no memory and no orchestration, not no engine."
// `mode: passthrough` selects this procedure. It is the thinnest possible
// system procedure: one `sub.run` carrying the user's text through the active
// role, the completion streamed straight back. It recalls nothing, persists
// nothing, runs no tool loop of its own, and re-enters nothing.
//
// ── The no-memory guarantee is structural (overview principle 7) ──
//
// This body imports ONLY the two host-injected libraries it touches —
// `procedure_inputs` (so `inputs.get('text')` dispatches onto the native bag)
// and `substrate_bridge` (so `sub.run(...)` resolves). It deliberately does
// **not** import `memory_bridge.dart`, so `mem` is never in scope and a
// `mem.*` call cannot be written. The d4rt `SandboxValidator` allow-lists
// exactly the imports a script declares (PE-1); the absent memory import is
// what makes "passthrough touches no memory" a property the sandbox *enforces*
// rather than a convention the body merely honours. The run is still a traced,
// budgeted, rate-limited `ProcedureRun` (SC-3) — the engine's recorder writes
// its own markers; this body writes none.
//
// ── The anchor invariant (PE-7 / principle 5) ──
//
// `sub.run` names a registered prompt whose role assembles persona + the
// assistant-dedication anchor at the substrate's assembly time — the body can
// never hand the substrate a pre-assembled wire prompt. The user's text is
// supplied as the role template's input, never as the wire prompt. Whether the
// anchor is actually concatenated is governed per-run by `Access.profile.
// anchored` (§ 3.4, plan step 9): a `passthrough` profile may set
// `anchored: false` for a non-assistant relay, but that toggle lives in the
// per-run substrate binding, not here — this body issues the same anchored-by-
// construction call every procedure does.
//
// ── Streaming (Q-D.38.1) ──
//
// Like the answer procedures, this body does not stream explicitly: the engine
// binds a per-run token sink to the substrate bridge's `onToken` (threaded from
// `Access.deliver`), so the relay's completion chunks forward to the live
// caller as they arrive. The body just returns the assembled `answer`.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';

/// The registered relay prompt (§ 5.2). Resolving it yields the active role +
/// LLM route + (empty) tool set and the template that carries the user `${text}`
/// straight through; `sub.run` assembles the wire prompt (anchor prepended per
/// the per-run binding) and returns the completion under `answer`.
const String _relayPromptId = 'assist_user.passthrough.relay';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');

  // The single relay call: the user's text through the active role. No recall
  // precedes it and no persist follows it — the body holds nothing to write.
  final completion = await sub.run(
    _relayPromptId,
    inputs: <String, Object?>{'text': text},
  );
  final answerText = completion['answer'];

  return <String, Object?>{
    'answer': answerText is String ? answerText : '',
  };
}
