// SubstrateBridge — the d4rt-bridged re-export of the brain's substrate
// primitive set (Plan step C.13;
// `tom_brain_procedure_prototype_specification.md` § 5.1).
//
// This is a **plain Dart class** (no annotation — `@D4rtBridged` does
// not exist in the d4rt ecosystem; see Q-C.3.1 / C.3 / C.11 in
// `prototype_implementation_details.md`). `tom_d4rt_generator` selects
// it for bridging because `build.yaml` (C.11) lists this file under the
// `all` module's `barrelFiles`. The generated bridge registers through
// `BrainBridges.register(d4rt)` (C.14 / C.16). The generator-output
// round-trip smoke lands at C.15; this step (C.13) authors only the
// source class and its native unit tests.
//
// ── Why primitive-typed signatures (Q-C.3.3 / Q-C.12.1) ─────────────
//
// Every method accepts and returns d4rt-native primitives — `String`,
// `num`/`int`/`double`, `bool`, `List`, `Map<String, Object?>`. The
// bridge translates those primitives into the substrate domain types
// (`LlmCall`, `Budget`, `WebSearchOptions`, `WebFetchOptions`, …) on
// the way in and back into plain maps/lists on the way out. Keeping the
// bridged surface primitive means the generator never has to bridge the
// entire `tom_brain_substrate` domain-type graph. The typed result
// wrappers the spec mentions in § 5.3 (`LlmResult`, `SearchResult`,
// `FetchResult`, …) are layered in `lib/api/` later (C.38–C.41) and
// wrap these primitive returns; they are deliberately *not* the bridged
// shape.
//
// ── Anchor invariant (PE-7) ─────────────────────────────────────────
//
// Every prompt the machinery issues carries the assistant-dedication
// anchor because `llm(...)` is the *only* completion path and it always
// routes through the substrate client. The bridge has no raw-completion
// escape hatch: it cannot supply a pre-assembled wire prompt — it can
// only name a `role` and supply `inputs`, and the substrate prepends
// the anchor at assembly time (substrate invariant 1, B.46). The bridge
// therefore preserves PE-7 structurally, without re-checking it.
//
// ── Why `llm` drains `completeStream` (Q-C.13.1) ────────────────────
//
// `TomBrainSubstrateClient.complete` returns an `LlmCallReport` only —
// the report carries provenance/metrics but **not the generated text**
// (the text lives on the stream's `LlmStreamChunk` events). The
// prototype's `answer_with_memory_v1` needs the answer text (§ 5.1
// step "answer"), so `llm` drains `completeStream`, concatenates the
// chunk text, and returns `{ 'text': …, 'report': … }`. A
// `LlmStreamFailed` terminal event is surfaced as a thrown
// [LlmCompletionFailure] carrying the typed failure class.
//
// ── The streaming variant (P1.3 #7) ─────────────────────────────────
//
// Draining-to-concat is the *internal* path. For an external/user
// request the spec (§ 11 step 2) requires the tokens to stream end to
// end. So `llm` also forwards each chunk to an optional per-run
// [SubstrateTokenSink] (`onToken`) as it arrives. The sink is `null` on
// the template bridge and on internal / free-time runs (buffered, as
// before); the engine binds a per-run sink only for an external request.
// The concatenated buffer is *still* accumulated and returned either way
// — the procedure's persist step needs the whole answer text and the
// edge needs the buffer to preserve a correct late-failure HTTP status.
// Streaming is therefore additive: live deltas for the external path,
// the unchanged `{text, report}` return for every path. Threading the
// sink through the dispatcher and onto the OpenAI SSE edge is P1.3 #8–#9;
// this file owns only the substrate-side seam.
//
// ── Interface boundary (PE-10) ──────────────────────────────────────
//
// The bridge wraps a `TomBrainSubstrateClient` — the consumer-facing
// contract (B.40) — never the concrete `InProcessTomBrainSubstrate` and
// never `tom_brain_substrate/lib/src/` internals. The host injects
// whichever implementation the deployment topology chose; the bridge
// cannot tell the difference.

import 'dart:convert' show jsonDecode;

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, TurnContext;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show MapFieldReader;

import '../budget/budget_ledger.dart' show BudgetLedger;
import '../config/provider_config.dart' show ToolProtocol;
import 'bridge_call_recorder.dart';

/// Re-exposes the substrate primitive set to d4rt procedure scripts.
///
/// Mirrors the substrate rows of
/// `tom_brain_procedure_prototype_specification.md` § 5.1:
/// `llm(prompt, {role, budget})`, `embed(text)`,
/// `search(query, {provider, k})`, `fetch(url, {budget})`. Each method
/// delegates to the wrapped [TomBrainSubstrateClient] and converts
/// between d4rt primitives and the substrate domain types.
class SubstrateBridge {
  /// The interface-boundary substrate client every method delegates to
  /// (PE-10). Injected by the host (C.16).
  final TomBrainSubstrateClient client;

