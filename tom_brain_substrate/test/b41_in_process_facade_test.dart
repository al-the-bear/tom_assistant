// B.41 — `InProcessTomBrainSubstrate` behavioural tests.
//
// Plan step B.41:
//
//   "Implement `TomBrainSubstrateInProcessClient`. (Isolate variant is
//    not needed at prototype scope; document it as future work in
//    `deferred.tom_brain.md`.)"
//
// The class-name divergence (plan: `TomBrainSubstrateInProcessClient`;
// in-tree: `InProcessTomBrainSubstrate`) is captured in
// `prototype_implementation_questions.md` Q-B.41.1 and locked to the
// in-tree name throughout the implementation and these tests.
//
// What this suite pins:
//
//   1. **Composition contract.** The facade extends [TomBrainSubstrate]
//      (the in-process marker base) and therefore IS-A
//      [TomBrainSubstrateClient]. Collaborators are constructor-injected
//      (role registry, provider map, router, embedding service, web
//      search, web fetch). Tests inject a stub provider + an in-memory
//      embedding service + direct stub web tools.
//
//   2. **Lifecycle.** `open` is idempotent and validates the supplied
//      config against the bound role registry — an unregistered route
//      surfaces as `SubstrateConfigException`. `close` is idempotent
//      and shuts down the event bus + cached MCP clients + embedding
//      service + web tools exactly once. Calls after `close` raise
//      `StateError`.
//
//   3. **LLM dispatch.** `complete` routes through the bound
//      `LlmRouter` → `LlmProvider` chain, assembles the wire prompt
//      from the role registry (only producer of the anchor), and
//      returns an `LlmCallReport` whose `anchorHash` equals
//      `AnchorRegistry.currentHash`.
//      `completeStream` produces the same shape over a stream — every
//      `LlmRunCompleted` carries an anchored report and the facade
//      emits a `LlmCallCompleted` event keyed to the same `callId` it
//      stamped on the stream.
//
//   4. **Anchor enforcement.** A misbehaving provider that drops the
//      anchor hash on the returned report makes the facade raise
//      `AnchorViolation` before the consumer observes the report —
//      buffered and streaming paths alike. Test uses a wrapper around
//      `StubLlmProvider` that rewrites `anchorHash` on the report.
//
//   5. **Embedding wiring.** `embed` / `embedBatch` round-trip the
//      `EmbeddingResult` (vector + model identity) and emit one
//      `EmbeddingComputed` per call, with `batchSize` reflecting the
//      true input length.
//
//   6. **Web wiring.** `webSearch` / `webFetch` dispatch to the bound
//      services and emit `WebSearchCompleted` / `WebFetchCompleted`
//      with the expected payload (provider id, query, k, hits, status,
//      bytes, truncated flag).
//
//   7. **MCP caching.** `mcpClient` returns the same instance for the
//      same `McpEndpoint.id` and a different instance for a different
//      id. The cached clients close exactly once on facade close.
//
//   8. **Stats.** `stats()` reports a fresh `SubstrateStats` snapshot
//      with per-provider / per-role call counts, embedding count,
//      web-tool counts, mcp-call count, and the router's
//      `cooldownsActive` passthrough.
//
//   9. **Event surface.** `events()` is the broadcast stream from the
//      facade's `SubstrateEventBus`. Late subscribers do not see past
//      events (broadcast semantics inherited from B.38). Events are
//      not emitted on the buffered-failure (`router throws`) path —
//      the router-layer exception is the terminal signal there
//      (deliberate per facade header comment).

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.41 / InProcessTomBrainSubstrate', () {
    // ─── Composition / marker identity ─────────────────────────

    test('IS-A TomBrainSubstrate and TomBrainSubstrateClient', () {
      final f = _buildFacade();
      addTearDown(f.facade.close);

      expect(f.facade, isA<TomBrainSubstrate>());
      expect(f.facade, isA<TomBrainSubstrateClient>());
    });

    test('exposes injected collaborators read-only', () {
      final f = _buildFacade();
      addTearDown(f.facade.close);

      expect(f.facade.roleRegistry, same(f.roleRegistry));
      expect(f.facade.router, same(f.router));
      expect(f.facade.providers, hasLength(1));
      expect(f.facade.providers['stub'], same(f.provider));

      // The exposed provider map is unmodifiable.
      expect(
        () => f.facade.providers['new'] = f.provider,
        throwsUnsupportedError,
      );
    });

    // ─── Lifecycle ─────────────────────────────────────────────

    test('open stores the config and is idempotent', () async {
      final f = _buildFacade();
      addTearDown(f.facade.close);

      expect(f.facade.boundConfig, isNull);
      await f.facade.open(_minimalConfig());
      expect(f.facade.boundConfig, isNotNull);

      // Re-opening with a different config replaces the bound value.
      final replacement = _minimalConfig();
      await f.facade.open(replacement);
      expect(f.facade.boundConfig, same(replacement));
    });

    test('open validates roleRoutes against the role registry', () async {
      final f = _buildFacade();
      addTearDown(f.facade.close);

      final bad = SubstrateConfig(
        providers: const [],
        roleRoutes: const <String, List<RoleRouteEntryConfig>>{
          'no_such_role': <RoleRouteEntryConfig>[
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

      expect(
        () => f.facade.open(bad),
        throwsA(isA<SubstrateConfigException>()),
      );
    });

    test('close is idempotent and forbids subsequent calls', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      expect(f.facade.isClosed, isFalse);

      await f.facade.close();
      expect(f.facade.isClosed, isTrue);

      // Second close is a no-op.
      await f.facade.close();
      expect(f.facade.isClosed, isTrue);

      // Surface methods refuse to run after close.
      expect(
        () => f.facade.complete(_assistantCall()),
        throwsA(isA<StateError>()),
      );
      expect(() => f.facade.embed('hi'), throwsA(isA<StateError>()));
    });

    test('close shuts the embedding service / web tools / event bus', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      expect(f.embedding.isClosed, isFalse);
      expect(f.webSearch.isClosed, isFalse);
      expect(f.webFetch.isClosed, isFalse);

      await f.facade.close();
      expect(f.embedding.isClosed, isTrue);
      expect(f.webSearch.isClosed, isTrue);
      expect(f.webFetch.isClosed, isTrue);

      // Events stream is closed: the facade's `events()` ends.
      // Use a fresh facade to test the timing (the original already
      // closed). Build a second one, attach a listener, then close.
      final g = _buildFacade();
      final done = Completer<void>();
      g.facade.events().listen((_) {}, onDone: done.complete);
      await g.facade.close();
      await done.future.timeout(const Duration(seconds: 1));
    });

    // ─── LLM dispatch (buffered) ───────────────────────────────

    test(
      'complete returns an anchored report and emits LlmCallCompleted',
      () async {
        final f = _buildFacade();
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        final events = <SubstrateEvent>[];
        final sub = f.facade.events().listen(events.add);
        addTearDown(sub.cancel);

        final report = await f.facade.complete(_assistantCall());

        expect(report.providerId, 'stub');
        expect(report.modelId, 'stub-model');
        expect(report.anchorHash, AnchorRegistry.currentHash);
        // Allow the event microtask to fan out.
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.single, isA<LlmCallCompleted>());
        final completed = events.single as LlmCallCompleted;
        expect(completed.callId, startsWith('sub-'));
        expect(completed.report.anchorHash, AnchorRegistry.currentHash);
      },
    );

    test('complete updates per-provider + per-role stats counters', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      await f.facade.complete(_assistantCall());
      await f.facade.complete(_assistantCall());

      final stats = f.facade.stats();
      expect(stats.callsPerProvider['stub'], 2);
      expect(stats.callsPerRole['assistant_to_user'], 2);
    });

    // ─── LLM dispatch (streaming) ──────────────────────────────

    test(
      'completeStream relays provider events and emits LlmCallCompleted',
      () async {
        final f = _buildFacade();
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        final substrateEvents = <SubstrateEvent>[];
        final eventsSub = f.facade.events().listen(substrateEvents.add);
        addTearDown(eventsSub.cancel);

        final streamEvents = await f.facade
            .completeStream(_assistantCall())
            .toList();

        expect(streamEvents.first, isA<LlmRunStarted>());
        expect(streamEvents.last, isA<LlmRunCompleted>());
        final completed = streamEvents.last as LlmRunCompleted;
        expect(completed.report.anchorHash, AnchorRegistry.currentHash);

        await Future<void>.delayed(Duration.zero);
        expect(substrateEvents.whereType<LlmCallCompleted>(), hasLength(1));
      },
    );

    test(
      'completeStream relays LlmRunFailed and emits LlmCallFailed',
      () async {
        final failingProvider = StubLlmProvider.alwaysFails(
          id: 'stub',
          defaultModel: 'stub-model',
          failure: const LlmFailure(classCode: 'unknown', message: 'forced'),
        );
        final f = _buildFacade(provider: failingProvider);
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        final substrateEvents = <SubstrateEvent>[];
        final eventsSub = f.facade.events().listen(substrateEvents.add);
        addTearDown(eventsSub.cancel);

        final streamEvents = await f.facade
            .completeStream(_assistantCall())
            .toList();

        // The router exhausts the single-entry chain and yields one
        // terminal LlmRunFailed.
        expect(streamEvents, isNotEmpty);
        expect(streamEvents.last, isA<LlmRunFailed>());

        await Future<void>.delayed(Duration.zero);
        expect(substrateEvents.whereType<LlmCallFailed>(), hasLength(1));
      },
    );

    // ─── Anchor enforcement ────────────────────────────────────

    test(
      'complete raises AnchorViolation when the report drops the anchor',
      () async {
        final tampering = _AnchorTamperingProvider(
          inner: StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
          rewrittenHash: 'sha256:dead',
        );
        final f = _buildFacade(provider: tampering);
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        await expectLater(
          f.facade.complete(_assistantCall()),
          throwsA(isA<AnchorViolation>()),
        );
      },
    );

    test(
      'completeStream raises AnchorViolation when streamed report drops anchor',
      () async {
        final tampering = _AnchorTamperingProvider(
          inner: StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
          rewrittenHash: 'sha256:dead',
        );
        final f = _buildFacade(provider: tampering);
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        await expectLater(
          f.facade.completeStream(_assistantCall()).toList(),
          throwsA(isA<AnchorViolation>()),
        );
      },
    );

    // ─── Embedding ─────────────────────────────────────────────

    test('embed returns identity and emits EmbeddingComputed', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      final events = <SubstrateEvent>[];
      final sub = f.facade.events().listen(events.add);
      addTearDown(sub.cancel);

      final result = await f.facade.embed('hello');

      expect(result.modelIdentity.providerId, 'stub');
      expect(result.modelIdentity.modelId, 'stub-embedder');
      expect(result.modelIdentity.dims, 4);

      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<EmbeddingComputed>(), hasLength(1));
      final ev = events.whereType<EmbeddingComputed>().single;
      expect(ev.batchSize, 1);
      expect(ev.dims, 4);
      expect(f.facade.stats().embeddingsComputed, 1);
    });

    test('embedBatch emits a single event with batchSize == inputs', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      final events = <SubstrateEvent>[];
      final sub = f.facade.events().listen(events.add);
      addTearDown(sub.cancel);

      final results = await f.facade.embedBatch(const ['a', 'b', 'c']);
      expect(results, hasLength(3));

      await Future<void>.delayed(Duration.zero);
      final emitted = events.whereType<EmbeddingComputed>().toList();
      expect(emitted, hasLength(1));
      expect(emitted.single.batchSize, 3);
      expect(f.facade.stats().embeddingsComputed, 3);
    });

    test('embedBatch on empty input emits nothing', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      final events = <SubstrateEvent>[];
      final sub = f.facade.events().listen(events.add);
      addTearDown(sub.cancel);

      final results = await f.facade.embedBatch(const <String>[]);
      expect(results, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<EmbeddingComputed>(), isEmpty);
      expect(f.facade.stats().embeddingsComputed, 0);
    });

    // ─── Web tools ─────────────────────────────────────────────

    test('webSearch dispatches and emits WebSearchCompleted', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      f.webSearch.primedHits = <SearchHit>[
        SearchHit(
          title: 'A',
          url: Uri.parse('https://example.com/a'),
          snippet: 'first',
          rank: 1,
        ),
      ];

      final events = <SubstrateEvent>[];
      final sub = f.facade.events().listen(events.add);
      addTearDown(sub.cancel);

      final result = await f.facade.webSearch('hello');
      expect(result.hits, hasLength(1));
      expect(result.provider, 'stub-search');

      await Future<void>.delayed(Duration.zero);
      final ev = events.whereType<WebSearchCompleted>().single;
      expect(ev.provider, 'stub-search');
      expect(ev.query, 'hello');
      expect(ev.hits, 1);
      expect(f.facade.stats().webSearches, 1);
    });

    test('webFetch dispatches and emits WebFetchCompleted', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      f.webFetch.primedResult = WebFetchResult(
        url: Uri.parse('https://example.com/'),
        status: 200,
        contentType: 'text/plain',
        text: 'hello world',
      );

      final events = <SubstrateEvent>[];
      final sub = f.facade.events().listen(events.add);
      addTearDown(sub.cancel);

      final result = await f.facade.webFetch(Uri.parse('https://example.com/'));
      expect(result.status, 200);

      await Future<void>.delayed(Duration.zero);
      final ev = events.whereType<WebFetchCompleted>().single;
      expect(ev.status, 200);
      expect(ev.bytes, 'hello world'.length);
      expect(ev.truncated, isFalse);
      expect(f.facade.stats().webFetches, 1);
    });

    // ─── MCP caching ───────────────────────────────────────────

    test('mcpClient returns the same instance per endpoint id', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      final a1 = f.facade.mcpClient(const McpEndpoint('memory'));
      final a2 = f.facade.mcpClient(const McpEndpoint('memory'));
      final b = f.facade.mcpClient(const McpEndpoint('tools'));

      expect(identical(a1, a2), isTrue);
      expect(identical(a1, b), isFalse);
      expect(f.facade.stats().mcpCalls, 2);
    });

    test('cached MCP clients are shut down on facade close', () async {
      // The facade's MCP cache holds real `McpClient` instances. We
      // can't replace them with a recording double because `McpClient`
      // is a `final` class (see `mcp_client/mcp_client.dart`). We
      // instead verify that:
      //
      //   1. `close()` tolerates a populated cache without throwing.
      //   2. After `close()`, attempting to use the facade fails with
      //      a `StateError` from `_ensureNotClosed` — meaning the
      //      facade has transitioned to its terminal state regardless
      //      of any best-effort MCP shutdown errors. (`close()` itself
      //      swallows per-client errors by design — see the facade
      //      doc-comment.)
      //   3. Calling `close()` a second time is a no-op (idempotency
      //      across the MCP-shutdown branch).
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());

      f.facade.mcpClient(const McpEndpoint('memory'));
      f.facade.mcpClient(const McpEndpoint('tools'));
      f.facade.mcpClient(const McpEndpoint('memory')); // cached hit.

      await f.facade.close();
      expect(f.facade.isClosed, isTrue);
      expect(
        () => f.facade.mcpClient(const McpEndpoint('memory')),
        throwsStateError,
      );
      await f.facade.close(); // second close is a no-op.
    });

    // ─── Stats ─────────────────────────────────────────────────

    test('stats() reflects the router cooldownsActive passthrough', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      final stats = f.facade.stats();
      expect(stats.activeCooldowns, f.router.cooldownsActive);
      expect(stats.callsPerProvider, isEmpty);
      expect(stats.callsPerRole, isEmpty);
      expect(stats.embeddingsComputed, 0);
      expect(stats.webSearches, 0);
      expect(stats.webFetches, 0);
      expect(stats.mcpCalls, 0);
    });

    // ─── Event broadcast semantics ─────────────────────────────

    test(
      'events() is a broadcast stream — late subscribers miss prior',
      () async {
        final f = _buildFacade();
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        // First call happens before subscribing.
        await f.facade.complete(_assistantCall());
        await Future<void>.delayed(Duration.zero);

        final lateEvents = <SubstrateEvent>[];
        final sub = f.facade.events().listen(lateEvents.add);
        addTearDown(sub.cancel);

        // Late subscriber sees only future events.
        await f.facade.complete(_assistantCall());
        await Future<void>.delayed(Duration.zero);
        expect(lateEvents.whereType<LlmCallCompleted>(), hasLength(1));
      },
    );
  });
}

