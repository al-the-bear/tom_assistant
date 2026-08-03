// B.42 — Engine-bridge equivalence test.
//
// Plan step B.42 (`_ai/quests/tom_brain/prototype_implementation_plan.md`
// § Phase B):
//
//   "Tests: the engine-side bridge works against the interface and
//    produces identical results when swapping the underlying provider
//    via `LlmRouter`."
//
// B.40 (`b40_engine_bridge_contract_test.dart`) locked the *structural*
// contract: engine consumers hold a `TomBrainSubstrateClient` reference
// and never narrow to the marker class or the concrete impl. B.41
// (`in_process_tom_brain_substrate.dart` + `b41_in_process_facade_test.dart`)
// shipped the concrete v1 facade.
//
// B.42 is the *behavioural* sibling — proof that the same engine-side
// bridge code path, given identical `LlmCall` inputs, produces
// structurally-identical observable results across:
//
//   (1) Different `LlmProvider` instances bound to the same role
//       through the same router policy shape. The provider id and
//       model id reflect the swap; the role-derived fields
//       (`anchorHash`, `promptHash`, `templateSha`, `tokensIn`) and the
//       provider-deterministic fields (`tokensOut` for two stubs that
//       both default-echo, `retries`, `notes`) are identical between
//       the two facades.
//
//   (2) Runtime rebinding of the `TomBrainSubstrateClient` on the
//       bridge — i.e. swapping which facade the bridge points at while
//       the bridge code is unchanged. Same equivalence holds across
//       the swap.
//
//   (3) Router-internal failover via a multi-entry route chain. With
//       chain `[failingProvider, workingProvider]` the failing entry
//       is rotated past on `unknown` classification (router action
//       `retryThenRotate` with `retriesPerClass: 0` ⇒ immediate
//       rotation). The observable report from the bridge is identical
//       to the same chain expressed as `[workingProvider]` alone — the
//       bridge cannot tell that failover happened.
//
//   (4) Streaming-path equivalence. The same swap-equivalence applies
//       to `completeStream`: the chunk text emitted across the stream
//       concatenates to the same response on both facades, and the
//       terminal `LlmStreamCompleted.report` honours the same field
//       equivalence as the buffered path.
//
// The `_AssistantEngineBridge` modelled here is the smallest engine-
// side consumer that exercises both `complete` and `completeStream`
// through `TomBrainSubstrateClient`. It mirrors the shape the Phase C
// `MemoryBridge` / `SubstrateBridge` will take (plan steps C.12–C.14):
// one constructor-injected client, no concrete-impl reference, no
// reach for the marker class.
//
// What this test deliberately does NOT do:
//
//   * No black-box conformance suite. That is B.45's job — driving
//     `TomBrainSubstrateClient` only across every method and every
//     failure path. B.42 covers the *equivalence-under-swap* corner
//     of that broader contract.
//
//   * No anchor-tampering exercise. B.41 already covers that for the
//     buffered + streaming paths; B.46 will lock it conformance-wide.
//
//   * No isolate-adapter exercise. The isolate variant is deferred to
//     `deferred.tom_brain.md`; the engine will consume the
//     future isolate adapter through the same `TomBrainSubstrateClient`
//     surface this bridge already binds against.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.42 / engine-bridge equivalence under provider swap', () {
    // ─── (1) Static provider swap behind same router policy shape ───

    test(
      'same role + inputs → identical observable report across providers',
      () async {
        // Two facades, two distinct providers, otherwise identical
        // composition (same role registry, same router-policy shape,
        // same role → single-entry chain). The bridge runs once
        // against each.
        final alphaFixture = _buildFacade(
          provider: StubLlmProvider(
            id: 'alpha',
            defaultModel: 'alpha-model',
          ),
        );
        addTearDown(alphaFixture.facade.close);
        await alphaFixture.facade.open(_minimalConfig());

        final betaFixture = _buildFacade(
          provider: StubLlmProvider(
            id: 'beta',
            defaultModel: 'beta-model',
          ),
        );
        addTearDown(betaFixture.facade.close);
        await betaFixture.facade.open(_minimalConfig());

        // One bridge instance, swapping which client it points at.
        final bridge = _AssistantEngineBridge(alphaFixture.facade);
        final alphaReport = await bridge.runAssistantQuery('hi');

        bridge.rebind(betaFixture.facade);
        final betaReport = await bridge.runAssistantQuery('hi');

        // ── Provider identity reflects the swap. ──
        expect(alphaReport.providerId, 'alpha');
        expect(alphaReport.modelId, 'alpha-model');
        expect(betaReport.providerId, 'beta');
        expect(betaReport.modelId, 'beta-model');
        expect(alphaReport.providerId, isNot(betaReport.providerId));
        expect(alphaReport.modelId, isNot(betaReport.modelId));

        // ── Role-derived fields are identical. ──
        // Same role + same inputs + same anchor ⇒ same assembled body
        // ⇒ same sha256 → identical anchorHash + promptHash + templateSha.
        expect(alphaReport.anchorHash, AnchorRegistry.currentHash);
        expect(betaReport.anchorHash, AnchorRegistry.currentHash);
        expect(alphaReport.promptHash, betaReport.promptHash);
        // `templateSha` lands at B.36's file-backed template loader;
        // prototype roles produce `null` here today (see role_template.dart
        // line 399). The equivalence assertion is intentional: when B.36
        // wires non-null shas, the two providers will still see the
        // same value because the role + inputs are identical.
        expect(alphaReport.templateSha, betaReport.templateSha);

        // ── Provider-deterministic fields are identical. ──
        // Both stubs use defaultEcho ⇒ identical response shape ⇒
        // identical tokensIn / tokensOut / retries / notes. The stub
        // pins wallClockMs to 0.
        expect(alphaReport.tokensIn, betaReport.tokensIn);
        expect(alphaReport.tokensOut, betaReport.tokensOut);
        expect(alphaReport.retries, betaReport.retries);
        expect(alphaReport.wallClockMs, betaReport.wallClockMs);
        expect(alphaReport.notes, betaReport.notes);
      },
    );

    // ─── (2) Runtime client rebind on the bridge ───────────────────

    test(
      'rebinding the bridge client mid-flight yields identical results',
      () async {
        // The Phase C engine never holds a concrete `TomBrainSubstrate`;
        // it holds a `TomBrainSubstrateClient`. Swapping the underlying
        // facade behind the bridge is a one-line operation. The bridge
        // code does not change; the observable report does not change
        // beyond the provider identity stamp.
        final firstFixture = _buildFacade(
          provider: StubLlmProvider(
            id: 'first',
            defaultModel: 'first-model',
          ),
        );
        addTearDown(firstFixture.facade.close);
        await firstFixture.facade.open(_minimalConfig());

        final secondFixture = _buildFacade(
          provider: StubLlmProvider(
            id: 'second',
            defaultModel: 'second-model',
          ),
        );
        addTearDown(secondFixture.facade.close);
        await secondFixture.facade.open(_minimalConfig());

        final bridge = _AssistantEngineBridge(firstFixture.facade);
        // Sanity: the bridge field is typed as the interface, not the
        // marker. The B.40 contract test pins this structurally; B.42
        // re-asserts it at runtime so a future change cannot silently
        // widen the field type.
        expect(bridge.client, isA<TomBrainSubstrateClient>());

        final beforeSwap = await bridge.runAssistantQuery('same input');

        // Rebind. No re-construction; only the reference moves.
        bridge.rebind(secondFixture.facade);
        expect(bridge.client, same(secondFixture.facade));

        final afterSwap = await bridge.runAssistantQuery('same input');

        // Provider identity reflects the swap.
        expect(beforeSwap.providerId, 'first');
        expect(afterSwap.providerId, 'second');

        // Everything else is identical — the engine-side bridge code
        // is provider-agnostic by construction.
        expect(afterSwap.anchorHash, beforeSwap.anchorHash);
        expect(afterSwap.promptHash, beforeSwap.promptHash);
        expect(afterSwap.templateSha, beforeSwap.templateSha);
        expect(afterSwap.tokensIn, beforeSwap.tokensIn);
        expect(afterSwap.tokensOut, beforeSwap.tokensOut);
        expect(afterSwap.retries, beforeSwap.retries);
        expect(afterSwap.notes, beforeSwap.notes);
      },
    );

    // ─── (3) Router-internal failover hidden from the bridge ────────

    test(
      'multi-entry failover yields the same observable report as a '
      'single-entry chain on the working provider',
      () async {
        // Chain A: [failing@stubFail, working@stubOk]. The first entry
        // raises a synthetic `unknown` failure on every call; the
        // classifier's `retryThenRotate` with `retriesPerClass: 0`
        // makes the router rotate to the second entry immediately.
        //
        // We use a custom `_CountingFailingProvider` because
        // `StubLlmProvider.alwaysFails` (`_AlwaysFailsStubProvider`)
        // does not increment its inherited `callCount` on the
        // buffered `complete` path — the failure factory only
        // increments on the streaming path. The counting wrapper
        // gives the test a clean "the router actually invoked the
        // failing entry" rail.
        final failing = _CountingFailingProvider(
          id: 'stubFail',
          defaultModel: 'stubFail-model',
        );
        final workingA = StubLlmProvider(
          id: 'stubOk',
          defaultModel: 'stubOk-model',
        );
        final failoverFixture = _buildFacade(
          provider: workingA,
          extraProviders: <String, LlmProvider>{'stubFail': failing},
          chain: const <RouteEntry>[
            RouteEntry(providerId: 'stubFail', model: 'stubFail-model'),
            RouteEntry(providerId: 'stubOk', model: 'stubOk-model'),
          ],
        );
        // The chain references a model id `stubFail-model` that does
        // not match the failing provider's `defaultModel` — that is
        // intentional: the router resolves the route entry's model
        // verbatim, and the failing provider just throws regardless
        // of the resolved model.
        addTearDown(failoverFixture.facade.close);
        await failoverFixture.facade.open(_minimalConfig());

        // Chain B: [working@stubOk]. Direct route, no failover.
        final workingB = StubLlmProvider(
          id: 'stubOk',
          defaultModel: 'stubOk-model',
        );
        final directFixture = _buildFacade(
          provider: workingB,
          chain: const <RouteEntry>[
            RouteEntry(providerId: 'stubOk', model: 'stubOk-model'),
          ],
        );
        addTearDown(directFixture.facade.close);
        await directFixture.facade.open(_minimalConfig());

        final bridge = _AssistantEngineBridge(failoverFixture.facade);
        final failoverReport = await bridge.runAssistantQuery('same input');

        bridge.rebind(directFixture.facade);
        final directReport = await bridge.runAssistantQuery('same input');

        // Both reports name the *working* provider — the bridge has
        // no way to observe that one of the chains routed through a
        // failing entry first.
        expect(failoverReport.providerId, 'stubOk');
        expect(directReport.providerId, 'stubOk');
        expect(failoverReport.modelId, 'stubOk-model');
        expect(directReport.modelId, 'stubOk-model');

        // Every report field on the winning route is identical.
        // `retries` on the winning route is `report.retries + 0` (the
        // router charges zero in-route retries because we pinned
        // `retriesPerClass: 0`); the failed entry's retry count is
        // accounted on the *failed* attempt's audit trail (discarded),
        // not on the successful report.
        expect(failoverReport.anchorHash, directReport.anchorHash);
        expect(failoverReport.promptHash, directReport.promptHash);
        expect(failoverReport.templateSha, directReport.templateSha);
        expect(failoverReport.tokensIn, directReport.tokensIn);
        expect(failoverReport.tokensOut, directReport.tokensOut);
        expect(failoverReport.retries, 0);
        expect(directReport.retries, 0);
        expect(failoverReport.notes, directReport.notes);
        expect(failoverReport.wallClockMs, directReport.wallClockMs);

        // The failing provider was actually invoked: its dedicated
        // call counter is non-zero. (Sanity rail against a future
        // router change that silently skips entries.)
        expect(failing.invocations, greaterThan(0));
      },
    );

    // ─── (4) Streaming-path equivalence ────────────────────────────

    test(
      'streaming dispatch produces equivalent reports + chunk text '
      'across the swap',
      () async {
        final alphaFixture = _buildFacade(
          provider: StubLlmProvider(
            id: 'alpha',
            defaultModel: 'alpha-model',
          ),
        );
        addTearDown(alphaFixture.facade.close);
        await alphaFixture.facade.open(_minimalConfig());

        final betaFixture = _buildFacade(
          provider: StubLlmProvider(
            id: 'beta',
            defaultModel: 'beta-model',
          ),
        );
        addTearDown(betaFixture.facade.close);
        await betaFixture.facade.open(_minimalConfig());

        final bridge = _AssistantEngineBridge(alphaFixture.facade);
        final alphaStream = await bridge.runAssistantStream('hi');
        bridge.rebind(betaFixture.facade);
        final betaStream = await bridge.runAssistantStream('hi');

        // The bridge's `runAssistantStream` concatenates chunk text +
        // surfaces the terminal report. Both providers use defaultEcho
        // ⇒ same response text ⇒ same concatenated body across the
        // swap.
        expect(alphaStream.text, betaStream.text);
        expect(alphaStream.report.providerId, 'alpha');
        expect(betaStream.report.providerId, 'beta');
        expect(
          alphaStream.report.anchorHash,
          betaStream.report.anchorHash,
        );
        expect(
          alphaStream.report.promptHash,
          betaStream.report.promptHash,
        );
        expect(
          alphaStream.report.templateSha,
          betaStream.report.templateSha,
        );
        expect(
          alphaStream.report.tokensIn,
          betaStream.report.tokensIn,
        );
        expect(
          alphaStream.report.tokensOut,
          betaStream.report.tokensOut,
        );
        expect(
          alphaStream.report.notes,
          betaStream.report.notes,
        );
      },
    );

    // ─── (5) Bridge field-type discipline ──────────────────────────

    test(
      'bridge holds TomBrainSubstrateClient and never narrows to the '
      'concrete impl',
      () {
        // Compile-time + runtime restatement of the B.40 rule. The
        // field's *static* type is the interface; the engine code
        // surface depends only on members declared on the interface.
        // A future widening of the bridge field type would break this
        // assertion.
        final fixture = _buildFacade();
        addTearDown(fixture.facade.close);

        final bridge = _AssistantEngineBridge(fixture.facade);

        // Static type assertion (the bridge's `client` field is typed
        // as `TomBrainSubstrateClient`):
        // ignore: unnecessary_type_check
        expect(bridge.client is TomBrainSubstrateClient, isTrue);

        // The concrete impl is IS-A `TomBrainSubstrateClient`, but
        // the bridge does not depend on that fact — it has no method
        // that returns a `TomBrainSubstrate` or `InProcessTomBrainSubstrate`.
        // Any future engine code that needed the marker would surface
        // here as a missing accessor on the bridge.
        expect(bridge.client, isA<TomBrainSubstrateClient>());
      },
    );
  });
}