  /// Per-run recording hook (E.3.2). `null` on the shared template bridge
  /// the engine is constructed with; the engine binds a per-run instance to
  /// the active recorder so every effect call lands on that run's trail and
  /// folds into its effort tally. Not part of the d4rt-facing constructor
  /// surface — a procedure script only ever sees the injected instance.
  final BridgeCallRecorder? _onCall;

  /// Per-run token-streaming hook (P1.3 #7). `null` on the shared template
  /// bridge and on every internal / free-time run — those keep the buffered
  /// path. The engine binds a per-run sink only for an **external/user**
  /// request (the path the spec § 11 step 2 mandates streaming for); when a
  /// sink is bound, [llm] forwards each generated chunk to it as it arrives
  /// rather than only concatenating the answer at the end. Like [_onCall],
  /// per-run binding is what makes streaming concurrency-safe: two runs that
  /// share the same client each carry their own sink. Not part of the
  /// d4rt-facing surface — a procedure script never sees it. The sink's
  /// downstream wiring (a `deliver`/`emit` primitive threaded through the
  /// dispatcher to the OpenAI SSE edge) lands in P1.3 #8–#9; this hook is the
  /// substrate-side seam those steps thread into.
  final SubstrateTokenSink? _onToken;

  /// Per-run budget ledger (PE-8). `null` on the shared template bridge and
  /// whenever the run's header budget enforces no count/spend cap; the engine
  /// binds a per-run instance over the run's header budget otherwise. When
  /// wired, every primitive call is gated through [BudgetLedger.check] before
  /// its side effect and folded into the ledger's tally after. `llm` is
  /// governed by the `tokenSpend` cap — refused only once spend is already at
  /// or over the cap, since a completion's token cost is unknowable before it
  /// runs (`embed` / `search` / `fetch` are `toolCalls` and refused before
  /// the call when the count cap is reached).
  final BudgetLedger? _budget;

  /// Per-run note sink for the low-level tool-protocol seam (Extension F
  /// step 10). The substrate package is protocol-unaware, so the `json_text`
  /// fallback's malformed-tool-call diagnostic (`llm.toolcall.parse.failed`)
  /// has to be observed here rather than on the substrate. `null` on the
  /// shared template bridge and wherever the run does not bind a recorder —
  /// the note is then dropped on this low-level path (the `call_llm_v1` loop,
  /// step 11, is the consumer that turns it into a trail `note`). Symmetric to
  /// [_onCall] / [_onToken]: not part of the d4rt-facing surface.
  final SubstrateNoteSink? _onNote;

  /// Resolves a provider id to its wire tool protocol (Extension F step 2 /
  /// step 10). `null` ⇒ every provider is treated as [ToolProtocol.openai]
  /// (the default the prototype shipped before tool-calling), so existing
  /// callers and tests see no behaviour change. The host binds the real
  /// registry-backed resolver at boot wiring (plan step 15); this constructor
  /// hook is only the seam. Not part of the d4rt-facing surface — a procedure
  /// script never selects a protocol; the substrate hides it (Q-F.4).
  final ToolProtocolResolver? _toolProtocolOf;

  /// Per-run turn-correlation context (logging-spec §3 / §9 — the "→ substrate"
  /// end of the `turnId` thread-through). `null` on the shared template bridge
  /// and on every internal / free-time / dream run — those issue completions
  /// outside a user turn, so their [LlmCall]s carry no `turnId` / `callSeq`. The
  /// engine binds a per-run context built from the turn's id when the
  /// invocation supplies one; each [llm] completion then stamps the turn's
  /// `turnId` and the next per-turn `callSeq` onto the outbound [LlmCall]. Like
  /// [_onCall] / [_onToken], the binding is per-run so concurrent runs that
  /// share the client each carry their own turn; but unlike them the *counter*
  /// is shared across a turn's nested runs (one [TurnContext] per turn, threaded
  /// down), so `callSeq` spans sub-procedures. Not part of the d4rt-facing
  /// surface — a procedure script never sees it.
  final TurnContext? _turn;