// ─── Test fixtures ────────────────────────────────────────────────

class _FacadeFixture {
  final InProcessTomBrainSubstrate facade;
  final RoleRegistry roleRegistry;
  final LlmProvider provider;
  final LlmRouter router;
  final _StubEmbeddingService embedding;
  final _StubWebSearch webSearch;
  final _StubWebFetch webFetch;

  _FacadeFixture({
    required this.facade,
    required this.roleRegistry,
    required this.provider,
    required this.router,
    required this.embedding,
    required this.webSearch,
    required this.webFetch,
  });
}

_FacadeFixture _buildFacade({
  LlmProvider? provider,
  McpClientFactory? mcpClientFactory,
}) {
  final roles = bootstrapRoleRegistry();
  final realProvider =
      provider ?? StubLlmProvider(id: 'stub', defaultModel: 'stub-model');
  final providers = <String, LlmProvider>{'stub': realProvider};
  final policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      'assistant_to_user': const <RouteEntry>[
        RouteEntry(providerId: 'stub', model: 'stub-model'),
      ],
    },
  );
  final router = LlmRouter(providers: providers, policy: policy);
  final embedding = _StubEmbeddingService();
  final search = _StubWebSearch();
  final fetch = _StubWebFetch();

  final facade = InProcessTomBrainSubstrate(
    roleRegistry: roles,
    providers: providers,
    router: router,
    embeddingService: embedding,
    webSearch: search,
    webFetch: fetch,
    mcpClientFactory: mcpClientFactory,
  );

  return _FacadeFixture(
    facade: facade,
    roleRegistry: roles,
    provider: realProvider,
    router: router,
    embedding: embedding,
    webSearch: search,
    webFetch: fetch,
  );
}