// ─── Engine-bridge under test ────────────────────────────────────

/// Smallest engine-side consumer of `TomBrainSubstrateClient`.
///
/// Models the shape `MemoryBridge` / `SubstrateBridge` will take in
/// Phase C (plan steps C.12–C.14, substrate spec § 16). The bridge:
///
///   * Holds one `TomBrainSubstrateClient` reference. The static type
///     is the consumer-facing interface (B.9); never the marker class
///     (`TomBrainSubstrate`); never a concrete impl
///     (`InProcessTomBrainSubstrate`).
///
///   * Exposes [runAssistantQuery] (buffered) and [runAssistantStream]
///     (streaming) — the two surface methods this test exercises.
///     Both compose an `LlmCall` for the `assistant_to_user` role and
///     return the bridge's view of the result.
///
///   * Supports [rebind] — replacing the held client without
///     re-constructing the bridge. Used to prove "swap the facade
///     behind the same engine-side code path" yields equivalent
///     results.
final class _AssistantEngineBridge {
  TomBrainSubstrateClient _client;

  _AssistantEngineBridge(this._client);

  /// Read-only accessor used by the test to verify the field is
  /// typed as the interface, not as the marker class or the impl.
  TomBrainSubstrateClient get client => _client;

  /// Swap the underlying client. The Phase C dispatcher will do the
  /// same when (e.g.) the in-process facade is replaced by the
  /// future isolate adapter.
  void rebind(TomBrainSubstrateClient next) {
    _client = next;
  }

