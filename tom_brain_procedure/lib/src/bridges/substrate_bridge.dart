// SubstrateBridge — the d4rt-bridged re-export of the brain's substrate
// primitive set (Plan step C.13;
// `tom_brain_procedure_specification.md` § 5.1).
//
// This is a **plain Dart class** (no annotation — `@D4rtBridged` does
// not exist in the d4rt ecosystem; see Q-C.3.1 / C.3 / C.11 in
// `prototype_implementation_details.md`). `tom_d4rt_generator` selects
// it for bridging because `buildkit.yaml` (C.11) lists this file under the
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
// anchor because the shared `_completeOnce` core is the *only* completion
// path and it always routes through the substrate client (`send` and the
// internal retrieval-role completion both feed it). The bridge has no
// raw-completion
// escape hatch: it cannot supply a pre-assembled wire prompt — it can
// only name a `role` and supply `inputs`, and the substrate prepends
// the anchor at assembly time (substrate invariant 1, B.46). The bridge
// therefore preserves PE-7 structurally, without re-checking it.
//
// ── Why `llm` drains `completeStream` (Q-C.13.1) ────────────────────
//
// `TomBrainSubstrateClient.complete` returns an `LlmCallReport` only —
// the report carries provenance/metrics but **not the generated text**
// (the text lives on the stream's `LlmTextDelta` events). The
// prototype's `answer_with_memory_v1` needs the answer text (§ 5.1
// step "answer"), so `llm` drains `completeStream`, concatenates the
// chunk text, and returns `{ 'text': …, 'report': … }`. A
// `LlmRunFailed` terminal event is surfaced as a thrown
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

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Budget, TurnContext;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, looksLikeToolCallAttempt, parseToolCallsFromText;

import '../api/procedure_inputs.dart' show ProcedureInputs;
import '../api/procedure_result.dart' show ProcedureResult;
import '../budget/budget_ledger.dart' show BudgetLedger;
import '../config/tool_protocol.dart' show ToolProtocol;
import 'bridge_call_recorder.dart';
import 'llm_call_observation.dart';
// The `sub.run` host-side seam value types (`ResolvedPrompt`,
// `UnregisteredPromptException`). Defined outside this barrelFile so the d4rt
// bridge generator does not bridge them (principle 7) — see that file's header.
import 'substrate_run_seams.dart';

