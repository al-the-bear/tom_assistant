// Review fix B.3.4 — `completeStream` drives lazily on listen.
//
// `prototype_review_result.md` § B.3.4 flagged that the facade's
// `completeStream` pumped the router's events into a fire-and-forget
// `StreamController` via `unawaited(drive())` *before* the consumer
// subscribed. Router (and provider) work therefore began the moment
// `completeStream` was called, and events buffered into the controller
// even when no one was listening — the stream was not lazy, and the
// subscriber's pause/resume never reached the producer.
//
// The fix returns a plain `async*` stream: single-subscription, started
// only on the first listen, with the consumer's pause/resume honoured
// across the `await for` boundary.
//
// These tests pin:
//   1. **Laziness** — no router/provider work happens until the
//      returned stream is listened to. (This is the actual bug.)
//   2. **Single subscription** — the returned stream rejects a second
//      listener, as an `async*` stream must.
//   3. **Behaviour preserved** — once listened to, the stream relays
//      the provider's events and the facade still emits exactly one
//      `LlmCallCompleted` keyed to the stamped call id.
//
// Note on back-pressure to the *provider*: the router
// (`LlmRouter.dispatchStream`) drains a provider's stream to its
// terminal event and buffers the chunks before replaying them (it has
// to see the terminal event to fold retries into the report). So a
// consumer pause cannot reach back through the router to the provider
// — that is a router design property, not a facade one. B.3.4 is about
// the facade no longer running the router before anyone listens; these
// tests pin that, not an end-to-end provider pause.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.3.4 / completeStream drives lazily', () {
    test(
      'does no router/provider work until the stream is listened to',
      () async {
        final f = _buildFacade();
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        final stream = f.facade.completeStream(_assistantCall());

        // Give any (incorrectly) eager driver several turns of the event
        // loop to start — a fire-and-forget `unawaited(drive())` would
        // have invoked the provider by now.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(
          f.provider.streamInvocations,
          0,
          reason: 'provider must not be invoked before the consumer listens',
        );

        // Subscribing kicks off the work.
        await stream.toList();
        expect(f.provider.streamInvocations, 1);
      },
    );

    test('is a single-subscription stream', () {
      final f = _buildFacade();
      addTearDown(f.facade.close);

      final stream = f.facade.completeStream(_assistantCall());
      expect(stream.isBroadcast, isFalse);

      stream.listen((_) {});
      expect(() => stream.listen((_) {}), throwsStateError);
    });

    test(
      'relays events and emits one LlmCallCompleted once listened',
      () async {
        final f = _buildFacade();
        await f.facade.open(_minimalConfig());
        addTearDown(f.facade.close);

        final substrateEvents = <SubstrateEvent>[];
        final sub = f.facade.events().listen(substrateEvents.add);
        addTearDown(sub.cancel);

        final streamEvents = await f.facade
            .completeStream(_assistantCall())
            .toList();

        expect(streamEvents.first, isA<LlmRunStarted>());
        expect(streamEvents.last, isA<LlmRunCompleted>());

        await Future<void>.delayed(Duration.zero);
        expect(substrateEvents.whereType<LlmCallCompleted>(), hasLength(1));
      },
    );
  });
}

// ─── Fixtures ─────────────────────────────────────────────────────

class _FacadeFixture {
  final InProcessTomBrainSubstrate facade;
  final _RecordingProvider provider;

  _FacadeFixture({required this.facade, required this.provider});
}

_FacadeFixture _buildFacade() {
  final roles = bootstrapRoleRegistry();
  final provider = _RecordingProvider(id: 'stub', defaultModel: 'stub-model');
  final providers = <String, LlmProvider>{'stub': provider};
  final policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      'assistant_to_user': const <RouteEntry>[
        RouteEntry(providerId: 'stub', model: 'stub-model'),
      ],
    },
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

  return _FacadeFixture(facade: facade, provider: provider);
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

/// [LlmProvider] that records how many times its streaming path has
/// been entered. The counter increments only when the `async*` body
/// actually runs — i.e. when something listens — so the test can prove
/// the facade does not drive the router before subscription.
final class _RecordingProvider extends LlmProvider {
  @override
  final String id;
  final String defaultModel;
  int streamInvocations = 0;

  _RecordingProvider({required this.id, required this.defaultModel});

  @override
  Future<LlmCallReport> complete(LlmRequest request) async {
    final prompt = request.prompt;
    final options = request.options;
    return _report(prompt, options);
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    streamInvocations++;
    final modelId = options.model ?? defaultModel;
    yield LlmRunStarted(
      callId: 'rec-$streamInvocations',
      providerId: id,
      modelId: modelId,
    );
    yield LlmRunCompleted(
      callId: 'rec-$streamInvocations',
      report: _report(prompt, options),
    );
  }

  LlmCallReport _report(WirePrompt prompt, LlmOptions options) => LlmCallReport(
    providerId: id,
    modelId: options.model ?? defaultModel,
    anchorHash: prompt.anchorHash,
    promptHash: 'sha256:0',
    tokensIn: prompt.combined.length,
    tokensOut: 0,
    retries: 0,
    wallClockMs: 0,
    templateSha: prompt.templateSha,
    notes: const <String>['recording'],
  );
}

final class _NoopEmbeddingService implements EmbeddingService {
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
    return EmbeddingResult(vec: Vec(values), modelIdentity: _identity);
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async =>
      <EmbeddingResult>[for (final t in texts) await embed(t)];

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async => EmbeddingProbeResult(
    currentIdentity: _identity,
    probeResult: await embed(probeText),
    driftEvent: null,
  );

  @override
  Future<void> close() async {}
}

final class _NoopWebSearch implements WebSearch {
  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async => WebSearchResult(
    provider: 'noop',
    query: query,
    hits: const <SearchHit>[],
  );

  @override
  void close() {}
}

final class _NoopWebFetch implements WebFetch {
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
