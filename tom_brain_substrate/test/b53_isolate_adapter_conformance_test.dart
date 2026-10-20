// Completion-plan item #12 — `IsolateTomBrainSubstrateAdapter` conformance.
//
// `IsolateTomBrainSubstrateAdapter` is the isolate-backed second
// implementation of [TomBrainSubstrateClient] (the in-process facade
// `InProcessTomBrainSubstrate` is the first). It hosts a real
// `TomBrainSubstrateClient` inside a worker isolate, marshals every
// surface method across the boundary, and — crucially — independently
// re-checks the assistant-dedication anchor on every report it surfaces,
// so a worker that fails to enforce the anchor cannot leak an unanchored
// report to a consumer.
//
// This suite drives the adapter over a **real** isolate boundary against
// two top-level `SubstrateFactory` functions:
//
//   * [buildStubBackedSubstrate] — a stub-backed
//     `InProcessTomBrainSubstrate` (mirrors `_buildFacade` in
//     `b41_in_process_facade_test.dart`). Used to prove the streaming
//     surface behaves identically to the in-process facade: a
//     `completeStream` call emits exactly one [LlmRunStarted], one or
//     more [LlmTextDelta], then exactly one [LlmRunCompleted].
//
//   * [buildBadAnchorSubstrate] — a hand-rolled, NON-enforcing
//     `TomBrainSubstrateClient` whose `complete` / `completeStream`
//     return a report with a tampered `anchorHash`. The worker does not
//     enforce the anchor, so the only thing standing between the bad
//     report and the consumer is the adapter's own independent re-check.
//     Both unary `complete` and streaming `completeStream` must surface
//     `AnchorViolation` at the proxy.
//
// Both factories are top-level functions: the host hands the factory to
// the spawned isolate as part of its boot context, and Dart isolates only
// accept top-level / static function tear-offs (closures captured in the
// spawning isolate cannot cross the boundary).

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('item #12 / IsolateTomBrainSubstrateAdapter', () {
    test('completeStream emits Started -> Chunk* -> Completed over the '
        'isolate boundary', () async {
      final host = TomBrainSubstrateIsolateHost(
        factory: buildStubBackedSubstrate,
      );
      await host.spawn();
      final adapter = IsolateTomBrainSubstrateAdapter(host: host);
      try {
        final events = await adapter.completeStream(_assistantCall()).toList();

        expect(events, isNotEmpty);
        expect(events.first, isA<LlmRunStarted>());
        expect(events.last, isA<LlmRunCompleted>());

        // Exactly one Started, exactly one terminal Completed, and at
        // least one Chunk in between — the spec § 4.3 streaming shape.
        expect(events.whereType<LlmRunStarted>().length, 1);
        expect(events.whereType<LlmRunCompleted>().length, 1);
        expect(events.whereType<LlmRunFailed>(), isEmpty);
        expect(events.whereType<LlmTextDelta>(), isNotEmpty);

        // The terminal names the call the started event opened.
        final started = events.first as LlmRunStarted;
        final completed = events.last as LlmRunCompleted;
        expect(completed.callId, started.callId);

        // The surfaced report carries the current anchor (the worker
        // facade enforces; the proxy re-affirms).
        expect(AnchorRegistry.isCurrent(completed.report.anchorHash), isTrue);
      } finally {
        await host.shutdown();
      }
    });

    test('complete re-checks the anchor at the proxy and throws '
        'AnchorViolation when the worker returns a tampered report', () async {
      final host = TomBrainSubstrateIsolateHost(
        factory: buildBadAnchorSubstrate,
      );
      await host.spawn();
      final adapter = IsolateTomBrainSubstrateAdapter(host: host);
      try {
        await expectLater(
          adapter.complete(_assistantCall()),
          throwsA(isA<AnchorViolation>()),
        );
      } finally {
        await host.shutdown();
      }
    });

    test('completeStream re-checks the anchor at the proxy and surfaces '
        'AnchorViolation as a stream error on a tampered report', () async {
      final host = TomBrainSubstrateIsolateHost(
        factory: buildBadAnchorSubstrate,
      );
      await host.spawn();
      final adapter = IsolateTomBrainSubstrateAdapter(host: host);
      try {
        await expectLater(
          adapter.completeStream(_assistantCall()).toList(),
          throwsA(isA<AnchorViolation>()),
        );
      } finally {
        await host.shutdown();
      }
    });

    test(
      'unary surface round-trips: embed + stats cross the boundary',
      () async {
        final host = TomBrainSubstrateIsolateHost(
          factory: buildStubBackedSubstrate,
        );
        await host.spawn();
        final adapter = IsolateTomBrainSubstrateAdapter(host: host);
        try {
          final embedding = await adapter.embed('hello');
          expect(embedding.modelIdentity.modelId, 'stub-embedder');
          expect(embedding.vec.values.length, 4);

          // A completed call bumps the per-provider / per-role counters.
          await adapter.complete(_assistantCall());
          final stats = adapter.stats();
          expect(stats.callsPerProvider['stub'], 1);
          expect(stats.embeddingsComputed, 1);
        } finally {
          await host.shutdown();
        }
      },
    );

    test('mcpClient is unsupported across the boundary', () async {
      final host = TomBrainSubstrateIsolateHost(
        factory: buildStubBackedSubstrate,
      );
      await host.spawn();
      final adapter = IsolateTomBrainSubstrateAdapter(host: host);
      try {
        expect(
          () => adapter.mcpClient(const McpEndpoint('x')),
          throwsUnsupportedError,
        );
      } finally {
        await host.shutdown();
      }
    });
  });
}