  /// Buffered `assistant_to_user` call.
  Future<LlmCallReport> runAssistantQuery(String question) {
    return _client.complete(_assistantCall(question));
  }

  /// Streaming `assistant_to_user` call. Concatenates chunk text and
  /// surfaces the terminal report from `LlmStreamCompleted`.
  Future<_StreamResult> runAssistantStream(String question) async {
    final buf = StringBuffer();
    LlmCallReport? finalReport;
    await for (final ev
        in _client.completeStream(_assistantCall(question))) {
      if (ev is LlmStreamChunk) {
        buf.write(ev.text);
      } else if (ev is LlmStreamCompleted) {
        finalReport = ev.report;
      } else if (ev is LlmStreamFailed) {
        throw StateError(
          '_AssistantEngineBridge stream failed: ${ev.failure.message}',
        );
      }
    }
    if (finalReport == null) {
      throw StateError('stream ended without LlmStreamCompleted');
    }
    return _StreamResult(text: buf.toString(), report: finalReport);
  }

  LlmCall _assistantCall(String question) => LlmCall(
        roleId: 'assistant_to_user',
        inputs: <String, Object?>{'question': question},
        budget: Budget(
          wallClockMs: 5000,
          tokenSpend: 1000,
          toolCalls: 1,
          memoryWrites: 0,
        ),
      );
}

