// B.9 — API surface contract tests.
//
// What this test file is for:
//
//   - Pin every value type and interface declared in
//     `lib/src/api/` against the substrate-spec § 3.1 surface, so
//     a future edit cannot silently drop a field / method without
//     a compile error here.
//   - Prove the sealed sums (`LlmStreamEvent`, `SubstrateEvent`)
//     are exhaustively branchable — i.e. a `switch` on every
//     subtype compiles cleanly under the strict-mode analyzer.
//   - Prove the two-class split (`TomBrainSubstrate implements
//     TomBrainSubstrateClient`) holds at the type level.
//   - Prove the cancellation primitive behaves: `none` is
//     uncancellable; sources fire exactly once; `whenCancelled` on
//     an already-cancelled source resolves immediately.
//   - Prove the substrate-event subtypes serialise through
//     `BrainEvent.toJson` correctly (UTC-only `occurredAt` invariant
//     is inherited from `tom_brain_shared`).
//
// What this test file is NOT for:
//
//   - There are no implementations at B.9. The interface methods
//     are unimplemented; instantiating `TomBrainSubstrateClient`
//     directly is impossible (abstract). Tests that drive the
//     full surface (the spec § 13.2 black-box conformance suite)
//     arrive at plan step B.45 once the in-process facade lands.
//   - No HTTP / network. Same B.8 discipline: every test runs in
//     the test isolate, no external processes, no listeners.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  group('B.9 / api surface', () {
    // ─── Lifecycle + structural typing ──────────────────────────

    test('TomBrainSubstrate implements TomBrainSubstrateClient', () {
      // Compile-time assertion that the marker base class actually
      // implements the consumer-facing contract.
      const TomBrainSubstrate marker = _DummySubstrate();
      // ignore: unnecessary_cast
      final TomBrainSubstrateClient client = marker as TomBrainSubstrateClient;
      expect(client, same(marker));
    });

    test('TomBrainSubstrateClient cannot be instantiated directly', () {
      // The contract is abstract — only subclasses can exist.
      // A direct `TomBrainSubstrateClient()` would not compile;
      // we verify the abstract semantics via the runtime check
      // that the marker subclass passes through identity.
      const TomBrainSubstrate dummy = _DummySubstrate();
      expect(dummy, isA<TomBrainSubstrateClient>());
      expect(dummy, isA<TomBrainSubstrate>());
    });

    // ─── LlmCall + LlmOptions + LlmCallReport ───────────────────

    test('LlmCall freezes the spec § 3.1 fields', () {
      final budget = Budget(
        wallClockMs: 1000,
        tokenSpend: 100,
        toolCalls: 1,
        memoryWrites: 0,
      );

      final call = LlmCall(
        roleId: 'assistant_to_user',
        inputs: const <String, Object?>{'question': 'hi'},
        budget: budget,
      );

      expect(call.roleId, equals('assistant_to_user'));
      expect(call.inputs, equals(<String, Object?>{'question': 'hi'}));
      expect(call.options, same(LlmOptions.empty));
      expect(call.budget, same(budget));
      expect(call.cancellationToken, same(CancellationToken.none));
    });

    test('LlmOptions.empty has documented defaults', () {
      const opts = LlmOptions.empty;
      expect(opts.temperature, isNull);
      expect(opts.maxOutputTokens, isNull);
      expect(opts.stopSequences, isEmpty);
      expect(opts.toolCatalogue, same(ToolCatalogue.empty));
      expect(opts.responseFormat, isNull);
    });

    test('ToolCatalogue tracks empty vs non-empty', () {
      expect(ToolCatalogue.empty.isEmpty, isTrue);
      expect(ToolCatalogue.empty.isNotEmpty, isFalse);

      const tool = ToolDescriptor(
        name: 'web.search',
        description: 'Run a web search.',
        parametersSchema: <String, Object?>{},
      );
      const cat = ToolCatalogue(<ToolDescriptor>[tool]);
      expect(cat.isEmpty, isFalse);
      expect(cat.isNotEmpty, isTrue);
      expect(cat.tools, hasLength(1));
      expect(cat.tools.first.name, equals('web.search'));
    });

    test('LlmCallReport preserves every provenance field', () {
      const report = LlmCallReport(
        providerId: 'ollama:local',
        modelId: 'gemma2:9b',
        anchorHash: 'sha256:anchor',
        promptHash: 'sha256:prompt',
        tokensIn: 12,
        tokensOut: 34,
        retries: 0,
        wallClockMs: 250,
        cost: 0.0012,
        templateSha: 'abc123',
        notes: <String>['response_format downgraded to text'],
      );

      expect(report.providerId, equals('ollama:local'));
      expect(report.modelId, equals('gemma2:9b'));
      expect(report.anchorHash, equals('sha256:anchor'));
      expect(report.promptHash, equals('sha256:prompt'));
      expect(report.tokensIn, equals(12));
      expect(report.tokensOut, equals(34));
      expect(report.retries, equals(0));
      expect(report.wallClockMs, equals(250));
      expect(report.cost, equals(0.0012));
      expect(report.templateSha, equals('abc123'));
      expect(report.notes, equals(<String>['response_format downgraded to text']));
    });

    test('LlmCallReport defaults cost / templateSha / notes', () {
      const report = LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );
      expect(report.cost, isNull);
      expect(report.templateSha, isNull);
      expect(report.notes, isEmpty);
    });

    // ─── LlmStreamEvent sealed sum exhaustiveness ───────────────

    test('LlmStreamEvent variants compose into an exhaustive switch',
        () {
      // The compile-time guarantee is the analyzer treating the
      // switch as exhaustive; this test simply ensures every
      // variant constructs and routes through the switch.
      final events = <LlmStreamEvent>[
        const LlmStreamStarted(
          callId: 'c1',
          providerId: 'p',
          modelId: 'm',
        ),
        const LlmStreamChunk(callId: 'c1', text: 'hello'),
        const LlmStreamToolCallProposed(
          callId: 'c1',
          toolCallId: 't1',
          toolName: 'web.search',
          arguments: <String, Object?>{'q': 'foo'},
        ),
        const LlmStreamCompleted(
          callId: 'c1',
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'h',
            promptHash: 'h',
            tokensIn: 0,
            tokensOut: 0,
            retries: 0,
            wallClockMs: 0,
          ),
        ),
        const LlmStreamFailed(
          callId: 'c1',
          failure: LlmFailure(
            classCode: 'rate_limit',
            message: '429 rate limited',
          ),
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'h',
            promptHash: 'h',
            tokensIn: 0,
            tokensOut: 0,
            retries: 1,
            wallClockMs: 50,
          ),
        ),
      ];

      String classify(LlmStreamEvent e) {
        switch (e) {
          case LlmStreamStarted _:
            return 'started';
          case LlmStreamChunk _:
            return 'chunk';
          case LlmStreamToolCallProposed _:
            return 'tool';
          case LlmStreamCompleted _:
            return 'completed';
          case LlmStreamFailed _:
            return 'failed';
        }
      }

      expect(
        events.map(classify).toList(),
        equals(<String>[
          'started',
          'chunk',
          'tool',
          'completed',
          'failed',
        ]),
      );
    });

    test('LlmFailure carries classCode + optional cause', () {
      const f = LlmFailure(
        classCode: 'network',
        message: 'connection refused',
        cause: 'SocketException',
      );
      expect(f.classCode, equals('network'));
      expect(f.message, equals('connection refused'));
      expect(f.cause, equals('SocketException'));
    });

    // ─── Embedding ───────────────────────────────────────────────

    test('EmbeddingModelIdentity equality is structural', () {
      const a = EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );
      const b = EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );
      const c = EmbeddingModelIdentity(
        providerId: 'ollama:local',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: false,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('EmbeddingResult carries vec + identity', () {
      final vec = Vec.zero(4);
      const id = EmbeddingModelIdentity(
        providerId: 'stub',
        modelId: 'fake-768',
        dims: 768,
        normalized: true,
      );
      final result = EmbeddingResult(vec: vec, modelIdentity: id);
      expect(result.vec, same(vec));
      expect(result.modelIdentity, equals(id));
    });

    // ─── Web tool results ───────────────────────────────────────

    test('SearchHit carries the spec § 8.1 four-field shape', () {
      final hit = SearchHit(
        title: 'Example',
        url: Uri.parse('https://example.invalid/'),
        snippet: 'A page.',
        rank: 1,
      );
      expect(hit.title, equals('Example'));
      expect(hit.url.toString(), equals('https://example.invalid/'));
      expect(hit.snippet, equals('A page.'));
      expect(hit.rank, equals(1));
    });

    test('WebSearchOptions.empty defaults provider null + k=10', () {
      const opts = WebSearchOptions.empty;
      expect(opts.provider, isNull);
      expect(opts.k, equals(10));
    });

    test('WebFetchResult enforces text/json/binaryMeta semantics', () {
      final textResult = WebFetchResult(
        url: Uri.parse('https://example.invalid/page'),
        status: 200,
        contentType: 'text/html',
        text: 'Hello.',
      );
      expect(textResult.text, isNotNull);
      expect(textResult.json, isNull);
      expect(textResult.binaryMeta, isNull);
      expect(textResult.truncated, isFalse);

      final jsonResult = WebFetchResult(
        url: Uri.parse('https://example.invalid/api'),
        status: 200,
        contentType: 'application/json',
        json: <String, Object?>{'ok': true},
      );
      expect(jsonResult.text, isNull);
      expect(jsonResult.json, equals(<String, Object?>{'ok': true}));
      expect(jsonResult.binaryMeta, isNull);

      final binResult = WebFetchResult(
        url: Uri.parse('https://example.invalid/blob'),
        status: 200,
        contentType: 'application/octet-stream',
        binaryMeta: const BinaryFetchMeta(
          contentType: 'application/octet-stream',
          contentLength: 1024,
        ),
      );
      expect(binResult.text, isNull);
      expect(binResult.json, isNull);
      expect(binResult.binaryMeta, isNotNull);
      expect(binResult.binaryMeta!.contentLength, equals(1024));
    });

    test('WebFetchOptions.empty defaults budget null + method GET', () {
      const opts = WebFetchOptions.empty;
      expect(opts.budgetBytes, isNull);
      expect(opts.method, equals('GET'));
      expect(opts.headers, isEmpty);
    });

    // ─── McpEndpoint ────────────────────────────────────────────

    test('McpEndpoint equality is structural on id', () {
      const a = McpEndpoint('memory');
      const b = McpEndpoint('memory');
      const c = McpEndpoint('memory_remote');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), equals('McpEndpoint(memory)'));
    });

    // ─── SubstrateEvent sealed sum + BrainEvent compliance ──────

    test('SubstrateEvent variants extend BrainEvent and emit kind', () {
      final at = DateTime.utc(2026, 5, 31, 12);
      final events = <SubstrateEvent>[
        LlmCallStarted(
          occurredAt: at,
          callId: 'c1',
          roleId: 'analyser',
          providerId: 'ollama:local',
          modelId: 'gemma2:9b',
        ),
        LlmCallChunk(occurredAt: at, callId: 'c1', charCount: 42),
        LlmCallCompleted(
          occurredAt: at,
          callId: 'c1',
          report: const LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'h',
            promptHash: 'h',
            tokensIn: 1,
            tokensOut: 2,
            retries: 0,
            wallClockMs: 10,
          ),
        ),
        LlmCallFailed(
          occurredAt: at,
          callId: 'c1',
          failure: const LlmFailure(
            classCode: 'timeout',
            message: 'wall-clock cutoff',
          ),
          providerId: 'p',
          modelId: 'm',
          retryCount: 1,
        ),
        ProviderFailover(
          occurredAt: at,
          fromProviderId: 'a',
          toProviderId: 'b',
          reason: 'rate_limit',
        ),
        CredentialCooldownStarted(
          occurredAt: at,
          profileId: 'openrouter',
          credentialFingerprint: 'sha256:ab',
          errorClass: 'billing',
          untilMs: 1735689600000,
        ),
        EmbeddingComputed(
          occurredAt: at,
          providerId: 'ollama:local',
          modelId: 'nomic-embed-text',
          dims: 768,
          batchSize: 1,
        ),
        EmbeddingIdentityChanged(
          occurredAt: at,
          fromIdentity: const EmbeddingModelIdentity(
            providerId: 'a',
            modelId: 'x',
            dims: 768,
            normalized: true,
          ),
          toIdentity: const EmbeddingModelIdentity(
            providerId: 'b',
            modelId: 'y',
            dims: 768,
            normalized: true,
          ),
        ),
        WebSearchCompleted(
          occurredAt: at,
          provider: 'duckduckgo',
          query: 'cats',
          k: 10,
          hits: 7,
        ),
        WebFetchCompleted(
          occurredAt: at,
          url: 'https://example.invalid/',
          status: 200,
          bytes: 1024,
          truncated: false,
        ),
        McpHandshakeCompleted(
          occurredAt: at,
          endpointId: 'memory',
          tools: const <String>['memory.recall'],
        ),
        McpCallCompleted(
          occurredAt: at,
          endpointId: 'memory',
          tool: 'memory.recall',
          wallClockMs: 15,
          ok: true,
        ),
      ];

      final kinds = events.map((e) => e.kind).toList();
      expect(
        kinds,
        equals(<String>[
          'substrate.llm-call-started',
          'substrate.llm-call-chunk',
          'substrate.llm-call-completed',
          'substrate.llm-call-failed',
          'substrate.provider-failover',
          'substrate.credential-cooldown-started',
          'substrate.embedding-computed',
          'substrate.embedding-identity-changed',
          'substrate.web-search-completed',
          'substrate.web-fetch-completed',
          'substrate.mcp-handshake-completed',
          'substrate.mcp-call-completed',
        ]),
      );

      // Every variant must serialise through BrainEvent.toJson
      // without throwing — `occurredAt` is UTC, payload is JSON-
      // shaped Map.
      for (final e in events) {
        final json = e.toJson();
        expect(json['kind'], equals(e.kind));
        expect(json['occurredAt'], equals(at.toIso8601String()));
        expect(json['payload'], isA<Map<String, Object?>>());
      }
    });

    test('CredentialCooldownStarted payload omits raw credential', () {
      final ev = CredentialCooldownStarted(
        occurredAt: DateTime.utc(2026, 5, 31),
        profileId: 'openrouter',
        credentialFingerprint: 'sha256:abcd',
        errorClass: 'billing',
        untilMs: 1735689600000,
      );
      final payload = ev.payloadJson();
      // The payload carries the fingerprint, never the token.
      expect(payload.containsKey('credentialFingerprint'), isTrue);
      expect(payload.values.any((v) =>
          v is String && v.contains('Bearer')), isFalse);
    });

    // ─── SubstrateStats ─────────────────────────────────────────

    test('SubstrateStats.empty has zero counters + snapshotAt set', () {
      final at = DateTime.utc(2026, 5, 31, 10);
      final s = SubstrateStats.empty(at);
      expect(s.snapshotAt, equals(at));
      expect(s.callsPerProvider, isEmpty);
      expect(s.callsPerRole, isEmpty);
      expect(s.embeddingsComputed, equals(0));
      expect(s.activeCooldowns, equals(0));
      expect(s.lastRetryAt, isNull);
      expect(s.webSearches, equals(0));
      expect(s.webFetches, equals(0));
      expect(s.mcpCalls, equals(0));
    });

    // ─── SubstrateConfig (B.36) ─────────────────────────────────

    test('SubstrateConfig is the concrete config root', () {
      // B.36 replaced the B.9 opaque-placeholder with the concrete
      // typed model. The api/ surface accepts it under the same
      // import path; constructing it requires every section the
      // YAML loader produces. The minimal fixture is the smallest
      // valid value; the full schema is covered in B.36's loader
      // test suite (`b36_substrate_config_loader_test.dart`).
      final cfg = _minimalSubstrateConfig();
      expect(cfg, isA<SubstrateConfig>());
      expect(cfg.providers, isEmpty);
      expect(cfg.roleRoutes, isEmpty);
    });

    // ─── CancellationToken ──────────────────────────────────────

    test('CancellationToken.none is never cancelled', () {
      const token = CancellationToken.none;
      expect(token.isCancelled, isFalse);

      // whenCancelled on `none` blocks forever — verify by racing
      // it against a short timeout.
      final outcome = Future.any(<Future<String>>[
        token.whenCancelled.then((_) => 'cancelled'),
        Future<String>.delayed(
          const Duration(milliseconds: 30),
          () => 'never',
        ),
      ]);
      expect(outcome, completion(equals('never')));
    });

    test('CancellationTokenSource fires exactly once', () async {
      final src = CancellationTokenSource();
      final token = src.token;
      expect(token.isCancelled, isFalse);
      expect(src.isCancelled, isFalse);

      final futureSeenCancel = token.whenCancelled.then((_) => true);
      src.cancel();
      expect(src.isCancelled, isTrue);
      expect(token.isCancelled, isTrue);

      // Idempotent — second cancel is a no-op.
      src.cancel();
      expect(await futureSeenCancel, isTrue);
    });

    test('whenCancelled on already-cancelled source resolves immediately',
        () async {
      final src = CancellationTokenSource();
      src.cancel();
      // Awaiting after cancellation returns without blocking.
      await src.token.whenCancelled.timeout(const Duration(milliseconds: 50));
      expect(src.token.isCancelled, isTrue);
    });
  });
}