  /// Wraps [client]. The host constructs this natively and registers the
  /// instance with the d4rt runtime. [onCall], when supplied, records each
  /// completed primitive call against the issuing run (E.3.2). [onToken], when
  /// supplied, receives each [llm] chunk's text delta live as it streams
  /// (P1.3 #7 — the external/user-request path). [budget], when supplied,
  /// enforces the run's procedure-header budget (PE-8). [onNote], when
  /// supplied, receives the low-level tool-protocol diagnostics
  /// (`llm.toolcall.parse.failed`); [toolProtocolOf], when supplied, selects a
  /// provider's wire tool protocol (defaulting to [ToolProtocol.openai]) —
  /// both Extension F step 10. [turn], when supplied, stamps the turn's
  /// `turnId` and an incrementing `callSeq` onto every [llm] call (logging-spec
  /// §3 / §9).
  SubstrateBridge(
    this.client, {
    BridgeCallRecorder? onCall,
    SubstrateTokenSink? onToken,
    BudgetLedger? budget,
    SubstrateNoteSink? onNote,
    ToolProtocolResolver? toolProtocolOf,
    TurnContext? turn,
  })  : _onCall = onCall,
        _onToken = onToken,
        _budget = budget,
        _onNote = onNote,
        _toolProtocolOf = toolProtocolOf,
        _turn = turn;

  /// Delegates to [body], gating it through the budget ledger and recording
  /// it on the run trail when those hooks are wired.
  ///
  /// [BudgetLedger.check] runs *before* [body], so a call that would exceed an
  /// applicable budget throws `ProcedureBudgetExceeded` and the side effect
  /// never happens. After [body] settles, the call is charged to the ledger
  /// and recorded (name [primitive], argument map [input], the flattened
  /// [resultOf] of the value, the measured wall-clock cost). With neither hook
  /// wired the call is a straight delegate. A throwing [body] (e.g.
  /// [LlmCompletionFailure]) — or a budget refusal — propagates without a
  /// recording: the engine records the crash / refusal on its own path.
  Future<T> _record<T>(
    String primitive,
    Map<String, Object?> input,
    Future<T> Function() body, {
    required Map<String, Object?> Function(T value) resultOf,
  }) async {
    final onCall = _onCall;
    final budget = _budget;
    if (onCall == null && budget == null) return body();
    budget?.check(primitive);
    final watch = Stopwatch()..start();
    final value = await body();
    watch.stop();
    final result = resultOf(value);
    budget?.charge(primitive, result: result);
    if (onCall != null) {
      await onCall(primitive, input, result,
          elapsedMs: watch.elapsedMilliseconds);
    }
    return value;
  }

  /// The role the prototype's user-facing answer step uses (§ 5.1
  /// step "answer"). The default for [llm] when the caller does not
  /// name a role.
  static const String defaultRole = 'assistant_to_user';

  /// The budget [llm] grants a call when the caller passes no `budget`
  /// map. Matches the procedure-header example in
  /// `tom_brain_procedure_prototype_specification.md` § 4 — generous
  /// enough that the single-shot prototype never trips it. The engine's
  /// procedure-level budget plumbing (C.19+) supersedes this; until
  /// then the bridge needs a concrete envelope to build an [LlmCall].
  /// (Q-C.13.2.)
  static Budget get defaultBudget => Budget(
        wallClockMs: 120000,
        tokenSpend: 40000,
        toolCalls: 30,
        memoryWrites: 6,
      );

  // ── llm ───────────────────────────────────────────────────────────