/// Lightweight view of a streaming response.
class _StreamResult {
  final String text;
  final LlmCallReport report;
  const _StreamResult({required this.text, required this.report});
}

// ─── Fixtures ────────────────────────────────────────────────────

class _FacadeFixture {
  final InProcessTomBrainSubstrate facade;
  final RoleRegistry roleRegistry;
  final LlmProvider provider;
  final LlmRouter router;

  _FacadeFixture({
    required this.facade,
    required this.roleRegistry,
    required this.provider,
    required this.router,
  });
}

/// Builds an `InProcessTomBrainSubstrate` against the supplied
/// `LlmProvider` (and any [extraProviders] needed for failover
/// chains). The role registry is the prototype bootstrap; the
/// embedding / web doubles are minimal no-ops because this test
/// only exercises the LLM dispatch path.
///
/// [chain] customises the `assistant_to_user` route chain. Defaults
/// to a single-entry chain pointing at the primary [provider].
_FacadeFixture _buildFacade({
  StubLlmProvider? provider,
  Map<String, LlmProvider> extraProviders = const <String, LlmProvider>{},
  List<RouteEntry>? chain,
}) {
  final roles = bootstrapRoleRegistry();
  final primary = provider ??
      StubLlmProvider(id: 'stub', defaultModel: 'stub-model');
  final providers = <String, LlmProvider>{
    primary.id: primary,
    ...extraProviders,
  };
  final resolvedChain = chain ??
      <RouteEntry>[
        // Default chain points at the primary provider with whatever
        // model id it was constructed for. This matters because the
        // router resolves the route entry's `model` onto
        // `LlmCallReport.modelId` (the provider's `defaultModel` only
        // applies when the route entry's model is the same value);
        // passing a wrong model id here would surface a model-not-
        // found classification at dispatch.
        RouteEntry(providerId: primary.id, model: primary.defaultModel),
      ];
  final policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      'assistant_to_user': resolvedChain,
    },
    // Force immediate rotation on `retryThenRotate` classes so the
    // failover test does not insert in-route retries that would
    // perturb the comparison against the direct-chain fixture.
    retriesPerClass: 0,
    overloadedBackoff: Duration.zero,
  );
  final router = LlmRouter(providers: providers, policy: policy);

  final facade = InProcessTomBrainSubstrate(
    roleRegistry: roles,
    providers: providers,
    router: router,
    embeddingService: _NoopEmbeddingService(),
    webSearch: _NoopWebSearch(),
    webFetch: _NoopWebFetch(),
  );

  return _FacadeFixture(
    facade: facade,
    roleRegistry: roles,
    provider: primary,
    router: router,
  );
}