// ─── Test fakes ────────────────────────────────────────────────

/// In-test stand-in for the in-process facade — every method
/// throws because B.9 only defines the contract; tests at B.45
/// exercise the real surface.
final class _DummySubstrate extends TomBrainSubstrate {
  const _DummySubstrate();

  @override
  Future<void> open(SubstrateConfig config) async =>
      throw UnimplementedError();

  @override
  Future<void> close() async => throw UnimplementedError();

  @override
  Future<LlmCallReport> complete(LlmCall call) =>
      throw UnimplementedError();

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      throw UnimplementedError();

  @override
  Future<EmbeddingResult> embed(String text) => throw UnimplementedError();

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) =>
      throw UnimplementedError();

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) =>
      throw UnimplementedError();

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) =>
      throw UnimplementedError();

  @override
  McpClient mcpClient(McpEndpoint endpoint) => throw UnimplementedError();

  @override
  Stream<SubstrateEvent> events() => throw UnimplementedError();

  @override
  SubstrateStats stats() => throw UnimplementedError();
}

// B.36 — `SubstrateConfig` is `final`; tests construct minimal
// instances directly rather than subclassing. The fixture below
// is the smallest valid value: empty providers + roleRoutes, a
// placeholder embedding choice, and default web/MCP/price blocks.
SubstrateConfig _minimalSubstrateConfig() => SubstrateConfig(
      providers: const [],
      roleRoutes: const {},
      embedding: const EmbeddingChoice(
        providerId: 'stub',
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      ),
      webSearch: const WebSearchConfig(
        defaultProvider: 'duckduckgo',
        providers: {
          'duckduckgo': WebSearchProviderConfig(kind: 'ddg_html'),
        },
      ),
      webFetch: const WebFetchConfig(),
      mcpClient: const McpClientConfigBlock(),
    );
