/// @procedure
/// id: tool_loop_v1
/// version: 1
/// summary: The shared send→parse→execute→re-send tool-calling loop over one
///   already-assembled transcript and named LLM route.
/// successCriterion: The loop returns the model's final answer (or, on
///   exhaustion, the last completion) after running every proposed tool call
///   through `tool.invoke` and folding the results back into the transcript.
/// budget: { wallClockMs: 14400000 }
/// # Only a wall-clock deadline (§ 5.4): the *number* of iterations is bounded by
/// # the caller's `maxToolLoops` input, not a fatal count cap, so a genuinely
/// # long tool-using turn is never throttled — only a hung run is stopped.
/// inputs:
///   - { name: transcript, type: String, required: true }
///   - { name: route, type: String, required: true }
///   - { name: maxToolLoops, type: int, required: true }
///   - { name: role, type: String, required: false }
///   - { name: tools, type: List, required: false }
///   - { name: temperature, type: num, required: false }
/// outputs:
///   - { name: answer, type: String }
///   - { name: toolLoopExhausted, type: bool }
/// requires: [ send, tool.invoke ]
//
// tool_loop_v1 — the single, shared tool-calling loop
// (prompt_configuration.md § 7.2 / § 7.4, increment 5).
//
// ── Why the loop is its own procedure ───────────────────────────────
//
// Before increment 5 every answering procedure hand-wrote its own
// send→parse→execute→re-send `while` (see `answer_with_memory_v1`'s loop).
// That duplication is the seam this procedure closes: the loop is identical
// for every prompt — only the *settings* differ (which tools, which route,
// how many iterations, what temperature, the assembled initial transcript).
// `sub.run` resolves all of that on the Dart side and then delegates the loop
// here via the existing `runProcedure` primitive, so the agentic control flow
// stays inside procedure-land and is observable on the trail like any other
// run. Per-prompt variation is expressed purely through the inputs `run`
// passes; the loop body never branches on the prompt.
//
// ── The algorithm (§ 7.2) ───────────────────────────────────────────
//
//   1. `transcript = assembledPrompt` (the `transcript` input).
//   2. `completion = sub.send(transcript, llmRoute: route, role: role,
//      tools: tools, temperature: …)` — one completion over the *named* route
//      (`send`, not `llm`: the route is selected by name, while the role still
//      assembles persona + the assistant-dedication anchor, § 7.4).
//   3. Parse the completion for tool calls (the substrate bridge already lowers
//      the model's `call:NAME{…}` text into `completion['toolCalls']`). If there
//      are executable calls → `tool.invoke` each, append the tool-results block
//      to the transcript, loop. Else → return the answer.
//   4. Bounded by `maxToolLoops`; exhaustion returns the last completion with a
//      `toolLoopExhausted: true` flag.
//
// ── What stays with the *caller*, not here ──────────────────────────
//
// This loop owns only the mechanical send→execute→re-send cycle bounded by a
// count cap. The *outer* orchestration — todo-based termination
// (`answer_with_memory_v1`), thinking critique / re-entry
// (`answer_with_thinking_v1`) — stays in each calling procedure (§ 7.2). So
// the termination here is the simple one: a turn with no executable tool call
// (and no malformed tool-call attempt) is the answer.
//
// ── The `unresolvedToolCall` re-prompt (§ 9.1 hardening) ────────────
//
// A completion can *look* like a tool call yet resolve to zero executable
// calls — a tool name not on offer, or arguments that fail every parse. That
// raw `call:NAME{…}` text is the model failing to work, not an answer, so it
// must never leak as the final answer. On that signal the loop feeds an error
// turn back naming the available tools and re-enters (consuming one iteration,
// so it is still bounded by `maxToolLoops`) rather than returning the unusable
// text. This mirrors the hardening `answer_with_memory_v1` already carries.
//
// ── The returned answer ─────────────────────────────────────────────
//
// `answer` is always the *last completion's* text: on normal termination that
// is the model's plain answer; on exhaustion that is the last completion the
// loop saw (§ 7.2 — "exhaustion returns the last completion"). A tool-deciding
// turn's text (the `call:…` line) is *not* surfaced as the answer unless the
// loop exhausts on it — while the loop is still running, tool-deciding text is
// the model working, not answering.
//
// ── How the body reaches its inputs and the bridges ─────────────────
//
// Like every system procedure, the entry point receives a native
// `ProcedureInputs` and reaches the bridges by importing the library each is
// registered under: `procedure_inputs.dart` names the input bag,
// `substrate_bridge.dart` brings the `sub` global into scope (so `sub.send`
// resolves), and `tool_bridge.dart` brings the `tool` global into scope (so
// `tool.invoke` resolves). These are the only host surfaces the body touches;
// the static `SandboxValidator` allow-lists exactly these import URIs.
//
// The anchor invariant (PE-7 / principle 5) holds structurally: `sub.send`
// names a `role` and supplies the transcript as the role template's `prompt`
// *input* — it can never hand the substrate a pre-assembled wire prompt, so
// the assistant-dedication anchor is always prepended at the substrate's
// assembly time, exactly as for `sub.llm`. Only *route selection* moved off
// the role (§ 7.4).
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/tool_bridge.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final route = '${inputs.get('route')}';
  final role = inputs.has('role') ? '${inputs.get('role')}' : 'assistant_to_user';
  final tools = inputs.has('tools') ? inputs.get('tools') : null;
  final maxToolLoops = _asPositiveInt(inputs.get('maxToolLoops'));

  // `temperature` is forwarded only when supplied; a `num` from the input bag is
  // narrowed to the `double?` the bridge expects (a bare `int` like `0` arrives
  // as `int`, not `double`).
  double? temperature;
  if (inputs.has('temperature')) {
    final raw = inputs.get('temperature');
    if (raw is num) temperature = raw.toDouble();
  }

  var transcript = '${inputs.get('transcript')}';
  var lastText = '';
  var exhausted = false;
  // The loop is driven by a `done` flag rather than `break`: d4rt does not
  // support `break` inside a `while` (it raises "Break statement outside of a
  // loop"), so every exit sets `done` and the condition re-checks it.
  var done = false;
  var loops = 0;

  while (!done) {
    final completion = await sub.send(
      transcript,
      llmRoute: route,
      role: role,
      tools: tools is List ? tools : null,
      temperature: temperature,
    );
    loops += 1;

    final text = completion['text'];
    if (text is String) lastText = text;

    final toolCalls = completion['toolCalls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      // A tool-deciding turn. Stop here if this was the last allowed iteration —
      // running the tools without a follow-up completion to read them would be
      // wasted work, so exhaustion is declared *before* the calls run.
      if (loops >= maxToolLoops) {
        exhausted = true;
        done = true;
      } else {
        // The awaited call is hoisted into its own local before the assignment:
        // d4rt mis-scopes `x = f(x, await g())` (an `await` in the argument list
        // of a call whose result feeds back into `x`), so the awaited value must
        // settle into a local first.
        final toolResults = await _runToolCalls(toolCalls);
        transcript = _appendToolResults(transcript, toolResults);
      }
    } else if (completion['unresolvedToolCall'] == true) {
      // The completion looked like a tool call but resolved to zero executable
      // calls (§ 9.1). The raw `call:…` text is the model failing to work, not
      // an answer, so feed an error turn back and re-enter — bounded by the same
      // `maxToolLoops` cap.
      if (loops >= maxToolLoops) {
        exhausted = true;
        done = true;
      } else {
        transcript = _appendToolCallError(transcript, tools);
      }
    } else {
      // A plain-answer turn with no executable call: this is the final answer.
      done = true;
    }
  }

  return <String, Object?>{
    'answer': lastText,
    'toolLoopExhausted': exhausted,
  };
}

