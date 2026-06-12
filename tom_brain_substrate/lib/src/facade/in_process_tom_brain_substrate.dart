// B.41 — `InProcessTomBrainSubstrate`.
//
// Plan step B.41 (verbatim, `prototype_implementation_plan.md` § Phase B):
//
//   "Implement `TomBrainSubstrateInProcessClient`. (Isolate variant is
//    not needed at prototype scope; document it as future work in
//    `completion_steps.tom_brain.md`.)"
//
// **Class-name divergence (Q-B.41.1).** The plan text names the class
// `TomBrainSubstrateInProcessClient`; everywhere else in the in-tree
// design — `lib/src/api/tom_brain_substrate.dart` § "The concrete v1
// implementation (`InProcessTomBrainSubstrate`, lands B.40+) extends
// this", the B.40 boundary-lock test's "no field of type
// `InProcessTomBrainSubstrate`" rule, `lib/tom_brain_substrate.dart`'s
// `src/facade/` build-order note — refers to it as
// `InProcessTomBrainSubstrate`. The in-tree name carries the intent
// better (it IS the in-process variant of `TomBrainSubstrate`; it is
// not a `Client` of anything). This file follows the in-tree
// convention; Q-B.41.1 in `prototype_implementation_questions.md`
// captures the divergence.
//
// What this file owns:
//
//   * A concrete `final class InProcessTomBrainSubstrate extends
//     TomBrainSubstrate` — the v1 in-process composition root.
//     Composes a role registry, a provider map, an `LlmRouter`, an
//     `EmbeddingService`, a `WebSearch`, a `WebFetch`, a
//     `SubstrateEventBus`, and a lazy MCP-client cache.
//
//   * Anchor enforcement on every outbound report. Every
//     [LlmCallReport] returned by [complete] / [completeStream] must
//     carry [AnchorRegistry.currentHash] in `anchorHash`; mismatch
//     throws [AnchorViolation] before the report is observed by the
//     consumer (spec § 12 fatal event). The conformance test at
//     B.46 will exercise this against every emitted report.
//
//   * Substrate-event emission for every surface method that completes
//     observably:
//
//       - [complete] / [completeStream] success ⇒
//         [LlmCallCompleted] (carries the verbatim report).
//       - [complete] / [completeStream] failure ⇒ [LlmCallFailed]
//         (carries the typed [LlmFailure] and the partial report's
//         provider / model / retry triple).
//       - [embed] / [embedBatch] ⇒ [EmbeddingComputed] (per call;
//         `batchSize` reflects input length).
//       - [webSearch] ⇒ [WebSearchCompleted].
//       - [webFetch] ⇒ [WebFetchCompleted].
//       - MCP outbound activity is observed by the per-session
//         client; this facade does not synthesize per-call events
//         on top of `mcpClient(...)` (the cached `McpClient` is
//         consumer-driven — emitting events here would double-count
//         once the engine's tool-call adapter starts using the
//         session).
//
//     Plan step B.41 / spec § 10.2 ship the twelve-variant taxonomy.
//     The facade emits exactly the variants its surface methods are
//     authoritative over; per-subsystem variants (`ProviderFailover`,
//     `CredentialCooldownStarted`, `EmbeddingIdentityChanged`,
//     `McpHandshakeCompleted`, `McpCallCompleted`, `LlmCallStarted`,
//     `LlmCallChunk`) are intentionally NOT synthesised here — they
//     are produced by the layer that has the authoritative
//     information about their lifecycle moment. The router would emit
//     `ProviderFailover` (B.43+ work — Q-B.41.2 captures the seam);
//     the MCP session would emit `McpCallCompleted`; etc. The
//     conformance gate this respects is: every emit point owns its
//     lifecycle moment, no event is double-emitted.
//
//   * Mutable per-process counters that back [stats]. The router
//     owns its own counter for [SubstrateStats.activeCooldowns] (via
//     [LlmRouter.cooldownsActive]); everything else is the facade's
//     accounting. Counters are read-only from the outside — [stats]
//     produces a fresh [SubstrateStats] snapshot on every call.
//
//   * Caching of `McpClient` per `McpEndpoint.id`. The factory
//     parameter lets tests inject a fake; production callers use the
//     default factory (a fresh `McpClient` per endpoint id, with the
//     substrate's own client identity). Closing the facade closes
//     every cached client.
//
//   * Idempotent lifecycle. [open] is idempotent — it validates the
//     supplied config against the bound role registry and stores it.
//     [close] is idempotent — it shuts the bus, closes the embedding
//     service / web tools / cached MCP clients exactly once.
//
// What this file deliberately does NOT own:
//
//   * Provider routing. That is `LlmRouter`'s job. The facade only
//     composes — it has no per-call routing decisions.
//
//   * Anchor injection mechanics. That is `RoleTemplate.assemble`'s
//     job (B.23). The facade calls `assemble(inputs: call.inputs)`
//     and trusts the resulting `WirePrompt.anchorHash` to be current;
//     enforcement here is at the *report* boundary, where a
//     misbehaving provider could have stripped the hash.
//
//   * Provider construction. The composition root (test, app boot)
//     constructs providers + router + embedding service + web tools
//     and hands them to the facade. The facade's job is wiring, not
//     manufacturing.
//
//   * The isolate / remote adapter variant. The plan defers it to
//     `completion_steps.tom_brain.md`; the engine binds against
//     [TomBrainSubstrateClient] (B.40 lock) so this facade and a
//     future isolate adapter ship through the same consumer surface.
//
//   * `SubstrateLog` integration. The B.39 / B.40 / B.41 Q-_*.3
//     thread defers the per-subsystem log-line migration to whichever
//     step actually wires the bus + log together. The facade ships
//     the bus wiring now; log lines are not added at every emit point
//     until the per-subsystem migration lands (Q-B.41.3 captures the
//     deferral; the existing per-subsystem code already calls
//     `SubstrateLog.<area>` at its own lifecycle moments — the
//     facade does not duplicate them).