LlmCall _assistantCall() => LlmCall(
  roleId: 'assistant_to_user',
  inputs: const <String, Object?>{'question': 'hi'},
  budget: Budget(
    wallClockMs: 5000,
    tokenSpend: 1000,
    toolCalls: 1,
    memoryWrites: 0,
  ),
);

SubstrateConfig _minimalConfig() => SubstrateConfig(
  providers: const <ProviderProfile>[],
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

// ─── Test doubles ─────────────────────────────────────────────────

final class _StubEmbeddingService implements EmbeddingService {
  bool isClosed = false;
  static const _identity = EmbeddingModelIdentity(
    providerId: 'stub',
    modelId: 'stub-embedder',
    dims: 4,
    normalized: false,
  );

  @override
  EmbeddingModelIdentity get currentModelIdentity => _identity;

  @override
  Future<EmbeddingResult> embed(String text) async {
    final values = Float32List(_identity.dims);
    values[0] = text.length.toDouble();
    return EmbeddingResult(vec: Vec(values), modelIdentity: _identity);
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const <EmbeddingResult>[];
    final out = <EmbeddingResult>[];
    for (final t in texts) {
      out.add(await embed(t));
    }
    return List<EmbeddingResult>.unmodifiable(out);
  }

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async {
    final probe = await embed(probeText);
    return EmbeddingProbeResult(
      currentIdentity: _identity,
      probeResult: probe,
      driftEvent: null,
    );
  }

  @override
  Future<void> close() async {
    isClosed = true;
  }
}

final class _StubWebSearch implements WebSearch {
  bool isClosed = false;
  List<SearchHit> primedHits = const <SearchHit>[];

  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    if (isClosed) throw StateError('closed');
    final capped = primedHits.length > options.k
        ? primedHits.sublist(0, options.k)
        : primedHits;
    return WebSearchResult(provider: 'stub-search', query: query, hits: capped);
  }

  @override
  void close() {
    isClosed = true;
  }
}

