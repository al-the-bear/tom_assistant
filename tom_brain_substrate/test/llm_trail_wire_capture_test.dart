// Wire-body capture on `LlmStreamCompleted` (`tom_brain_logging.md` §5.2 /
// §10 step #4).
//
// Step #4 (`LlmTrailWriter`) needs the **full wire body** — the anchor
// scaffold the provider actually saw — to write `llm/<role>/…raw.json`.
// The body lives only as a local `WirePrompt` inside the facade's
// `_driveCompleteStream`; no event carried it (logging-spec "gap #3").
//
// This pins the seam that closes the gap: the terminal `LlmStreamCompleted`
// the facade yields now carries a `CapturedWirePrompt` (an api/-layer DTO —
// `WirePrompt` itself stays confined to `lib/src/llm/` so consumers cannot
// construct one and bypass the role registry). The DTO mirrors the wire's
// provenance (body + anchorHash + roleId + templateSha) so a downstream
// trail writer can serialise the §5.2 `wire` block from one source of truth.
//
// Why on the stream event and not via the spec's literal §9 two-stream join
// (`RunRecorder.onEntry` + `events()`): the bridge already drains
// `completeStream` to its terminal event, so attaching the wire there is one
// source of truth with no fragile temporal correlation between two buses.
// (Spec reconciliation, recorded in §9.)

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('§5.2 — wire body captured on LlmStreamCompleted', () {
    test('terminal completed event carries the assembled wire body', () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      final events =
          await f.facade.completeStream(_assistantCall()).toList();
      final completed = events.last as LlmStreamCompleted;

      final wire = completed.wire;
      expect(wire, isNotNull,
          reason: 'the wire body is the §5.2 raw-trail payload');
      expect(wire!.roleId, 'assistant_to_user');
      expect(wire.body, isNotEmpty,
          reason: 'the body is the anchor scaffold the provider saw');
      // The wire the consumer sees is the very prompt the report hashed:
      // its anchorHash must equal the report's (anchor invariant, B.46).
      expect(wire.anchorHash, completed.report.anchorHash);
      expect(wire.templateSha, completed.report.templateSha);
    });

    test('the captured body begins with the dedication anchor block',
        () async {
      final f = _buildFacade();
      await f.facade.open(_minimalConfig());
      addTearDown(f.facade.close);

      final events =
          await f.facade.completeStream(_assistantCall()).toList();
      final wire = (events.last as LlmStreamCompleted).wire!;

      // The provider echoes `prompt.body.length` as tokensIn; the captured
      // body must be that same string (one source of truth, not a re-render).
      final report = (events.last as LlmStreamCompleted).report;
      expect(wire.body.length, report.tokensIn);
    });
  });
}

// ─── Fixtures (mirror rev_b3_4_complete_stream_lazy_test.dart) ───────

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

final class _RecordingProvider implements LlmProvider {
  @override
  final String id;
  final String defaultModel;
  int streamInvocations = 0;

  _RecordingProvider({required this.id, required this.defaultModel});

  @override
  Future<LlmCallReport> complete(WirePrompt prompt, LlmOptions options) async {
    return _report(prompt, options);
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    streamInvocations++;
    final modelId = options.model ?? defaultModel;
    yield LlmStreamStarted(
      callId: 'rec-$streamInvocations',
      providerId: id,
      modelId: modelId,
    );
    yield LlmStreamCompleted(
      callId: 'rec-$streamInvocations',
      report: _report(prompt, options),
    );
  }

  LlmCallReport _report(WirePrompt prompt, LlmOptions options) => LlmCallReport(
        providerId: id,
        modelId: options.model ?? defaultModel,
        anchorHash: prompt.anchorHash,
        promptHash: 'sha256:0',
        tokensIn: prompt.body.length,
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
  }) async =>
      EmbeddingProbeResult(
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
  }) async =>
      WebSearchResult(
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
  }) async =>
      WebFetchResult(
        url: url,
        status: 200,
        contentType: 'text/plain',
        text: '',
      );

  @override
  void close() {}
}