import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../api/captured_wire.dart';
import '../api/embedding_result.dart';
import '../api/llm_call.dart';
import '../api/llm_stream_event.dart';
import '../api/mcp_endpoint.dart';
import '../api/substrate_event.dart';
import '../api/substrate_stats.dart';
import '../api/tom_brain_substrate.dart';
import '../api/web_results.dart';
import '../config/substrate_config.dart';
import '../embed/embedding_service.dart';
import '../llm/anchor_registry.dart';
import '../llm/llm_provider.dart';
import '../llm/wire_prompt.dart';
import '../mcp_client/mcp_client.dart';
import '../obs/substrate_event_bus.dart';
import '../roles/role_registry.dart';
import '../router/llm_router.dart';
import '../web/web_fetch.dart';
import '../web/web_search.dart';

/// The substrate package version reported on the wire (MCP client
/// identity, and any future protocol handshake that needs a version).
///
/// Single code-side source of truth: previously the version lived both
/// here and as a literal inside [_defaultMcpIdentity], kept in step only
/// by a comment — and had already drifted (`0.1.0` here vs `0.0.1` in the
/// pubspec). There is no build-time version generator in this package
/// (no `build_runner`), so this constant is the canonical code value;
/// it tracks `pubspec.yaml`'s `version` and is bumped in the same change
/// as a release.
const String substratePackageVersion = '0.0.1';

/// Default identity stamped on lazily-constructed [McpClient] instances.
/// Sourced from the single [substratePackageVersion] constant.
const McpClientIdentity _defaultMcpIdentity = McpClientIdentity(
  name: 'tom_brain_substrate',
  version: substratePackageVersion,
);

/// Signature for the lazy [McpClient] factory the facade uses to
/// materialise cached clients on demand.
///
/// The default factory produces an [McpClient] bound to the
/// substrate's own identity; tests inject a fake to return their own
/// double. The factory is **not** responsible for connecting the
/// client — handshake / transport hookup is consumer-driven (the
/// engine's tool-call adapter calls `connect(transport)` when it
/// needs a session).
typedef McpClientFactory = McpClient Function(McpEndpoint endpoint);

McpClient _defaultMcpClientFactory(McpEndpoint endpoint) {
  return McpClient(identity: _defaultMcpIdentity);
}