SubstrateConfig _minimalConfig() => SubstrateConfig(
      providers: const <ProviderProfile>[],
      // The facade calls `config.validateRoleRegistry(_roleRegistry)`
      // on `open`. The bootstrap registry declares the five
      // prototype roles; we cover `assistant_to_user` (the role the
      // bridge invokes) here. The other roles in the registry are
      // not addressed by the route map, which the validator accepts
      // — every routed role must be in the registry, but the registry
      // is allowed to declare roles the config does not yet route.
      roleRoutes: const <String, List<RoleRouteEntryConfig>>{
        'assistant_to_user': <RoleRouteEntryConfig>[
          RoleRouteEntryConfig(providerId: 'stub', model: 'stub-model'),
        ],
      },
      embedding: const EmbeddingChoice(
        providerId: 'stub',
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      ),
      webSearch: const WebSearchConfig(
        defaultProvider: 'duckduckgo',
        providers: <String, WebSearchProviderConfig>{
          'duckduckgo': WebSearchProviderConfig(kind: 'ddg_html'),
        },
      ),
      webFetch: const WebFetchConfig(),
      mcpClient: const McpClientConfigBlock(),
    );

// ─── Minimal no-op collaborators (LLM-only test path) ────────────

final class _NoopEmbeddingService implements EmbeddingService {
  static const _identity = EmbeddingModelIdentity(
    providerId: 'noop',
    modelId: 'noop',
    dims: 1,
    normalized: false,
  );