/// Narrows a `maxToolLoops` input to a positive int, defaulting to one when it
/// is missing, non-numeric, or non-positive — a loop must run at least once to
/// produce any completion to return.
int _asPositiveInt(Object? raw) {
  final value = raw is num ? raw.toInt() : 1;
  return value < 1 ? 1 : value;
}

/// Executes each proposed tool call through the live `tool.invoke` surface and
/// returns one record per call for folding back into the transcript.
///
/// `tool.invoke` returns its own `{ok: false, error}` for the pre-flight
/// failures (unknown tool, policy-denied, args fail the input schema), so those
/// never throw here. A tool that *throws while running* is caught and turned
/// into the same `{ok: false, error}` shape, so one failing tool never aborts
/// the whole loop — the model sees the error and can recover on the next turn.
///
/// Each `toolCalls` entry is `{id, name, arguments}` (the substrate bridge wire
/// shape); a non-map entry or one with a non-String `name` is skipped (PE-1: the
/// proposal came across an untrusted boundary).
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
/// result list leaves the transcript unchanged.
String _appendToolResults(String transcript, List results) {
  if (results.isEmpty) return transcript;
  var block = 'Tool results:\n';
  for (final record in results) {
    if (record is! Map) continue;
    block += '- ${record['name']}(${record['args']}) → ${record['outcome']}\n';
  }
  return '$transcript\n$block';
}

/// Folds an "invalid tool call" error turn into the transcript when a completion
/// looked like a tool-call attempt but resolved to zero executable calls
/// (§ 9.1). It names the offered tools so the model can correct itself — issue a
/// valid `call:NAME{…}` or just answer in plain prose — rather than the unusable
/// `call:…` text leaking as the answer. The names come from the same tool
/// descriptors `sub.run` offered the loop, so the listed names are exactly the
/// ones `tool.invoke` accepts.
String _appendToolCallError(String transcript, Object? tools) {
  final names = <String>[];
  if (tools is List) {
    for (final descriptor in tools) {
      if (descriptor is Map) {
        final name = descriptor['name'];
        if (name is String && name.isNotEmpty) names.add(name);
      }
    }
  }
  final available = names.isEmpty ? '(none)' : names.join(', ');
  return '$transcript\nThat was not a valid tool call: it named no available '
      'tool, or its arguments could not be read. Available tools: $available. '
      'Reply with a valid call (call:NAME{arg: value}) or a plain answer.\n';
}