  /// Runs an LLM completion through the substrate and returns the
  /// generated text, any proposed tool calls, and the call report.
  ///
  /// [prompt] is supplied to the role template as the `prompt` input
  /// (Q-C.13.3); the bridge never supplies a raw wire prompt, so the
  /// substrate's anchor injection (PE-7) cannot be bypassed. [role]
  /// names the role-registry key and defaults to [defaultRole]. [budget]
  /// is an optional primitive map (`wallClockMs`, `tokenSpend`,
  /// `toolCalls`, `memoryWrites`); when omitted, [defaultBudget]
  /// applies.
  ///
  /// [tools] is an optional tool catalogue in the `tool.list` wire shape —
  /// a list of `{name, description?, input_schema?}` maps (Extension F
  /// step 10, § 21.1). When supplied, it rides onto [LlmOptions.toolCatalogue]
  /// so the role may propose tool calls. A malformed entry (missing `name`,
  /// non-map entry, wrong field types) surfaces a located [FormatException]
  /// (PE-1) — d4rt is an untrusted boundary.
  ///
  /// The returned `toolCalls` is uniform regardless of provider (Q-F.4): the
  /// substrate's wire protocol is hidden behind the resolved provider's
  /// [ToolProtocol] (selected by the injected [ToolProtocolResolver],
  /// defaulting to [ToolProtocol.openai]):
  ///
  ///   - [ToolProtocol.openai] — the provider emits native
  ///     [LlmStreamToolCallProposed] events; they are collected verbatim into
  ///     the uniform shape.
  ///   - [ToolProtocol.jsonText] — a non-tool-calling model emits a simple
  ///     JSON tool-call object (`{"tool": …, "arguments": {…}}`, optionally
  ///     markdown-fenced) in the completion text; it is parsed into the *same*
  ///     uniform shape. A completion that is plain prose yields an empty
  ///     `toolCalls`; a malformed JSON tool-call object yields an empty
  ///     `toolCalls` plus an `llm.toolcall.parse.failed` note, and the text
  ///     falls through as the no-tool answer.
  ///
  /// This is the *only* widening of the low-level surface; it adds no turn
  /// loop — that lives entirely in `call_llm_v1` (step 11).
  ///
  /// Returns `{'text': …, 'toolCalls': [{id, name, arguments}…], 'report':
  /// {...}}` — `text` is the concatenated answer, `toolCalls` is empty when
  /// none, and the report mirrors [LlmCallReport]. Throws
  /// [LlmCompletionFailure] when the
  /// stream terminates with [LlmStreamFailed].
  Future<Map<String, Object?>> llm(
    String prompt, {
    String role = defaultRole,
    List<Object?>? tools,
    Map<String, Object?>? budget,
  }) =>
      _record<Map<String, Object?>>(
        'llm',
        <String, Object?>{'prompt': prompt, 'role': role},
        () async {
          final catalogue = _buildToolCatalogue(tools);
          // Turn-correlation stamp (logging-spec §3 / §9): when a turn is bound,
          // name this completion with the turn's id and the next per-turn
          // `callSeq`. The counter advances once per llm call (embeddings do not
          // consume it) and spans the turn's nested runs because the one
          // [TurnContext] is shared down. Unbound (internal / dream) ⇒ both null.
          final turn = _turn;
          final call = LlmCall(
            roleId: role,
            inputs: <String, Object?>{'prompt': prompt},
            options: LlmOptions(toolCatalogue: catalogue),
            budget: _buildBudget(budget),
            turnId: turn?.turnId,
            callSeq: turn?.nextCallSeq(),
          );

          final buffer = StringBuffer();
          final nativeToolCalls = <Object?>[];
          final onToken = _onToken;
          String? providerId;

          await for (final event in client.completeStream(call)) {
            switch (event) {
              case LlmStreamChunk(:final text):
                buffer.write(text);
                // External/user-request path (P1.3 #7): forward each delta
                // live as it arrives. Awaited so the downstream sink (the SSE
                // edge, once wired) keeps ordering and backpressure. The
                // buffer is still accumulated — the returned `text` feeds the
                // procedure's persist step and preserves correct late-failure
                // HTTP status. With no sink bound the chunk is only buffered
                // (the internal / free-time path).
                if (onToken != null) await onToken(text);
              case LlmStreamToolCallProposed(
                  :final toolCallId,
                  :final toolName,
                  :final arguments,
                ):
                // Native (openai-protocol) tool call: collect into the uniform
                // shape. Under json_text the provider never emits these — the
                // tool call rides in the completion text instead.
                nativeToolCalls.add(<String, Object?>{
                  'id': toolCallId,
                  'name': toolName,
                  'arguments': arguments,
                });
              case LlmStreamStarted(providerId: final id):
                providerId = id;
              case LlmStreamCompleted(:final report):
                final protocol = _toolProtocolOf
                        ?.call(providerId ?? report.providerId) ??
                    ToolProtocol.openai;
                final toolCalls = await _resolveToolCalls(
                  protocol,
                  nativeToolCalls,
                  buffer.toString(),
                  catalogue,
                );
                return <String, Object?>{
                  'text': buffer.toString(),
                  'toolCalls': toolCalls,
                  'report': _reportToMap(report),
                };
              case LlmStreamFailed(:final failure, report: final failReport):
                throw LlmCompletionFailure(
                  classCode: failure.classCode,
                  message: failure.message,
                  report: _reportToMap(failReport),
                );
            }
          }

          // A well-behaved substrate always terminates with Completed or
          // Failed. Reaching here means the stream closed without a terminal
          // event — a substrate contract violation, surfaced loudly.
          throw StateError(
            'completeStream closed without a terminal '
            'LlmStreamCompleted/LlmStreamFailed event.',
          );
        },
        resultOf: (value) => value,
      );