/// v1 in-process composition of the Tom Brain substrate.
///
/// `final` so a downstream package cannot subclass it and reach
/// around the lifecycle / anchor / event invariants. Tests that need
/// a fake substrate implement [TomBrainSubstrateClient] (or extend
/// [TomBrainSubstrate]) directly; they do not extend this class.
///
/// **Composition contract.** The composition root constructs every
/// collaborator (`RoleRegistry`, provider map, [LlmRouter],
/// [EmbeddingService], [WebSearch], [WebFetch]) and hands them in
/// pre-wired. The facade owns:
///
///   * The [SubstrateEventBus] (constructed internally unless the
///     caller injects one — useful for tests that bind a captor
///     before `open` runs).
///   * The mutable per-process counters that back [stats].
///   * The cache of [McpClient] instances keyed by `McpEndpoint.id`.
///
/// **Lifecycle.** [open] validates the supplied [SubstrateConfig]
/// against the bound role registry (every routed role id must be
/// registered — Q-B.22.4) and stores the config. Idempotent —
/// re-opening with a new config replaces the stored value; the
/// already-running collaborators are not rebuilt (configuration
/// hot-reload is out of scope for the prototype). [close] is
/// idempotent — second and subsequent calls return immediately.
///
/// **Anchor enforcement.** Every [LlmCallReport] returned by
/// [complete] / [completeStream] is checked against
/// [AnchorRegistry.currentHash]; a mismatch throws [AnchorViolation]
/// before the consumer observes the report. The conformance test at
/// B.46 proves no public path bypasses the check.
final class InProcessTomBrainSubstrate extends TomBrainSubstrate
    with CloseGuard {
  final RoleRegistry _roleRegistry;
  final Map<String, LlmProvider> _providers;
  final LlmRouter _router;
  final EmbeddingService _embeddingService;
  final WebSearch _webSearch;
  final WebFetch _webFetch;
  final SubstrateEventBus _eventBus;
  final McpClientFactory _mcpClientFactory;
  final DateTime Function() _now;

  /// The last config supplied to [open]. `null` until the first
  /// successful [open] call. Stored for future cross-validation
  /// hooks (price-table lookup in cost reporting, provider lookup
  /// for diagnostics) and for the [config] getter exposed to tests.
  SubstrateConfig? _config;

  /// Monotonic per-substrate call counter. Incremented on every
  /// [complete] / [completeStream]; folded into the substrate-side
  /// `callId` so trail consumers can correlate events that share a
  /// call without needing the provider's own id.
  int _callCounter = 0;

  // ─── Stats counters ──────────────────────────────────────────

  final Map<String, int> _callsPerProvider = <String, int>{};
  final Map<String, int> _callsPerRole = <String, int>{};
  int _embeddingsComputed = 0;
  DateTime? _lastRetryAt;
  int _webSearches = 0;
  int _webFetches = 0;
  int _mcpCalls = 0;

  // ─── McpClient cache ─────────────────────────────────────────

  final Map<String, McpClient> _mcpClientCache = <String, McpClient>{};

  /// Constructs a facade from pre-wired collaborators.
  ///
  /// Required collaborators:
  ///
  ///   * [roleRegistry] — produces [WirePrompt] from
  ///     [LlmCall.roleId] + [LlmCall.inputs] via `assemble(...)`.
  ///   * [providers] — keyed by `LlmProvider.id`. Held for
  ///     introspection (tests, future composition-root callers); the
  ///     facade dispatches through [router], it does not call
  ///     providers directly.
  ///   * [router] — the only legitimate consumer of [LlmProvider]
  ///     outside of provider conformance tests.
  ///   * [embeddingService] — single per-substrate instance.
  ///   * [webSearch] / [webFetch] — single per-substrate instances.
  ///
  /// Optional collaborators:
  ///
  ///   * [eventBus] — when null, the facade constructs its own
  ///     [SubstrateEventBus]. Tests that need to attach a captor
  ///     before `open` runs inject one explicitly.
  ///   * [config] — when non-null, the facade adopts this config at
  ///     construction; [open] can still be called later with a
  ///     different config.
  ///   * [mcpClientFactory] — when null, falls back to the default
  ///     factory (produces a fresh [McpClient] per endpoint id).
  ///   * [now] — clock seam. Tests inject a fixed clock to get
  ///     deterministic `occurredAt` / `snapshotAt` values; production
  ///     code leaves the default.
  InProcessTomBrainSubstrate({
    required RoleRegistry roleRegistry,
    required Map<String, LlmProvider> providers,
    required LlmRouter router,
    required EmbeddingService embeddingService,
    required WebSearch webSearch,
    required WebFetch webFetch,
    SubstrateEventBus? eventBus,
    SubstrateConfig? config,
    McpClientFactory? mcpClientFactory,
    DateTime Function()? now,
  })  : _roleRegistry = roleRegistry,
        _providers = Map<String, LlmProvider>.unmodifiable(providers),
        _router = router,
        _embeddingService = embeddingService,
        _webSearch = webSearch,
        _webFetch = webFetch,
        _eventBus = eventBus ?? SubstrateEventBus(),
        _mcpClientFactory = mcpClientFactory ?? _defaultMcpClientFactory,
        _now = now ?? DateTime.now,
        _config = config;

  // ─── Test / introspection accessors ─────────────────────────

  /// The most recently bound [SubstrateConfig], or `null` before
  /// the first successful [open]. Exposed for tests and for the
  /// (eventual) Forge brain inspector.
  SubstrateConfig? get boundConfig => _config;

  /// The registered role registry. Exposed read-only for tests that
  /// want to assert "the facade routed through this exact registry"
  /// (B.42 conformance suite leans on this for the cross-provider
  /// equivalence assertion).
  RoleRegistry get roleRegistry => _roleRegistry;

  /// The provider map keyed by `LlmProvider.id`. Unmodifiable copy
  /// of the constructor argument; mutating the original map after
  /// construction does not affect the facade's view.
  Map<String, LlmProvider> get providers => _providers;

  /// The bound router. Exposed read-only for tests / inspectors.
  LlmRouter get router => _router;

  // ─── Lifecycle ───────────────────────────────────────────────

  @override
  Future<void> open(SubstrateConfig config) async {
    _ensureNotClosed('open');
    // Cross-validation: every routed role id must be registered.
    // Surfaces SubstrateConfigException (wrapping RoleTemplateNotFound)
    // before the facade adopts the config.
    config.validateRoleRegistry(_roleRegistry);
    _config = config;
  }

  @override
  Future<void> close() async {
    if (!markClosed()) return;

    // Close cached MCP clients first so any in-flight server-side
    // sessions terminate before the bus closes (event drainage).
    for (final client in _mcpClientCache.values) {
      try {
        await client.close();
      } on Object {
        // Best-effort: a misbehaving session must not block shutdown.
      }
    }
    _mcpClientCache.clear();

    try {
      await _embeddingService.close();
    } on Object {
      // Same posture as above.
    }
    try {
      _webSearch.close();
    } on Object {
      // Same.
    }
    try {
      _webFetch.close();
    } on Object {
      // Same.
    }

    await _eventBus.close();
  }

  // ─── LLM ─────────────────────────────────────────────────────

  @override
  Future<LlmCallReport> complete(LlmCall call) async {
    _ensureNotClosed('complete');

    final template = _roleRegistry.get(call.roleId);
    final prompt = template.assemble(inputs: call.inputs);
    final callId = _allocateCallId();

    // The router surfaces failures as typed router-layer exceptions
    // (`NoRouteAvailable`, `ContextOverflowError`, `RoleNotFound`)
    // rather than as `LlmFailure` carriers; the facade does NOT
    // synthesize a `LlmCallFailed` event for those, because the
    // router-layer exception is not a per-call failure of *one*
    // provider — it is the chain's terminal verdict and carries no
    // provider/model triple. The streaming path (`completeStream`)
    // does see `LlmStreamFailed` carriers and emits the matching
    // event there. Trail consumers that need a structural
    // "the call ended in failure" signal for the buffered path read
    // the exception via `dart:async` zone hooks or wrap the call
    // themselves.
    final routeChain = call.routeChain;
    final report = routeChain == null
        ? await _router.dispatch(
            roleId: call.roleId,
            prompt: prompt,
            options: call.options,
            budget: call.budget,
            cancellationToken: call.cancellationToken,
          )
        : await _router.dispatchOverChain(
            roleId: call.roleId,
            chain: routeChain,
            prompt: prompt,
            options: call.options,
            budget: call.budget,
            cancellationToken: call.cancellationToken,
          );

    _enforceAnchorOrThrow(report: report, roleId: call.roleId);
    _recordCallSuccess(report: report, roleId: call.roleId);

    _safeEmit(
      LlmCallCompleted(
        occurredAt: _now().toUtc(),
        callId: callId,
        report: report,
      ),
    );

    return report;
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    // Eager validation + prompt assembly so a closed substrate or an
    // unknown role surfaces synchronously to the caller (RoleNotFound),
    // not lazily on the first listen.
    _ensureNotClosed('completeStream');
    final template = _roleRegistry.get(call.roleId);
    final prompt = template.assemble(inputs: call.inputs);
    final callId = _allocateCallId();

    // Returned as a lazy `async*` stream rather than pumped into a
    // fire-and-forget StreamController. B.3.4: the previous shape started
    // `drive()` before the consumer subscribed, so router work began and
    // events buffered even when no one was listening. An async generator
    // is single-subscription, starts only on listen, and propagates the
    // subscriber's pause/resume back through `await for` to the router
    // (and thus the provider) as real back-pressure.
    return _driveCompleteStream(call, prompt, callId);
  }

  /// The streaming driver behind [completeStream]. Pure transform of the
  /// router's event stream: enforces the anchor and records observability
  /// on the terminal events, then forwards every event. A thrown
  /// exception (anchor violation or router-terminal failure) propagates
  /// as a stream error and terminates the stream.
  Stream<LlmStreamEvent> _driveCompleteStream(
    LlmCall call,
    WirePrompt prompt,
    String callId,
  ) async* {
    final routeChain = call.routeChain;
    final upstream = routeChain == null
        ? _router.dispatchStream(
            roleId: call.roleId,
            prompt: prompt,
            options: call.options,
            budget: call.budget,
            cancellationToken: call.cancellationToken,
          )
        : _router.dispatchStreamOverChain(
            roleId: call.roleId,
            chain: routeChain,
            prompt: prompt,
            options: call.options,
            budget: call.budget,
            cancellationToken: call.cancellationToken,
          );
    await for (final event in upstream) {
      var toYield = event;
      if (event is LlmStreamCompleted) {
        _enforceAnchorOrThrow(
          report: event.report,
          roleId: call.roleId,
        );
        _recordCallSuccess(
          report: event.report,
          roleId: call.roleId,
        );
        _safeEmit(
          LlmCallCompleted(
            occurredAt: _now().toUtc(),
            callId: callId,
            report: event.report,
          ),
        );
        // Attach the wire body the provider actually saw, so a
        // downstream `LlmTrailWriter` can serialise the §5.2 raw trail
        // from one source of truth (`tom_brain_logging.md` §10 step #4).
        // `prompt` is the very `WirePrompt` handed to the provider, so
        // its anchorHash / templateSha match `event.report` by
        // construction (anchor invariant).
        toYield = LlmStreamCompleted(
          callId: event.callId,
          report: event.report,
          wire: CapturedWirePrompt(
            body: prompt.body,
            anchorHash: prompt.anchorHash,
            roleId: prompt.roleId,
            templateSha: prompt.templateSha,
          ),
        );
      } else if (event is LlmStreamFailed) {
        _safeEmit(
          LlmCallFailed(
            occurredAt: _now().toUtc(),
            callId: callId,
            failure: event.failure,
            providerId: event.report.providerId,
            modelId: event.report.modelId,
            retryCount: event.report.retries,
          ),
        );
      }
      yield toYield;
    }
  }

  // ─── Embedding ───────────────────────────────────────────────

  @override
  Future<EmbeddingResult> embed(String text) async {
    _ensureNotClosed('embed');
    final result = await _embeddingService.embed(text);
    _embeddingsComputed++;
    _safeEmit(
      EmbeddingComputed(
        occurredAt: _now().toUtc(),
        providerId: result.modelIdentity.providerId,
        modelId: result.modelIdentity.modelId,
        dims: result.modelIdentity.dims,
        batchSize: 1,
      ),
    );
    return result;
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    _ensureNotClosed('embedBatch');
    final results = await _embeddingService.embedBatch(texts);
    if (results.isEmpty) return results;
    _embeddingsComputed += results.length;
    final identity = results.first.modelIdentity;
    _safeEmit(
      EmbeddingComputed(
        occurredAt: _now().toUtc(),
        providerId: identity.providerId,
        modelId: identity.modelId,
        dims: identity.dims,
        batchSize: results.length,
      ),
    );
    return results;
  }

  // ─── Web tools ───────────────────────────────────────────────

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    _ensureNotClosed('webSearch');
    final result = await _webSearch.search(query, options: options);
    _webSearches++;
    _safeEmit(
      WebSearchCompleted(
        occurredAt: _now().toUtc(),
        provider: result.provider,
        query: result.query,
        k: options.k,
        hits: result.hits.length,
      ),
    );
    return result;
  }

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    _ensureNotClosed('webFetch');
    final result = await _webFetch.fetch(url, options: options);
    _webFetches++;
    _safeEmit(
      WebFetchCompleted(
        occurredAt: _now().toUtc(),
        url: result.url.toString(),
        status: result.status,
        // Prefer the measured body byte length the fetcher recorded
        // (real size, consistent across text / json / binary). The
        // fallbacks cover producers that did not measure (test
        // doubles); `DefaultWebFetch` always sets `contentBytes`, so
        // the JSON path reports its true byte length, not a 0/1
        // placeholder (B.3.5).
        bytes: result.contentBytes ??
            result.text?.length ??
            result.binaryMeta?.contentLength ??
            (result.json == null ? 0 : 1),
        truncated: result.truncated,
      ),
    );
    return result;
  }

  // ─── MCP outbound ────────────────────────────────────────────

  @override
  McpClient mcpClient(McpEndpoint endpoint) {
    _ensureNotClosed('mcpClient');
    final cached = _mcpClientCache[endpoint.id];
    if (cached != null) return cached;
    final client = _mcpClientFactory(endpoint);
    _mcpClientCache[endpoint.id] = client;
    _mcpCalls++;
    return client;
  }

  // ─── Observability ───────────────────────────────────────────

  @override
  Stream<SubstrateEvent> events() => _eventBus.events();

  @override
  SubstrateStats stats() {
    return SubstrateStats(
      snapshotAt: _now().toUtc(),
      callsPerProvider: Map<String, int>.unmodifiable(_callsPerProvider),
      callsPerRole: Map<String, int>.unmodifiable(_callsPerRole),
      embeddingsComputed: _embeddingsComputed,
      activeCooldowns: _router.cooldownsActive,
      lastRetryAt: _lastRetryAt,
      webSearches: _webSearches,
      webFetches: _webFetches,
      mcpCalls: _mcpCalls,
    );
  }

  // ─── Internal helpers ────────────────────────────────────────

  void _ensureNotClosed(String op) =>
      ensureOpen('InProcessTomBrainSubstrate.$op');

  String _allocateCallId() {
    _callCounter++;
    return 'sub-${_callCounter.toString().padLeft(6, '0')}';
  }

  void _enforceAnchorOrThrow({
    required LlmCallReport report,
    required String roleId,
  }) {
    if (AnchorRegistry.isCurrent(report.anchorHash)) return;
    throw AnchorViolation(
      expected: AnchorRegistry.currentHash,
      actual: report.anchorHash,
      providerId: report.providerId,
      modelId: report.modelId,
      roleId: roleId,
    );
  }

  void _recordCallSuccess({
    required LlmCallReport report,
    required String roleId,
  }) {
    _callsPerProvider.update(
      report.providerId,
      (v) => v + 1,
      ifAbsent: () => 1,
    );
    _callsPerRole.update(
      roleId,
      (v) => v + 1,
      ifAbsent: () => 1,
    );
    if (report.retries > 0) {
      // A non-zero retry count on the surfacing report means the router
      // retried at least once (possibly on the same provider) before this
      // provider stuck. This is a retry signal, not a failover signal:
      // `retries > 0` includes same-provider retries, so the field is
      // named `_lastRetryAt`. A true provider-failover stat lands once the
      // router emits `ProviderFailover` (Q-B.41.2 in
      // `prototype_implementation_questions.md`).
      _lastRetryAt = _now().toUtc();
    }
  }

  void _safeEmit(SubstrateEvent event) {
    if (_eventBus.isClosed) return;
    _eventBus.emit(event);
  }
}