/// Re-exposes the substrate primitive set to d4rt procedure scripts.
///
/// Mirrors the substrate rows of
/// `tom_brain_procedure_specification.md` § 5.1:
/// `send(transcript, {llmRoute, role})`, `run(promptId, {inputs})`,
/// `embed(text)`, `search(query, {provider, k})`, `fetch(url, {budget})`.
/// `send` and `run` are the only substrate completion entry points — the
/// low-level `llm` method was retired (prompt_configuration.md Phase 5,
/// step 12): every completion now routes by an explicit named route
/// (`send`) or a registered prompt id (`run`). Each method delegates to the
/// wrapped [TomBrainSubstrateClient] and converts between d4rt primitives
/// and the substrate domain types.
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
  /// sink is bound, [send] forwards each generated chunk to it as it arrives
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

  /// Per-run **thinking** channel sink (`agent_loop_completion.md` § 9.2 Todo
  /// 6). `null` on the shared template bridge and on internal / free-time runs.
  /// Distinct from [_onToken] (the **answer** channel the user reads): the
  /// thinking sink carries text the run produced *while working* — a
  /// tool-deciding turn's `call:NAME{…}` text, or the whole completion of a
  /// non-answer role — so that working text never folds into the streamed
  /// answer. Fire-and-forget (one notice per turn, not per token): a thinking
  /// notice carries no answer text, so it neither paces nor blocks the body.
  /// The engine binds it on the top-level external run only; the dispatch route
  /// delivers each notice beside the answer as an out-of-band [OutboundChunk].
  final SubstrateThinkingSink? _onThinking;

  /// Resolves a provider id to its wire tool protocol (Extension F step 2 /
  /// step 10). `null` ⇒ every provider is treated as [ToolProtocol.openai]
  /// (the default the prototype shipped before tool-calling), so existing
  /// callers and tests see no behaviour change. The host binds the real
  /// registry-backed resolver at boot wiring (plan step 15); this constructor
  /// hook is only the seam. Not part of the d4rt-facing surface — a procedure
  /// script never selects a protocol; the substrate hides it (Q-F.4).
  final ToolProtocolResolver? _toolProtocolOf;

  /// Resolves an LLM route *name* to the `List<RouteEntry>` chain [send]
  /// dispatches over (§7.4 / §8). `null` ⇒ [send] cannot route and throws a
  /// [StateError]; [send] is unaffected (it routes by role). The host binds a
  /// resolver backed by the cognition config's `llm:` route table at boot
  /// wiring (increment 5 step 5d); this constructor hook is only the seam, the
  /// `ToolProtocolResolver` pattern applied to route selection. Not part of the
  /// d4rt-facing surface — a procedure script names a route, never a chain.
  final RouteChainResolver? _routeChainOf;

  /// Resolves a registered prompt *id* to its inherited settings + loaded,
  /// placeholder-resolved template body (§7.4 / §7.1). `null` ⇒ [run] cannot
  /// resolve a prompt and throws a [StateError]; [send] is unaffected
  /// (they take an already-assembled transcript, not an id). The host binds a
  /// resolver backed by the cognition config's prompt registry at boot wiring
  /// (increment 5 step 5d); this constructor hook is only the seam, the
  /// `RouteChainResolver` pattern applied to prompt resolution. Not part of the
  /// d4rt-facing surface — a procedure script names a prompt id, never resolves
  /// it itself.
  final PromptResolver? _promptResolver;

  /// Runs another procedure by id, for [run] to delegate the send→parse→
  /// execute→re-send loop to the shared `tool_loop_v1` d4rt script (§7.2 /
  /// §7.4). `null` ⇒ [run] cannot delegate and throws a [StateError]. The
  /// engine binds it per run over that run's depth-capped `RunProcedurePrimitive`
  /// (so the nested loop run gets the right depth bookkeeping and its own trail),
  /// exactly as the `runProcedure` native primitive does for a scripted nested
  /// call. Not part of the d4rt-facing surface — a procedure script reaches
  /// nested procedures through the native `runProcedure`, never through the
  /// substrate bridge.
  final ProcedureRunner? _runProcedure;

  /// The per-run profile role (`session_configuration.md` § 3.3; plan step 8
  /// (a)). `null` on the shared template bridge and whenever the run's profile
  /// pins no role; the engine binds it per run from `Access.profile.role`. It is
  /// a **fallback**, not an override: [run] uses it as the call's role *only
  /// when the resolved prompt names none* (an empty [ResolvedPrompt.role]) — a
  /// prompt that declares its own role keeps it (the spec's "profile role used
  /// when the procedure names none"). Not part of the d4rt-facing surface — a
  /// procedure script never sees it.
  final String? _profileRole;

  /// The per-run anchoring toggle (`session_configuration.md` § 3.4; plan
  /// step 9). `true` (the default and the shared template bridge) ⇒ every
  /// [LlmCall] this bridge issues carries the assistant-dedication anchor — the
  /// Postulate-3 path. `false` ⇒ the run's profile opted out (the passthrough
  /// relay), so each outbound call is stamped `anchored: false` and the substrate
  /// omits the anchor. The engine binds it per run from `Access.profile.anchored`.
  /// Not part of the d4rt-facing surface — a procedure script never sees it (the
  /// anchor is a profile/safety concern, never a script one).
  final bool _anchored;

  /// Per-run turn-correlation context (logging-spec §3 / §9 — the "→ substrate"
  /// end of the `turnId` thread-through). `null` on the shared template bridge
  /// and on every internal / free-time / dream run — those issue completions
  /// outside a user turn, so their [LlmCall]s carry no `turnId` / `callSeq`. The
  /// engine binds a per-run context built from the turn's id when the
  /// invocation supplies one; each [send] completion then stamps the turn's
  /// `turnId` and the next per-turn `callSeq` onto the outbound [LlmCall]. Like
  /// [_onCall] / [_onToken], the binding is per-run so concurrent runs that
  /// share the client each carry their own turn; but unlike them the *counter*
  /// is shared across a turn's nested runs (one [TurnContext] per turn, threaded
  /// down), so `callSeq` spans sub-procedures. Not part of the d4rt-facing
  /// surface — a procedure script never sees it.
  final TurnContext? _turn;

  /// Per-run raw-LLM-trail observer (`tom_brain_logging.md` §5.2 / §10 step
  /// #4). `null` on the shared template bridge and on every run that does not
  /// bind a trail writer; the engine binds a per-run observer that wraps each
  /// [LlmCallObservation] with run-correlation and hands it to the run's
  /// `LlmTrailSink`. Fired once per completed `llm` call, *after* the answer is
  /// assembled, with the captured wire body the provider saw — the only seam
  /// where wire + answer + report coexist. Kept distinct from [_onCall] so the
  /// wire scaffold never lands in the d4rt-facing result map (PE-1). Best-effort
  /// and non-blocking (logging-spec §9): a throwing observer is swallowed so it
  /// cannot break the completion. Not part of the d4rt-facing surface.
  final LlmTrailObserver? _onLlmTrail;

  /// Wraps [client]. The host constructs this natively and registers the
  /// instance with the d4rt runtime. [onCall], when supplied, records each
  /// completed primitive call against the issuing run (E.3.2). [onToken], when
  /// supplied, receives each [send] chunk's text delta live as it streams
  /// (P1.3 #7 — the external/user-request path). [budget], when supplied,
  /// enforces the run's procedure-header budget (PE-8). [onNote], when
  /// supplied, receives the low-level tool-protocol diagnostics
  /// (`llm.toolcall.parse.failed`); [toolProtocolOf], when supplied, selects a
  /// provider's wire tool protocol (defaulting to [ToolProtocol.openai]) —
  /// both Extension F step 10. [routeChainOf], when supplied, resolves an LLM
  /// route name to the chain [send] dispatches over (§7.4); without it [send]
  /// throws and [send] is unaffected. [turn], when supplied, stamps the turn's
  /// `turnId` and an incrementing `callSeq` onto every [send] call (logging-spec
  /// §3 / §9). [onLlmTrail], when supplied, receives one [LlmCallObservation]
  /// per completed [send] call (wire body + answer + report) so a downstream
  /// raw-LLM-trail writer can serialise the §5.2 `llm/<role>/…raw.json` file
  /// (logging-spec §10 step #4). [profileRole], when supplied, is the run's
  /// profile-pinned role (§ 3.3): [run] uses it as the call's role *only when
  /// the resolved prompt names none* (an empty role) — a fallback, never an
  /// override. [anchored] (default `true`) is the run's profile anchoring toggle
  /// (§ 3.4): when `false`, every [LlmCall] this bridge issues is stamped
  /// `anchored: false` so the substrate omits the dedication anchor.
  SubstrateBridge(
    this.client, {
    BridgeCallRecorder? onCall,
    SubstrateTokenSink? onToken,
    BudgetLedger? budget,
    SubstrateNoteSink? onNote,
    SubstrateThinkingSink? onThinking,
    ToolProtocolResolver? toolProtocolOf,
    RouteChainResolver? routeChainOf,
    PromptResolver? promptResolver,
    ProcedureRunner? runProcedure,
    String? profileRole,
    bool anchored = true,
    TurnContext? turn,
    LlmTrailObserver? onLlmTrail,
  }) : _onCall = onCall,
       _onToken = onToken,
       _budget = budget,
       _onNote = onNote,
       _onThinking = onThinking,
       _toolProtocolOf = toolProtocolOf,
       _routeChainOf = routeChainOf,
       _promptResolver = promptResolver,
       _runProcedure = runProcedure,
       _profileRole = profileRole,
       _anchored = anchored,
       _turn = turn,
       _onLlmTrail = onLlmTrail;

  /// The injected route-chain resolver this bridge was built with, or `null`.
  ///
  /// The engine rebuilds a fresh [SubstrateBridge] per run (binding that run's
  /// recorder / token sink / budget / turn), and reads this off the template
  /// bridge to carry the §7.4 routing seam onto the per-run bridge — without it
  /// every per-run [send] would throw "no RouteChainResolver bound". Returns the
  /// raw resolver closure; it is a host-side wiring detail, never called from a
  /// procedure script (a script names a route, never a chain).
  RouteChainResolver? get routeChainOf => _routeChainOf;

  /// The injected prompt resolver this bridge was built with, or `null`.
  ///
  /// Read off the template bridge by the engine when it rebuilds a fresh
  /// [SubstrateBridge] per run, so [run]'s id→settings resolution seam is
  /// carried onto the per-run bridge (mirrors [routeChainOf]). A host-side
  /// wiring detail, never called from a procedure script.
  PromptResolver? get promptResolver => _promptResolver;

  /// The injected nested-procedure runner this bridge was built with, or
  /// `null`.
  ///
  /// The engine binds a *fresh* runner per run (over that run's depth-capped
  /// `RunProcedurePrimitive`), so unlike [routeChainOf] / [promptResolver] this
  /// is not carried from the template bridge — it is rebound each run. The
  /// getter exists for symmetry and test introspection. A host-side wiring
  /// detail, never called from a procedure script.
  ProcedureRunner? get procedureRunner => _runProcedure;

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
      await onCall(
        primitive,
        input,
        result,
        elapsedMs: watch.elapsedMilliseconds,
      );
    }
    return value;
  }

  /// The role the prototype's user-facing answer step uses (§ 5.1
  /// step "answer"). The default for [send] when the caller does not
  /// name a role.
  static const String defaultRole = 'assistant_to_user';

  /// The budget [send] grants a call when the caller passes no `budget`
  /// map. Matches the procedure-header example in
  /// `tom_brain_procedure_specification.md` § 4 — generous
  /// enough that the single-shot prototype never trips it. The engine's
  /// procedure-level budget plumbing (C.19+) supersedes this; until
  /// then the bridge needs a concrete envelope to build an [LlmCall].
  /// (Q-C.13.2.)
  static Budget get defaultBudget => Budget(
    wallClockMs: 86400000,
    tokenSpend: 100000000,
    toolCalls: 800,
    memoryWrites: 1000000,
  );

  // ── send ──────────────────────────────────────────────────────────

  /// Runs one completion over an **explicitly named LLM route** (§7.4) and
  /// returns `{text, toolCalls, unresolvedToolCall, report}` — the uniform
  /// completion shape every substrate entry point yields.
  ///
  /// `send` is the low-level completion entry of the prompt-configuration
  /// routing seam: the `llm:` setting selects an LLM route by *name* (§8), and
  /// `send` dispatches over that route's resolved chain. [llmRoute] is resolved
  /// to a `List<RouteEntry>` by the injected [RouteChainResolver]
  /// ([_routeChainOf]); the resolved chain rides onto [LlmCall.routeChain] so
  /// the substrate routes over it (substrate §7.4 seam). The [role] still
  /// assembles the wire prompt — persona + anchor + provenance — so route
  /// selection is the only thing decoupled from the role and the anchor
  /// invariant (PE-7) is preserved unchanged.
  ///
  /// [transcript] is the prompt body (the role template's `prompt` input).
  /// [tools] is the optional tool catalogue in the `tool.list` wire shape — a
  /// list of `{name, description?, input_schema?}` maps (§ 21.1); a malformed
  /// entry surfaces a located [FormatException] (PE-1). [temperature] /
  /// [maxOutputTokens] / [responseFormat] ride onto [LlmOptions] — `send` is
  /// where a procedure pins decoding knobs a role answer would otherwise leave
  /// at provider/role defaults. [channel] forces the stream channel (§9.2):
  /// `null` defaults by [role] (a deliberation role streams to `thinking`,
  /// every other role to `answer`), `'thinking'` routes the completion to the
  /// out-of-band channel so it never reaches the user-visible answer (the lever
  /// `sub.run` threads from a prompt's `channel:` setting).
  ///
  /// The returned `toolCalls` is uniform regardless of provider (Q-F.4): the
  /// substrate's wire protocol is hidden behind the resolved provider's
  /// [ToolProtocol] (selected by the injected [ToolProtocolResolver],
  /// defaulting to [ToolProtocol.openai]). A non-tool-calling model emitting a
  /// markdown-fenced JSON tool-call object is parsed into the same shape; a
  /// malformed object yields an empty `toolCalls` plus an
  /// `llm.toolcall.parse.failed` note and the text falls through as the
  /// no-tool answer.
  ///
  /// Throws [StateError] when no [RouteChainResolver] is bound (a wiring bug —
  /// `send` cannot route without one). A resolver that does not know [llmRoute]
  /// throws its own error; an empty resolved chain surfaces the substrate's
  /// `EmptyRouteChain`.
  // `async` so a synchronous validation throw (an unbound [RouteChainResolver],
  // or a malformed tool entry from `_buildToolCatalogue`) surfaces as a Future
  // rejection rather than escaping synchronously — the d4rt bridge awaits this
  // method, so its error contract is "the returned Future fails".
  Future<Map<String, Object?>> send(
    String transcript, {
    required String llmRoute,
    String role = defaultRole,
    List<Object?>? tools,
    double? temperature,
    int? maxOutputTokens,
    Map<String, Object?>? responseFormat,
    String? channel,
  }) async {
    final resolver = _routeChainOf;
    if (resolver == null) {
      throw StateError(
        'sub.send requires a RouteChainResolver but none was bound on the '
        'SubstrateBridge (route "$llmRoute").',
      );
    }
    final chain = resolver(llmRoute);
    return _completeOnce(
      primitive: 'send',
      recordInput: <String, Object?>{
        'prompt': transcript,
        'role': role,
        'route': llmRoute,
      },
      prompt: transcript,
      role: role,
      options: LlmOptions(
        toolCatalogue: _buildToolCatalogue(tools),
        temperature: temperature,
        maxOutputTokens: maxOutputTokens,
        responseFormat: responseFormat,
      ),
      routeChain: chain,
      // Per-call stream routing (§9.2). `null` ⇒ the §9.2 default by [role]
      // (an `assistant_to_user` answer streams to the user). An explicit
      // `'thinking'` forces the out-of-band channel — the lever a registered
      // prompt's `channel:` setting pulls through `sub.run`/`tool_loop_v1` so a
      // deliberation turn under the user-facing role (e.g. the answer loop's
      // DONE/CONTINUE `completion_check`, §13.2) never leaks to the answer.
      channel: channel,
    );
  }

  // ── run ───────────────────────────────────────────────────────────

  /// Runs a **registered prompt by id** (§7.1 / §7.4): resolves the prompt's
  /// inherited settings + loaded, placeholder-resolved template via the injected
  /// [PromptResolver], renders the one placeholder it owns (`${tools.catalogue}`)
  /// from the resolved tool set, assembles the initial transcript, then
  /// **delegates the send→parse→execute→re-send loop** to the shared
  /// `scripts/system/tool_loop_v1.dart` d4rt script via the injected
  /// [ProcedureRunner] (the engine's `runProcedure` primitive). `run` does
  /// **not** implement the loop — it owns only the Dart-side resolution.
  ///
  /// [promptId] names the registered prompt (e.g.
  /// `assist_user.answer_with_memory.assembly`); [inputs] are the placeholder
  /// bindings the resolver resolves the template against (plus the §6 built-ins
  /// the resolver injects). Returns the loop's `{answer, toolLoopExhausted}`.
  ///
  /// Throws [UnregisteredPromptException] when [promptId] is not registered
  /// (the resolver returns `null`), and [StateError] when no [PromptResolver] /
  /// [ProcedureRunner] is bound (a wiring bug — `run` cannot resolve or
  /// delegate without them).
  ///
  /// The anchor invariant (PE-7 / principle 5) is preserved exactly as for
  /// [send]: `run` never hands the substrate a wire prompt — it builds the
  /// transcript that `tool_loop_v1` passes to `sub.send` as the role template's
  /// `prompt` input, so the role still prepends persona + the assistant-
  /// dedication anchor at the substrate's assembly time.
  Future<Map<String, Object?>> run(
    String promptId, {
    Map<String, Object?> inputs = const <String, Object?>{},
  }) async {
    final resolver = _promptResolver;
    if (resolver == null) {
      throw StateError(
        'sub.run requires a PromptResolver but none was bound on the '
        'SubstrateBridge (prompt "$promptId").',
      );
    }
    final runner = _runProcedure;
    if (runner == null) {
      throw StateError(
        'sub.run requires a ProcedureRunner but none was bound on the '
        'SubstrateBridge (prompt "$promptId").',
      );
    }

    final resolved = await resolver(promptId, inputs);
    if (resolved == null) {
      throw UnregisteredPromptException(promptId);
    }

    // Render the one placeholder `run` owns — `${tools.catalogue}` — from the
    // resolved tool set (§7.4). Every other placeholder was already resolved by
    // the [PromptResolver] against `inputs` + the §6 built-ins; the catalogue is
    // the exception because it depends on the tool list `run` resolves here.
    final transcript = _renderToolCataloguePlaceholder(
      resolved.templateBody,
      resolved.tools,
    );

    // Delegate the loop to the shared `tool_loop_v1` script. Per-prompt
    // variation rides entirely in these inputs (§7.2): the same loop body serves
    // every prompt. The script returns `{answer, toolLoopExhausted}`.
    // Per-run profile role fallback (`session_configuration.md` § 5.1, plan
    // step 8 (a); SCP-31). A profile's role *fills* a prompt that names none —
    // `ResolvedPrompt.role` is empty — but never overrides a named role. So the
    // engine-bound `_profileRole` is used only when the resolved prompt leaves
    // the role unset.
    final effectiveRole =
        (resolved.role.isEmpty &&
            _profileRole != null &&
            _profileRole.isNotEmpty)
        ? _profileRole
        : resolved.role;

    final loopInputs = ProcedureInputs(<String, Object?>{
      'transcript': transcript,
      'route': resolved.llmRoute,
      'role': effectiveRole,
      'tools': resolved.tools,
      'maxToolLoops': resolved.maxToolLoops,
      if (resolved.temperature != null) 'temperature': resolved.temperature,
      // The prompt's resolved stream channel (§9.2). Forwarded so `tool_loop_v1`
      // can pin its `sub.send` to the out-of-band thinking channel for a
      // deliberation prompt run under the user-facing role (the answer loop's
      // DONE/CONTINUE `completion_check`, §13.2). Absent ⇒ the §9.2 default by
      // role, so every existing answering prompt is unaffected.
      if (resolved.channel != null) 'channel': resolved.channel,
    });
    final result = await runner(toolLoopProcedureId, loopInputs);

    final answer = result.output<String>('answer') ?? '';
    final exhausted = result.output<bool>('toolLoopExhausted') ?? false;
    return <String, Object?>{'answer': answer, 'toolLoopExhausted': exhausted};
  }

  /// Resolves a registered prompt or fragment to its **rendered template body**,
  /// *without* issuing any LLM call (§7.1 / §13.2). [render] is the no-LLM
  /// sibling of [run]: it performs the identical Dart-side resolution through
  /// the injected [PromptResolver] — registry lookup, settings inheritance,
  /// template loading, placeholder + `${tools.catalogue}` rendering — but stops
  /// before the tool loop. There is no `send`, no role assembly, no route.
  ///
  /// It is how a procedure turns a `kind: fragment` template into a string to
  /// inject into another prompt's input slot, replacing the deleted inline Dart
  /// string builders (`_renderTodoList` / `_continueReminderText`, plan step
  /// 11): the answer loops render `assist_user.*.todo_list` (over the live
  /// `todo.list` result) and `assist_user.*.continuation_hint` here, then pass
  /// the results as the `todo_list` / `open_todo_reminder` inputs of the next
  /// `sub.run`.
  ///
  /// [promptId] names the registered template; [inputs] are the placeholder
  /// bindings the resolver resolves against (plus the §6 built-ins). Returns the
  /// fully rendered body (`${tools.catalogue}` rendered from the prompt's
  /// resolved tool set, a no-op for the marker-less fragments).
  ///
  /// Throws [UnregisteredPromptException] when [promptId] is not registered and
  /// [StateError] when no [PromptResolver] is bound (a wiring bug — `render`
  /// cannot resolve without one).
  Future<String> render(
    String promptId, {
    Map<String, Object?> inputs = const <String, Object?>{},
  }) async {
    final resolver = _promptResolver;
    if (resolver == null) {
      throw StateError(
        'sub.render requires a PromptResolver but none was bound on the '
        'SubstrateBridge (prompt "$promptId").',
      );
    }
    final resolved = await resolver(promptId, inputs);
    if (resolved == null) {
      throw UnregisteredPromptException(promptId);
    }
    return _renderToolCataloguePlaceholder(
      resolved.templateBody,
      resolved.tools,
    );
  }

  /// The id of the shared tool-loop procedure [run] delegates to (§7.2).
  static const String toolLoopProcedureId = 'tool_loop_v1';

  /// Replaces the literal `${tools.catalogue}` marker in [template] with a
  /// rendered "Tools available to you" block built from [tools] (§7.4). A
  /// template without the marker is returned unchanged; an empty [tools] set
  /// (the `none` profile) renders the marker away to the empty string.
  ///
  /// Each descriptor is a `{name, description?, group?, input_schema?}` map (the
  /// `tool.list` wire shape); the block names each tool, renders its argument
  /// schema inline, and states the canonical `call:NAME{…}` format the substrate
  /// must emit — the same rendering discipline `answer_with_memory_v1` applies,
  /// so a prompt migrated onto `run` (increment 6) sees an identical catalogue.
  static String _renderToolCataloguePlaceholder(
    String template,
    List<Object?> tools,
  ) {
    const marker = r'${tools.catalogue}';
    if (!template.contains(marker)) return template;
    return template.replaceAll(marker, _renderToolCatalogue(tools));
  }

  /// Renders [tools] as a "Tools available to you" block, or `''` when there is
  /// none. Mirrors `answer_with_memory_v1._renderToolCatalogue` (§9.1): each
  /// tool line carries its `args: {…}` schema and the block closes with the
  /// canonical call-format instruction, so a memoryless substrate emits a clean,
  /// parseable `call:NAME{…}`.
  static String _renderToolCatalogue(List<Object?> tools) {
    if (tools.isEmpty) return '';
    var rendered = '';
    for (final tool in tools) {
      if (tool is! Map) continue;
      final name = tool['name'];
      if (name == null || '$name'.isEmpty) continue;
      final group = tool['group'];
      final description = tool['description'];
      final groupSuffix = (group != null && '$group'.isNotEmpty)
          ? ' ($group)'
          : '';
      final descSuffix = (description != null && '$description'.isNotEmpty)
          ? ': $description'
          : '';
      final argsSuffix = ' ${_renderArgsSchema(tool['input_schema'])}';
      rendered += '- $name$groupSuffix$descSuffix$argsSuffix\n';
    }
    if (rendered.isEmpty) return '';
    final howToCall =
        'To use a tool, reply with ONLY a single call line and no '
        'other text, using the exact tool name and argument keys from the list '
        'above:\n'
        '  call:TOOL_NAME{arg1: "value", arg2: 123}\n'
        'For a tool with no arguments use empty braces: call:TOOL_NAME{}\n'
        'Example: call:memory.read{text: "project history"}\n'
        'If you do not need a tool, just answer the user in plain prose.\n';
    return 'Tools available to you:\n$rendered\n$howToCall\n';
  }

  /// Renders one tool's `input_schema` as a compact `args: {key: type
  /// (required), …}` signature (§9.1). Mirrors
  /// `answer_with_memory_v1._renderArgsSchema`. A tool with no readable
  /// properties renders `args: {}`.
  static String _renderArgsSchema(Object? schema) {
    if (schema is! Map) return 'args: {}';
    final properties = schema['properties'];
    if (properties is! Map || properties.isEmpty) return 'args: {}';
    final required = <String>{};
    final rawRequired = schema['required'];
    if (rawRequired is List) {
      for (final entry in rawRequired) {
        if (entry is String) required.add(entry);
      }
    }
    final parts = <String>[];
    properties.forEach((key, spec) {
      final keyName = '$key';
      final type = (spec is Map && spec['type'] != null)
          ? '${spec['type']}'
          : 'value';
      final requiredSuffix = required.contains(keyName) ? ' (required)' : '';
      parts.add('$keyName: $type$requiredSuffix');
    });
    return 'args: {${parts.join(', ')}}';
  }

  // ── shared completion core ─────────────────────────────────────────

  /// The build-and-drain core shared by [send] and [retrievalRole].
  ///
  /// Both callers issue exactly one substrate completion and return the
  /// uniform `{text, toolCalls, unresolvedToolCall, report}` map; they differ
  /// only in *how the route is chosen*. A role-keyed completion (the path
  /// [retrievalRole] takes) leaves [routeChain] null so the substrate consults
  /// `roleRoutes[role]`; [send] routes over the explicit [routeChain] resolved
  /// from a route name. Every other concern — anchor-preserving role assembly,
  /// the budget gate / trail record (via [_record]), per-call channel routing
  /// (§9.2), tool-call resolution (§9.1), turn correlation, and the
  /// raw-LLM-trail observation — is identical, so it lives here once rather
  /// than duplicated across callers.
  ///
  /// [primitive] is the recorder/ledger name (`'llm'` or `'send'` — both
  /// charged as llm calls, §8 accountant). [recordInput] is the argument map
  /// the trail records. [options] is the fully built [LlmOptions] (its
  /// `toolCatalogue` is read back for the tool-call resolve step). [budget] is
  /// the optional primitive budget map; [channel] forces the stream channel
  /// (`null` ⇒ defaults by [role]).
  Future<Map<String, Object?>> _completeOnce({
    required String primitive,
    required Map<String, Object?> recordInput,
    required String prompt,
    required String role,
    required LlmOptions options,
    List<RouteEntry>? routeChain,
    Map<String, Object?>? budget,
    String? channel,
  }) => _record<Map<String, Object?>>(primitive, recordInput, () async {
    final catalogue = options.toolCatalogue;
    // Per-call stream routing (§ 9.2 Todo 6). The resolved channel says
    // where this completion's text streams: the **answer** channel the
    // user reads, or the out-of-band **thinking** channel. Explicit
    // `channel` wins; otherwise it defaults by role (an
    // `assistant_to_user` answer streams to the user; a deliberation role
    // streams to thinking).
    final toThinking = _resolvesToThinking(channel, role);
    // A tools-bearing call is an agentic *decision* turn: any chunk could
    // turn out to be a `call:NAME{…}` the user must never read, so its
    // text is buffered and routed at completion (tool-deciding text →
    // thinking; a plain answer is left for the body to deliver via
    // `emit`). A tools-free call cannot be a tool decision, so an answer
    // turn streams live token-by-token as before.
    final hasTools = catalogue.isNotEmpty;
    final liveAnswer = !toThinking && !hasTools;
    // Turn-correlation stamp (logging-spec §3 / §9): when a turn is bound,
    // name this completion with the turn's id and the next per-turn
    // `callSeq`. The counter advances once per llm call (embeddings do not
    // consume it) and spans the turn's nested runs because the one
    // [TurnContext] is shared down. Unbound (internal / dream) ⇒ both null.
    final turn = _turn;
    // Hoisted so the same ordinal stamps both the outbound call and the
    // raw-trail observation; calling `nextCallSeq()` twice would burn two
    // ordinals for one completion (§5.2 `callSeq` must match §3's stamp).
    final callSeq = turn?.nextCallSeq();
    // Stamp the live tom_brain session id onto the call (agent-SDK spec
    // § 1.5). Every HTTP / stub provider ignores `brainSessionId`; only
    // the Agent SDK provider reads it — the session it serves the call from,
    // and in `sessionMode: brain` the key of the conversation it resumes.
    // A turn-less (internal / dream) call carries a null session id.
    final stampedOptions = turn?.brainSessionId == null
        ? options
        : options.copyWith(sessionId: turn!.brainSessionId);
    final call = LlmCall(
      roleId: role,
      inputs: <String, Object?>{'prompt': prompt},
      options: stampedOptions,
      budget: _buildBudget(budget),
      turnId: turn?.turnId,
      callSeq: callSeq,
      // null for `llm` (route by role); the explicit chain for `send`.
      routeChain: routeChain,
      // Per-run profile anchoring toggle (§ 3.4, plan step 9): `false`
      // omits the dedication anchor for the run's profile (the relay).
      anchored: _anchored,
    );

    // Raw-trail provenance (§5.2): when the engine bound a trail observer,
    // record when this completion began so the writer can emit `startedAt`.
    final onLlmTrail = _onLlmTrail;
    final startedAt = DateTime.now().toUtc();

    final buffer = StringBuffer();
    // A buffered (tools-bearing or thinking) turn captures its deltas so
    // they can be routed once at completion: a terminal answer replays
    // them to the answer channel in their original chunk boundaries (so
    // streaming UX survives), while a tool-deciding turn discards them
    // from the answer and surfaces the whole text as one thinking notice.
    final bufferedDeltas = liveAnswer ? null : <String>[];
    final nativeToolCalls = <Object?>[];
    final onToken = _onToken;
    String? providerId;

    await for (final event in client.completeStream(call)) {
      switch (event) {
        case LlmTextDelta(:final text):
          buffer.write(text);
          // External/user-request path (P1.3 #7): forward each delta
          // live as it arrives, but ONLY when this is a live answer turn
          // (no tools on offer, answer channel). A tools-bearing turn is
          // buffered and routed once at completion (§ 9.2 Todo 6) so a
          // `call:NAME{…}` decision never leaks onto the answer channel;
          // its deltas are captured to be replayed verbatim if it turns
          // out to be a terminal answer. Awaited so the downstream sink
          // keeps ordering and backpressure. The buffer is still
          // accumulated — the returned `text` feeds the procedure's
          // persist step and preserves correct late-failure HTTP status.
          // With no sink bound the chunk is only buffered (the internal /
          // free-time path).
          if (liveAnswer && onToken != null) {
            await onToken(text);
          } else {
            bufferedDeltas?.add(text);
          }
        case LlmToolCall(
          callId: final toolCallId,
          name: final toolName,
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
        case LlmRunStarted(providerId: final id):
          providerId = id;
        case LlmRunCompleted(
          :final report,
          callId: final completedCallId,
          :final wire,
        ):
          final protocol =
              _toolProtocolOf?.call(providerId ?? report.providerId) ??
              ToolProtocol.openai;
          final answer = buffer.toString();
          final resolved = await _resolveToolCalls(
            protocol,
            nativeToolCalls,
            answer,
            catalogue,
          );
          final toolCalls = resolved.calls;
          // The § 9.1 Todo 8 guard: the text looked like a tool call but
          // resolved to zero executable calls (a name not on offer, or
          // args that failed every parse). It is the model *failing to
          // work*, not an answer — so its text must be kept off the
          // answer channel (routed to thinking below) and the flag is
          // surfaced for the loop body to feed an error turn back.
          final unresolvedToolCall = resolved.unresolvedAttempt;
          // Buffered-turn routing (§ 9.2 Todo 6). A live answer turn
          // already streamed its tokens, so it needs no completion
          // routing. Otherwise route the buffered text by outcome:
          //   - a tool-deciding turn (it resolved to a tool call) is the
          //     model *working* — its text is the `call:NAME{…}` decision,
          //     which goes to the thinking channel as one notice and never
          //     to the answer the user reads;
          //   - a plain completion on the thinking channel surfaces its
          //     whole text as one thinking notice;
          //   - a plain completion on the answer channel IS the answer:
          //     replay its captured deltas to the answer channel in their
          //     original chunk boundaries, so a buffered terminal answer
          //     still streams to the user.
          if (!liveAnswer) {
            if (toolCalls.isNotEmpty || toThinking || unresolvedToolCall) {
              // Label the streamed stage (§ 9.2 Todo 7): prefix the notice
              // with a short, role-keyed stage marker so the user can
              // follow the live process (`🧠 analysing… …`). The label
              // rides only on the notice — `answer` (returned to the body
              // for persist / transcript) stays unlabeled. An unresolved
              // tool-call attempt (§ 9.1 Todo 8) routes here too: its
              // `call:NAME{…}` text is working text, never the answer.
              _onThinking?.call(_labelThinkingStage(role, answer));
            } else if (onToken != null && bufferedDeltas != null) {
              for (final delta in bufferedDeltas) {
                await onToken(delta);
              }
            }
          }
          // Raw-trail observation (§5.2 / §10 step #4): fire the wire +
          // answer + report to the run's writer. Separate from the
          // result map (PE-1) and best-effort (logging-spec §9) — a
          // throwing observer must not break the completion.
          if (onLlmTrail != null) {
            try {
              onLlmTrail(
                LlmCallObservation(
                  callType: role,
                  turnId: turn?.turnId.value,
                  callSeq: callSeq,
                  callId: completedCallId ?? '',
                  startedAt: startedAt,
                  wire: wire,
                  answer: answer,
                  report: report,
                  options: stampedOptions,
                ),
              );
            } catch (_) {
              // Trail writing is non-essential; swallow to protect the
              // completion path.
            }
          }
          return <String, Object?>{
            'text': answer,
            'toolCalls': toolCalls,
            'unresolvedToolCall': unresolvedToolCall,
            'report': _reportToMap(report),
          };
        case LlmRunFailed(:final failure, report: final failReport):
          throw LlmCompletionFailure(
            classCode: failure.classCode,
            message: failure.message,
            report: failReport == null
                ? const <String, Object?>{}
                : _reportToMap(failReport),
          );
        default:
          // Thinking, usage and the other trail events carry nothing
          // this bridge records.
          break;
      }
    }

    // A well-behaved substrate always terminates with Completed or
    // Failed. Reaching here means the stream closed without a terminal
    // event — a substrate contract violation, surfaced loudly.
    throw StateError(
      'completeStream closed without a terminal '
      'LlmRunCompleted/LlmRunFailed event.',
    );
  }, resultOf: (value) => value);

  /// Resolves the uniform `toolCalls` list from a completion, recovering a
  /// text-format tool call whatever dialect the model wrote it in (Q-F.4).
  ///
  /// Native structured calls always win: under [ToolProtocol.openai] the
  /// substrate surfaces them as [LlmToolCall] events collected
  /// into [native], and those are returned unchanged. When [native] is empty,
  /// the call may still be hiding in the completion [text] — the live failure
  /// mode is Gemma-on-oMLX, an `openai`-protocol provider that writes
  /// `<|tool_call>call:web.search{…}<tool_call|>` into text instead of
  /// emitting a native array. So for *either* protocol we parse [text] across
  /// every known dialect (Gemma sentinel, functional `call:NAME{…}`, JSON
  /// object/array, Hermes `<tool_call>`, Mistral `[TOOL_CALLS]`, fenced JSON)
  /// and keep only calls to a tool actually on offer. [protocol] is retained
  /// as the declared wire contract; recovery is intentionally protocol-
  /// agnostic because any provider can degrade to a text call.
  ///
  /// A completion with no tools on offer ([catalogue] empty) is never a tool
  /// call. Text that looked like a tool-call attempt but did not parse — or
  /// named a tool not on offer — yields an empty list, sets [_ResolvedToolCalls.unresolvedAttempt],
  /// and emits the typed `llm.toolcall.parse.failed` note; plain prose is
  /// silent (and `unresolvedAttempt` stays `false`).
  ///
  /// The `unresolvedAttempt` flag is the § 9.1 Todo 8 guard signal: the answer
  /// loop reads it to feed an error turn back instead of returning the raw
  /// `call:NAME{…}` text as the user's answer, and [send] routes that text to the
  /// thinking channel (never the answer) at completion.
  Future<_ResolvedToolCalls> _resolveToolCalls(
    ToolProtocol protocol,
    List<Object?> native,
    String text,
    ToolCatalogue catalogue,
  ) async {
    if (native.isNotEmpty) {
      return _ResolvedToolCalls(native, unresolvedAttempt: false);
    }
    if (catalogue.isEmpty) {
      return const _ResolvedToolCalls(<Object?>[], unresolvedAttempt: false);
    }

    final knownNames = <String>{for (final tool in catalogue.tools) tool.name};
    final parsed = parseToolCallsFromText(text, knownToolNames: knownNames);
    if (parsed.isEmpty) {
      if (looksLikeToolCallAttempt(text)) {
        await _noteToolCallParseFailed(text);
        return const _ResolvedToolCalls(<Object?>[], unresolvedAttempt: true);
      }
      return const _ResolvedToolCalls(<Object?>[], unresolvedAttempt: false);
    }
    return _ResolvedToolCalls(<Object?>[
      for (final call in parsed)
        <String, Object?>{
          'id': null,
          'name': call.name,
          'arguments': call.arguments,
        },
    ], unresolvedAttempt: false);
  }

  /// Emits the `llm.toolcall.parse.failed` note when a `json_text` completion
  /// looked like a tool call but could not be read as one. A no-op when no
  /// [SubstrateNoteSink] is bound (the low-level path's default).
  Future<void> _noteToolCallParseFailed(String text) async {
    await _onNote?.call('llm.toolcall.parse.failed', <String, Object?>{
      'text': text,
    });
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

  /// The deliberation roles whose completions default to the **thinking**
  /// channel (§ 9.2 Todo 6): they reason *about* a prompt rather than answer the
  /// user, so their text is working text, not an answer. Every other role
  /// (notably [defaultRole], `assistant_to_user`) defaults to the answer
  /// channel.
  static const Set<String> _thinkingRoles = <String>{
    'analyser',
    'sub_thinker',
    'evaluator',
  };

  /// Resolves whether a completion streams on the **thinking** channel.
  ///
  /// An explicit [channel] wins (`'thinking'` ⇒ thinking; any other value ⇒
  /// answer); with none given the [role] decides — a [_thinkingRoles] member
  /// streams to thinking, everything else to the answer channel.
  static bool _resolvesToThinking(String? channel, String role) {
    if (channel != null) return channel == 'thinking';
    return _thinkingRoles.contains(role);
  }

  /// Short, role-keyed stage labels for the streamed thinking notice (§ 9.2
  /// Todo 7). Each labels *which* cognitive stage is running so the user can
  /// follow the live process. A role with no entry — including a tool-deciding
  /// `assistant_to_user` turn routed here because its text was a `call:NAME{…}`
  /// — uses [_fallbackStageLabel].
  static const Map<String, String> _stageLabels = <String, String>{
    'analyser': '🧠 analysing…',
    'sub_thinker': '🧩 reasoning…',
    'recaller': '📚 recalling…',
    'synthesiser': '✍️ drafting…',
    'evaluator': '🔎 critiquing…',
  };

  /// The generic label for thinking text whose role names no specific stage.
  static const String _fallbackStageLabel = '🤔 thinking…';

  /// Prefixes [text] with [role]'s stage label so the thinking notice reads as
  /// `🧠 analysing… <text>` (§ 9.2 Todo 7). The label lives only on the notice;
  /// the unlabeled [text] is what the bridge returns to the procedure.
  static String _labelThinkingStage(String role, String text) {
    final label = _stageLabels[role] ?? _fallbackStageLabel;
    return text.isEmpty ? label : '$label $text';
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
      final schema = _reader.optionalMap(
        map,
        'input_schema',
        'tools[$i].input_schema',
      );
      descriptors.add(
        ToolDescriptor(
          name: name,
          description: description,
          parametersSchema: schema == null
              ? const <String, Object?>{}
              : _coerceStringKeys(schema),
        ),
      );
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
  /// method runs one role-keyed completion through the shared [_completeOnce]
  /// core (so the anchor and budget gate still apply, charged under the `llm`
  /// effort class), reads the completion text, `jsonDecode`s it, and lifts it
  /// into the role's typed shape via `parseRetrievalRoleOutput`.
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
    final completion = await _completeOnce(
      primitive: 'llm',
      recordInput: <String, Object?>{'prompt': prompt, 'role': roleId},
      prompt: prompt,
      role: roleId,
      options: LlmOptions(toolCatalogue: _buildToolCatalogue(null)),
      budget: budget,
    );
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
      return _retrievalDegraded(
        'role "$roleId" output is not JSON: ${e.message}',
      );
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
  }) => _record<Map<String, Object?>>(
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
  Future<Map<String, Object?>> fetch(String url, {int? budgetBytes}) =>
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
          _reader
              .optionalNum(raw, 'wallClockMs', 'budget.wallClockMs')
              ?.toInt() ??
          fallback.wallClockMs,
      tokenSpend:
          _reader
              .optionalNum(raw, 'tokenSpend', 'budget.tokenSpend')
              ?.toInt() ??
          fallback.tokenSpend,
      toolCalls:
          _reader.optionalNum(raw, 'toolCalls', 'budget.toolCalls')?.toInt() ??
          fallback.toolCalls,
      memoryWrites:
          _reader
              .optionalNum(raw, 'memoryWrites', 'budget.memoryWrites')
              ?.toInt() ??
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

/// The outcome of resolving a completion's tool calls (§ 9.1 Todo 8).
///
/// [calls] is the uniform `{id, name, arguments}` list (empty when none).
/// [unresolvedAttempt] is `true` only when the completion *looked* like a
/// tool-call attempt yet resolved to zero executable calls (a tool name not on
/// offer, or args that failed every parse) — the signal [SubstrateBridge.send]
/// surfaces as `unresolvedToolCall` so the answer loop feeds an error turn back
/// instead of returning the raw `call:NAME{…}` text as the answer.
class _ResolvedToolCalls {
  const _ResolvedToolCalls(this.calls, {required this.unresolvedAttempt});

  final List<Object?> calls;
  final bool unresolvedAttempt;
}

/// Receives each generated text delta from [SubstrateBridge.send] as it
/// streams (P1.3 #7 — the end-to-end token-streaming seam).
///
/// The engine binds a per-run instance only for an **external/user** request;
/// internal secondary and free-time prompts leave it unbound and keep the
/// buffered path (spec § 11 step 2 — streaming is required for incoming
/// external requests, optional otherwise). [textDelta] is one substrate
/// [LlmTextDelta]'s text, in arrival order. The future is awaited per chunk
/// so the downstream consumer (the OpenAI SSE edge, wired in #8–#9) preserves
/// ordering and backpressure.
typedef SubstrateTokenSink = Future<void> Function(String textDelta);

/// Receives a low-level tool-protocol diagnostic from [SubstrateBridge.send]
/// (Extension F step 10).
///
/// The only category emitted today is `llm.toolcall.parse.failed` — a
/// `json_text` completion that looked like a tool call but could not be read
/// as one. The engine binds a per-run sink that folds the note onto the run's
/// trail (the `call_llm_v1` loop, step 11, is the consumer); the shared
/// template bridge and internal paths leave it unbound and the note is
/// dropped. [category] is the dotted note category; [payload] carries the
/// diagnostic detail (the offending completion text).
typedef SubstrateNoteSink =
    Future<void> Function(String category, Map<String, Object?> payload);

/// Receives the **thinking** channel text from [SubstrateBridge.send]
/// (`agent_loop_completion.md` § 9.2 Todo 6).
///
/// Fired once per buffered turn that routes to thinking — a tool-deciding
/// turn's `call:NAME{…}` decision text, or the whole completion of a
/// thinking-channel role — never per token. The engine binds a per-run sink
/// only on the top-level external run; internal / free-time runs leave it
/// unbound and the thinking text is dropped (no live caller). [text] is the
/// completion's full text. Fire-and-forget (unlike [SubstrateTokenSink]): a
/// thinking notice carries no answer text, so it neither paces nor blocks the
/// body's streaming.
typedef SubstrateThinkingSink = void Function(String text);

/// Resolves a provider id to the wire [ToolProtocol] it speaks (Extension F
/// step 2 / step 10).
///
/// The substrate package is protocol-unaware, so the bridge needs this seam to
/// know whether to collect native [LlmToolCall] events
/// ([ToolProtocol.openai]) or parse a JSON tool-call object out of the
/// completion text ([ToolProtocol.jsonText]). The host binds a registry-backed
/// resolver at boot wiring (plan step 15); an unbound resolver treats every
/// provider as [ToolProtocol.openai].
typedef ToolProtocolResolver = ToolProtocol Function(String providerId);

/// Resolves an LLM route *name* to the `List<RouteEntry>` chain
/// [SubstrateBridge.send] dispatches over (§7.4 / §8).
///
/// The cognition config's `llm:` block names routes (e.g. `fast`, `deep`); a
/// prompt selects one by name and `send` routes over its chain instead of the
/// role-keyed chain `llm` uses. The host binds a resolver backed by that route
/// table at boot wiring (increment 5 step 5d); the bridge stays config-unaware
/// — it is handed the name→chain function, the `ToolProtocolResolver` pattern
/// applied to route selection. A resolver that does not know the name should
/// throw (an unknown route is a config error, not a silent fallback).
typedef RouteChainResolver = List<RouteEntry> Function(String routeName);

/// Resolves a registered prompt *id* to its [ResolvedPrompt] (§7.1 / §7.4).
///
/// The host backs it with the cognition config's prompt registry: the seam
/// performs the registry lookup, inheritance resolution, template load, and
/// placeholder resolution (against [inputs] + the §6 built-ins), and yields the
/// inherited settings + resolved template body. Returns `null` when [promptId]
/// is not registered — [SubstrateBridge.run] turns that into an
/// [UnregisteredPromptException]. The bridge stays config-unaware — it is handed
/// the id→settings function, the [RouteChainResolver] pattern applied to prompt
/// resolution.
typedef PromptResolver =
    Future<ResolvedPrompt?> Function(
      String promptId,
      Map<String, Object?> inputs,
    );

/// Runs another procedure by id on behalf of [SubstrateBridge.run] (§7.2).
///
/// The engine binds it per run over that run's depth-capped
/// `RunProcedurePrimitive`, so the delegated `tool_loop_v1` run gets correct
/// depth bookkeeping and its own trail — exactly the path a scripted nested
/// `runProcedure` takes. `run` is the only caller; it always targets the latest
/// version, so the seam takes no `version`.
typedef ProcedureRunner =
    Future<ProcedureResult> Function(
      String procedureId,
      ProcedureInputs inputs,
    );

/// Thrown by [SubstrateBridge.send] when the substrate stream terminates
/// with [LlmRunFailed].
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