  /// Resolves the uniform `toolCalls` list from whichever wire protocol the
  /// resolved provider speaks (Q-F.4).
  ///
  /// Under [ToolProtocol.openai] the substrate already surfaced native tool
  /// calls as [LlmStreamToolCallProposed] events, collected verbatim into
  /// [native]; this returns them unchanged. Under [ToolProtocol.jsonText] a
  /// non-tool-calling model embeds the tool call in [text]; it is parsed into
  /// the same `{id, name, arguments}` shape — but only when [catalogue] is
  /// non-empty (a completion with no tools on offer is never a tool call).
  Future<List<Object?>> _resolveToolCalls(
    ToolProtocol protocol,
    List<Object?> native,
    String text,
    ToolCatalogue catalogue,
  ) async {
    switch (protocol) {
      case ToolProtocol.openai:
        return native;
      case ToolProtocol.jsonText:
        if (catalogue.isEmpty) return const <Object?>[];
        return _parseJsonTextToolCalls(text);
    }
  }

  /// Parses a `json_text`-protocol completion into the uniform `toolCalls`
  /// shape, or surfaces the typed parse-failure note.
  ///
  /// The model is asked to answer with a bare `{"tool": …, "arguments": {…}}`
  /// object (optionally wrapped in a ```json fence) when it wants a tool;
  /// anything else is a plain prose answer. The heuristic: after de-fencing
  /// and trimming, text that does not start with `{` is prose ⇒ empty list, no
  /// note. Text that does start with `{` is *meant* to be a tool call, so a
  /// failure to read it as one (`jsonDecode` throws, the value is not a map,
  /// or it has no String `tool` key) is a malformed tool call ⇒ empty list
  /// plus an `llm.toolcall.parse.failed` note (the text still falls through as
  /// the no-tool answer).
  Future<List<Object?>> _parseJsonTextToolCalls(String text) async {
    final stripped = _stripJsonFence(text.trim());
    if (!stripped.startsWith('{')) {
      // Plain prose answer — not a tool call, not a malformation.
      return const <Object?>[];
    }

    Object? decoded;
    try {
      decoded = jsonDecode(stripped);
    } on FormatException {
      await _noteToolCallParseFailed(text);
      return const <Object?>[];
    }

    if (decoded is! Map) {
      await _noteToolCallParseFailed(text);
      return const <Object?>[];
    }
    final tool = decoded['tool'];
    if (tool is! String) {
      await _noteToolCallParseFailed(text);
      return const <Object?>[];
    }

    final rawArgs = decoded['arguments'];
    final arguments = <String, Object?>{};
    if (rawArgs is Map) {
      rawArgs.forEach((Object? key, Object? value) {
        arguments['$key'] = value;
      });
    }
    return <Object?>[
      <String, Object?>{'id': null, 'name': tool, 'arguments': arguments},
    ];
  }

  /// Emits the `llm.toolcall.parse.failed` note when a `json_text` completion
  /// looked like a tool call but could not be read as one. A no-op when no
  /// [SubstrateNoteSink] is bound (the low-level path's default).
  Future<void> _noteToolCallParseFailed(String text) async {
    await _onNote?.call(
      'llm.toolcall.parse.failed',
      <String, Object?>{'text': text},
    );
  }

  /// Strips a leading/trailing markdown code fence (```` ```json `` … `` ``` ````)
  /// from [text], returning the inner content trimmed. Text without a fence is
  /// returned unchanged.
  static String _stripJsonFence(String text) {
    if (!text.startsWith('```')) return text;
    var inner = text;
    final firstNewline = inner.indexOf('\n');
    if (firstNewline != -1) inner = inner.substring(firstNewline + 1);
    if (inner.endsWith('```')) inner = inner.substring(0, inner.length - 3);
    return inner.trim();
  }

  /// Builds a [ToolCatalogue] from the d4rt-supplied [tools] list (each entry
  /// a `{name, description?, input_schema?}` map in the `tool.list` wire
  /// shape). `null`/empty ⇒ [ToolCatalogue.empty]. A malformed entry surfaces
  /// a located [FormatException] via [_reader] (PE-1).
  static ToolCatalogue _buildToolCatalogue(List<Object?>? tools) {
    if (tools == null || tools.isEmpty) return ToolCatalogue.empty;
    final descriptors = <ToolDescriptor>[];
    for (var i = 0; i < tools.length; i++) {
      final map = _reader.mapValue(tools[i], 'tools[$i]')!;
      final name = _reader.requireString(map, 'name', 'tools[$i].name');
      final description =
          _reader.optionalString(map, 'description', 'tools[$i].description') ??
              '';
      final schema =
          _reader.optionalMap(map, 'input_schema', 'tools[$i].input_schema');
      descriptors.add(ToolDescriptor(
        name: name,
        description: description,
        parametersSchema:
            schema == null ? const <String, Object?>{} : _coerceStringKeys(schema),
      ));
    }
    return ToolCatalogue(descriptors);
  }