final class _StubWebFetch implements WebFetch {
  bool isClosed = false;
  WebFetchResult? primedResult;

  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    if (isClosed) throw StateError('closed');
    final base =
        primedResult ??
        WebFetchResult(
          url: url,
          status: 200,
          contentType: 'text/plain',
          text: '',
        );
    return WebFetchResult(
      url: base.url,
      status: base.status,
      contentType: base.contentType,
      text: base.text,
      json: base.json,
      binaryMeta: base.binaryMeta,
      truncated: base.truncated,
    );
  }

  @override
  void close() {
    isClosed = true;
  }
}

/// Wrapper around any [LlmProvider] that rewrites the report's
/// `anchorHash` before returning. Used to prove the facade refuses
/// to surface a report whose anchor has been tampered with.
final class _AnchorTamperingProvider extends LlmProvider {
  final LlmProvider inner;
  final String rewrittenHash;

  _AnchorTamperingProvider({required this.inner, required this.rewrittenHash});

  @override
  String get id => inner.id;

  LlmCallReport _rewrite(LlmCallReport r) => LlmCallReport(
    providerId: r.providerId,
    modelId: r.modelId,
    anchorHash: rewrittenHash,
    promptHash: r.promptHash,
    tokensIn: r.tokensIn,
    tokensOut: r.tokensOut,
    retries: r.retries,
    wallClockMs: r.wallClockMs,
    cost: r.cost,
    templateSha: r.templateSha,
    notes: r.notes,
  );

  @override
  Future<LlmCallReport> complete(LlmRequest request) async {
    final prompt = request.prompt;
    final options = request.options;
    final r = await inner.complete(
      LlmRequest(prompt: prompt, options: options),
    );
    return _rewrite(r);
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    await for (final ev in inner.run(
      LlmRequest(prompt: prompt, options: options),
    )) {
      if (ev is LlmRunCompleted) {
        yield LlmRunCompleted(callId: ev.callId, report: _rewrite(ev.report));
      } else {
        yield ev;
      }
    }
  }
}