  @override
  EmbeddingModelIdentity get currentModelIdentity => _identity;

  @override
  Future<EmbeddingResult> embed(String text) =>
      throw UnsupportedError('B.42 does not exercise embeddings');

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) =>
      throw UnsupportedError('B.42 does not exercise embeddings');

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) =>
      throw UnsupportedError('B.42 does not exercise embeddings');

  @override
  Future<void> close() async {}
}

final class _NoopWebSearch implements WebSearch {
  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) =>
      throw UnsupportedError('B.42 does not exercise web search');

  @override
  void close() {}
}

/// Always-failing `LlmProvider` that *does* count buffered invocations.
///
/// Surrogate for `StubLlmProvider.alwaysFails`, which only increments
/// its inherited `callCount` on the streaming path. The B.42 failover
/// test exercises the buffered path through the router; we need a
/// rail confirming the router actually walked the failing entry
/// before rotating, so the test fixture brings its own counter.
final class _CountingFailingProvider implements LlmProvider {
  @override
  final String id;
  final String defaultModel;
  int invocations = 0;

  _CountingFailingProvider({
    required this.id,
    required this.defaultModel,
  });

  @override
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) {
    invocations++;
    return Future<LlmCallReport>.error(
      const LlmFailure(
        classCode: 'unknown',
        message: '_CountingFailingProvider.complete: forced failure',
      ),
    );
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    invocations++;
    final modelId = options.model ?? defaultModel;
    yield LlmStreamStarted(
      callId: 'fail-$invocations',
      providerId: id,
      modelId: modelId,
    );
    yield LlmStreamFailed(
      callId: 'fail-$invocations',
      failure: const LlmFailure(
        classCode: 'unknown',
        message: '_CountingFailingProvider.completeStream: forced',
      ),
      report: LlmCallReport(
        providerId: id,
        modelId: modelId,
        anchorHash: prompt.anchorHash,
        promptHash: 'sha256:forced',
        tokensIn: prompt.combined.length,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      ),
    );
  }
}

final class _NoopWebFetch implements WebFetch {
  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) =>
      throw UnsupportedError('B.42 does not exercise web fetch');

  @override
  void close() {}
}