  /// Coerces a d4rt map with potentially `Object?` keys into the
  /// `Map<String, Object?>` [ToolDescriptor.parametersSchema] requires.
  /// A non-String key surfaces a located [FormatException] (PE-1).
  static Map<String, Object?> _coerceStringKeys(Map<Object?, Object?> raw) {
    final out = <String, Object?>{};
    raw.forEach((Object? key, Object? value) {
      out[_reader.stringValue(key, 'input_schema key')!] = value;
    });
    return out;
  }

  // ── retrievalRole ───────────────────────────────────────────────────

  /// Runs one Extension-H retrieval role (substrate § 6.2a) and returns its
  /// **deterministically parsed** output, degrading gracefully on a malformed
  /// model result rather than crashing (PE-6, hub § 23.9).
  ///
  /// [roleId] names one of the six retrieval roles (`recall_planner`,
  /// `hypothesis_writer`, `query_term_writer`, `category_selector`,
  /// `retrieval_reranker`, `profile_selector`); [prompt] is the role input.
  /// The role is asked to answer with a JSON object matching its schema; this
  /// method routes through [llm] (so the anchor and budget gate still apply),
  /// reads the completion text, `jsonDecode`s it, and lifts it into the role's
  /// typed shape via `parseRetrievalRoleOutput`.
  ///
  /// Returns a primitive map the conductor / `recall_*` procedures consume:
  ///
  ///   - on success: `{'ok': true, 'role': roleId, 'output': {...}}` — the
  ///     `output` map is the role-specific projection (see
  ///     [_retrievalOutputToMap]);
  ///   - on a malformed result (non-JSON text, or JSON that does not match the
  ///     role schema, or an unknown [roleId]): `{'ok': false, 'code':
  ///     'retrieval.role.output.malformed', 'reason': …}`.
  ///
  /// A genuine substrate failure (the completion stream fails) is **not**
  /// degraded here — it propagates as [LlmCompletionFailure] so the calling
  /// sub-procedure fails and the conductor drops its seeds (the PE-6 path lives
  /// at the conductor, not here). Only a *well-returned but unusable* result is
  /// the graceful-degrade case § 6.2a defines.
  Future<Map<String, Object?>> retrievalRole(
    String roleId,
    String prompt, {
    Map<String, Object?>? budget,
  }) async {
    final completion = await llm(prompt, role: roleId, budget: budget);
    final text = completion['text'];
    if (text is! String) {
      return _retrievalDegraded('role "$roleId" produced no text');
    }

    // Strip a markdown ```json … ``` fence before decoding — a live medium
    // model wraps structured output in one, and a fenced-but-well-formed JSON
    // answer is usable, not malformed. The tool-call path
    // (`_parseJsonTextToolCalls`) already de-fences with the same helper; both
    // structured-output readers in this bridge use one fence convention.
    final stripped = _stripJsonFence(text.trim());
    Object? decoded;
    try {
      decoded = jsonDecode(stripped);
    } on FormatException catch (e) {
      return _retrievalDegraded('role "$roleId" output is not JSON: ${e.message}');
    }
    if (decoded is! Map) {
      return _retrievalDegraded('role "$roleId" output is not a JSON object');
    }

    final json = <String, Object?>{};
    decoded.forEach((Object? key, Object? value) => json['$key'] = value);

    final parse = parseRetrievalRoleOutput(roleId, json);
    switch (parse) {
      case RetrievalRoleParsed(:final output):
        return <String, Object?>{
          'ok': true,
          'role': roleId,
          'output': _retrievalOutputToMap(output),
        };
      case RetrievalRoleDegraded(:final code, :final reason):
        return <String, Object?>{'ok': false, 'code': code, 'reason': reason};
    }
  }

  static Map<String, Object?> _retrievalDegraded(String reason) =>
      <String, Object?>{
        'ok': false,
        'code': retrievalRoleOutputMalformed,
        'reason': reason,
      };