// ─── Shared call fixture ──────────────────────────────────────────────

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

// ─── Worker factories (top-level: sendable across the isolate) ────────

/// Stub-backed in-process facade — mirrors `_buildFacade` from b41.
Future<TomBrainSubstrateClient> buildStubBackedSubstrate() async {
  final roles = bootstrapRoleRegistry();
  final provider = StubLlmProvider(id: 'stub', defaultModel: 'stub-model');
  final providers = <String, LlmProvider>{'stub': provider};
  final policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      'assistant_to_user': const <RouteEntry>[
        RouteEntry(providerId: 'stub', model: 'stub-model'),
      ],
    },
  );
  final router = LlmRouter(providers: providers, policy: policy);
  return InProcessTomBrainSubstrate(
    roleRegistry: roles,
    providers: providers,
    router: router,
    embeddingService: _StubEmbeddingService(),
    webSearch: _StubWebSearch(),
    webFetch: _StubWebFetch(),
  );
}

/// Non-enforcing fake that returns reports carrying a tampered anchor
/// hash. The adapter's independent re-check is the only line of defense.
Future<TomBrainSubstrateClient> buildBadAnchorSubstrate() async =>
    _BadAnchorSubstrate();

const String _tamperedAnchorHash = 'sha256:deadbeefdeadbeef';

class _BadAnchorSubstrate implements TomBrainSubstrateClient {
  int _seq = 0;

  LlmCallReport _badReport() => LlmCallReport(
    providerId: 'bad-provider',
    modelId: 'bad-model',
    anchorHash: _tamperedAnchorHash,
    promptHash: 'sha256:0',
    tokensIn: 1,
    tokensOut: 1,
    retries: 0,
    wallClockMs: 1,
  );

  @override
  Future<LlmCallReport> complete(LlmCall call) async => _badReport();

  @override
  Stream<LlmEvent> completeStream(LlmCall call) async* {
    final callId = 'bad-${_seq++}';
    yield LlmRunStarted(
      callId: callId,
      providerId: 'bad-provider',
      modelId: 'bad-model',
    );
    yield LlmTextDelta('tampered');
    yield LlmRunCompleted(callId: callId, report: _badReport());
  }

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<EmbeddingResult> embed(String text) =>
      throw UnimplementedError('embed');

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) =>
      throw UnimplementedError('embedBatch');

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) => throw UnimplementedError('webSearch');

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) => throw UnimplementedError('webFetch');

  @override
  McpClient mcpClient(McpEndpoint endpoint) =>
      throw UnimplementedError('mcpClient');

  @override
  Stream<SubstrateEvent> events() => const Stream<SubstrateEvent>.empty();

  @override
  SubstrateStats stats() => SubstrateStats.empty(DateTime.now().toUtc());
}

// ─── Stub collaborators for the in-process facade worker ──────────────

final class _StubEmbeddingService implements EmbeddingService {
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
  Future<void> close() async {}
}

final class _StubWebSearch implements WebSearch {
  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async => WebSearchResult(
    provider: 'stub-search',
    query: query,
    hits: const <SearchHit>[],
  );

  @override
  void close() {}
}

final class _StubWebFetch implements WebFetch {
  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async => WebFetchResult(
    url: url,
    status: 200,
    contentType: 'text/plain',
    text: '',
  );

  @override
  void close() {}
}