  /// Projects a typed [RetrievalRoleOutput] into the primitive map a procedure
  /// reads. Exhaustive over the six § 6.2a output classes.
  static Map<String, Object?> _retrievalOutputToMap(RetrievalRoleOutput o) {
    switch (o) {
      case RecallPlannerOutput(:final questions):
        return <String, Object?>{'questions': questions};
      case HypothesisWriterOutput(:final answers):
        return <String, Object?>{'answers': answers};
      case QueryTermWriterOutput(:final query, :final synonyms):
        return <String, Object?>{'query': query, 'synonyms': synonyms};
      case CategorySelectorOutput(
          :final nodeTypes,
          :final edgeTypes,
          :final conceptNames,
        ):
        return <String, Object?>{
          'nodeTypes': nodeTypes,
          'edgeTypes': edgeTypes,
          'conceptNames': conceptNames,
        };
      case RetrievalRerankerOutput(:final ranking):
        return <String, Object?>{
          'ranking': ranking
              .map((c) => <String, Object?>{'id': c.id, 'score': c.score})
              .toList(),
        };
      case ProfileSelectorOutput(:final profile, :final confidence):
        return <String, Object?>{'profile': profile, 'confidence': confidence};
    }
  }

  // ── embed ─────────────────────────────────────────────────────────

  /// Embeds [text] and returns the vector plus the producing model's
  /// identity.
  ///
  /// Returns `{'vec': [<double>…], 'modelIdentity': {...}}`. The
  /// identity is memory's cosine-comparability commitment (§ 7.4); it
  /// rides into the persisted node so cross-model vectors are never
  /// mixed.
  Future<Map<String, Object?>> embed(String text) =>
      _record<Map<String, Object?>>(
        'embed',
        <String, Object?>{'text': text},
        () async {
          final result = await client.embed(text);
          return _embeddingToMap(result);
        },
        resultOf: (value) => value,
      );

  // ── search ────────────────────────────────────────────────────────

  /// Issues a web search and returns the hits.
  ///
  /// [provider] pins the search engine (`null` ⇒ substrate default);
  /// [k] caps the hit count (default 10, matching
  /// [WebSearchOptions.empty]). Returns
  /// `{'provider': …, 'query': …, 'hits': [{title, url, snippet, rank}]}`.
  Future<Map<String, Object?>> search(
    String query, {
    String? provider,
    int k = 10,
  }) =>
      _record<Map<String, Object?>>(
        'search',
        <String, Object?>{'query': query, 'provider': provider, 'k': k},
        () async {
          final result = await client.webSearch(
            query,
            options: WebSearchOptions(provider: provider, k: k),
          );
          return _searchToMap(result);
        },
        resultOf: (value) => value,
      );

  // ── fetch ─────────────────────────────────────────────────────────

  /// Fetches [url] with the configured budget + headers + UA.
  ///
  /// [budgetBytes] caps the read; a larger response returns with
  /// `truncated: true` rather than failing (§ 12). Returns
  /// `{'url', 'status', 'contentType', 'text'?, 'json'?, 'binaryMeta'?,
  /// 'truncated'}` — exactly one of `text` / `json` / `binaryMeta` is
  /// non-null per the resolved content type.
  Future<Map<String, Object?>> fetch(
    String url, {
    int? budgetBytes,
  }) =>
      _record<Map<String, Object?>>(
        'fetch',
        <String, Object?>{'url': url, 'budgetBytes': budgetBytes},
        () async {
          final result = await client.webFetch(
            Uri.parse(url),
            options: WebFetchOptions(budgetBytes: budgetBytes),
          );
          return _fetchToMap(result);
        },
        resultOf: (value) => value,
      );

  // ── primitive ⇄ domain conversions ────────────────────────────────

  /// Descriptive-`FormatException` reader for the d4rt-supplied budget map.
  /// d4rt scripts are an untrusted boundary (PE-1): a malformed budget field
  /// fails with a located error naming it, never an opaque `TypeError`.
  static const MapFieldReader _reader = MapFieldReader(FormatException.new);

  static Budget _buildBudget(Map<String, Object?>? raw) {
    if (raw == null) return defaultBudget;
    final fallback = defaultBudget;
    return Budget(
      wallClockMs:
          _reader.optionalNum(raw, 'wallClockMs', 'budget.wallClockMs')?.toInt() ??
              fallback.wallClockMs,
      tokenSpend:
          _reader.optionalNum(raw, 'tokenSpend', 'budget.tokenSpend')?.toInt() ??
              fallback.tokenSpend,
      toolCalls:
          _reader.optionalNum(raw, 'toolCalls', 'budget.toolCalls')?.toInt() ??
              fallback.toolCalls,
      memoryWrites:
          _reader.optionalNum(raw, 'memoryWrites', 'budget.memoryWrites')?.toInt() ??
              fallback.memoryWrites,
    );
  }

  static Map<String, Object?> _reportToMap(LlmCallReport report) =>
      <String, Object?>{
        'providerId': report.providerId,
        'modelId': report.modelId,
        'anchorHash': report.anchorHash,
        'promptHash': report.promptHash,
        'tokensIn': report.tokensIn,
        'tokensOut': report.tokensOut,
        'retries': report.retries,
        'wallClockMs': report.wallClockMs,
        if (report.cost != null) 'cost': report.cost,
        if (report.templateSha != null) 'templateSha': report.templateSha,
        'notes': List<String>.of(report.notes),
      };

  static Map<String, Object?> _embeddingToMap(EmbeddingResult result) =>
      <String, Object?>{
        'vec': result.vec.values.toList(),
        'modelIdentity': <String, Object?>{
          'providerId': result.modelIdentity.providerId,
          'modelId': result.modelIdentity.modelId,
          'dims': result.modelIdentity.dims,
          'normalized': result.modelIdentity.normalized,
        },
      };

  static Map<String, Object?> _searchToMap(WebSearchResult result) =>
      <String, Object?>{
        'provider': result.provider,
        'query': result.query,
        'hits': result.hits.map(_hitToMap).toList(),
      };

  static Map<String, Object?> _hitToMap(SearchHit hit) => <String, Object?>{
        'title': hit.title,
        'url': hit.url.toString(),
        'snippet': hit.snippet,
        'rank': hit.rank,
      };

  static Map<String, Object?> _fetchToMap(WebFetchResult result) =>
      <String, Object?>{
        'url': result.url.toString(),
        'status': result.status,
        'contentType': result.contentType,
        'truncated': result.truncated,
        if (result.text != null) 'text': result.text,
        if (result.json != null) 'json': result.json,
        if (result.binaryMeta != null)
          'binaryMeta': <String, Object?>{
            'contentType': result.binaryMeta!.contentType,
            if (result.binaryMeta!.contentLength != null)
              'contentLength': result.binaryMeta!.contentLength,
          },
      };
}

/// Receives each generated text delta from [SubstrateBridge.llm] as it
/// streams (P1.3 #7 — the end-to-end token-streaming seam).
///
/// The engine binds a per-run instance only for an **external/user** request;
/// internal secondary and free-time prompts leave it unbound and keep the
/// buffered path (spec § 11 step 2 — streaming is required for incoming
/// external requests, optional otherwise). [textDelta] is one substrate
/// [LlmStreamChunk]'s text, in arrival order. The future is awaited per chunk
/// so the downstream consumer (the OpenAI SSE edge, wired in #8–#9) preserves
/// ordering and backpressure.
typedef SubstrateTokenSink = Future<void> Function(String textDelta);

/// Receives a low-level tool-protocol diagnostic from [SubstrateBridge.llm]
/// (Extension F step 10).
///
/// The only category emitted today is `llm.toolcall.parse.failed` — a
/// `json_text` completion that looked like a tool call but could not be read
/// as one. The engine binds a per-run sink that folds the note onto the run's
/// trail (the `call_llm_v1` loop, step 11, is the consumer); the shared
/// template bridge and internal paths leave it unbound and the note is
/// dropped. [category] is the dotted note category; [payload] carries the
/// diagnostic detail (the offending completion text).
typedef SubstrateNoteSink = Future<void> Function(
  String category,
  Map<String, Object?> payload,
);

/// Resolves a provider id to the wire [ToolProtocol] it speaks (Extension F
/// step 2 / step 10).
///
/// The substrate package is protocol-unaware, so the bridge needs this seam to
/// know whether to collect native [LlmStreamToolCallProposed] events
/// ([ToolProtocol.openai]) or parse a JSON tool-call object out of the
/// completion text ([ToolProtocol.jsonText]). The host binds a registry-backed
/// resolver at boot wiring (plan step 15); an unbound resolver treats every
/// provider as [ToolProtocol.openai].
typedef ToolProtocolResolver = ToolProtocol Function(String providerId);

/// Thrown by [SubstrateBridge.llm] when the substrate stream terminates
/// with [LlmStreamFailed].
///
/// Carries the substrate failure taxonomy's [classCode] (kebab-case;
/// `rate_limit`, `timeout`, `auth`, `context_overflow`, …) so the
/// engine's fallback executor (C.46) can branch by class, plus the
/// best-effort [report] reflecting what was known at the point of
/// failure.
final class LlmCompletionFailure implements Exception {
  /// Stable kebab-case discriminator from `substrate_specification.md`
  /// § 5.4.
  final String classCode;

  /// Human-readable diagnostic. For logging / trail entries, not
  /// end-user display.
  final String message;

  /// Flattened best-effort [LlmCallReport] at the point of failure.
  final Map<String, Object?> report;

  LlmCompletionFailure({
    required this.classCode,
    required this.message,
    required this.report,
  });

  @override
  String toString() =>
      'LlmCompletionFailure(classCode: $classCode, message: $message)';
}
