// Plan-2 item 12 — live provider smoke (integration).
//
// Plan text (verbatim, `prototype_implementation_plan_2.md` item 12):
//
//   "**Substrate: live provider smoke (integration).** `complete()` /
//    `completeStream()` through `OpenAiPassthroughProvider` against
//    **oMLX**, and `embed()` / `embedBatch()` through
//    `OllamaEmbeddingService` against **Ollama**. Gate the test to skip
//    when the endpoints are unreachable (no CI flakiness), but it must
//    pass on bomber now. *Verify:* a real streamed completion from oMLX
//    and a real 768-d embedding assert through the public
//    `TomBrainSubstrate` facade."
//
// What this file owns:
//
//   * A *live* end-to-end smoke that drives the public
//     `InProcessTomBrainSubstrate` facade against two real daemons:
//       - chat: oMLX (OpenAI-compatible) via `OpenAiPassthroughProvider`;
//       - embeddings: Ollama via `OllamaEmbeddingService` over an
//         `OllamaLlmProvider`.
//     oMLX serves no embedding model, so embeddings come from Ollama —
//     the two responsibilities are split exactly as the production
//     facade splits them (chat = router; embeddings = embeddingService).
//
//   * Two independent reachability probes (one per daemon). Each test is
//     registered with `skip:` resolved at registration time from a cheap
//     2-second TCP connect — so a developer machine without either
//     daemon records a clean skip, never a flaky failure, while bomber
//     (both daemons up) runs them green.
//
// Why the probe is split in two:
//
//   The chat and embedding daemons are different processes on different
//   hosts (oMLX on the GPU box, Ollama on localhost). A machine may have
//   one but not the other; gating each family on its own probe keeps the
//   green surface as large as the live infrastructure allows instead of
//   skipping everything when only one daemon is down.
//
// Endpoint defaults (bomber) and overrides:
//
//   * oMLX     — `TOM_BRAIN_OMLX_BASE_URI`  (default `http://10.8.0.7:8000/`),
//                `TOM_BRAIN_OMLX_MODEL`     (default `gemma-4-26b-a4b-it-4bit`).
//     NOTE: the base URI MUST carry a trailing slash — the OpenAI HTTP
//     client resolves `v1/chat/completions` against it relatively, so a
//     missing slash would drop the last path segment.
//   * Ollama   — `TOM_BRAIN_OLLAMA_BASE_URI` (default `http://127.0.0.1:11434/`),
//                embedding model `nomic-embed-text`, 768 dims.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

void main() {
  // The providers' default wire HTTP client is sourced from the
  // `tom_core_kernel` factory, which delegates to the active
  // `TomPlatformUtils`. In a bare `dart test` process that is the
  // fallback platform, whose `httpClient()` throws `UnimplementedError`.
  // The server entrypoint installs the standalone platform at startup;
  // this live integration smoke must do the same so the real HTTP path
  // is exercised end-to-end. (Off-host runs skip before any HTTP call,
  // so this init is harmless there.)
  setUpAll(() {
    TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);
  });

  group('P2.12 / live provider smoke', () {
    // ─── oMLX chat row (skipped when oMLX unreachable) ──────────────
    group('oMLX chat via OpenAiPassthroughProvider', () {
      final target = _LiveTarget.resolve(
        baseUriEnv: 'TOM_BRAIN_OMLX_BASE_URI',
        defaultBaseUri: 'http://10.8.0.7:8000/',
        modelEnv: 'TOM_BRAIN_OMLX_MODEL',
        defaultModel: 'gemma-4-26b-a4b-it-4bit',
        daemonName: 'oMLX',
      );

      test(
        'complete: real answer from oMLX through the facade — anchored',
        () async {
          final reason = await target.unreachableReason();
          if (reason != null) return markTestSkipped(reason);

          final fixture = _buildLiveFacade(chat: target);
          final TomBrainSubstrateClient client = fixture.client;
          addTearDown(fixture.dispose);
          await client.open(_liveConfig(chatModel: target.model));

          final report = await client.complete(_assistantCall());

          expect(report.providerId, 'omlx');
          expect(report.modelId, isNotEmpty);
          expect(
            report.tokensOut,
            greaterThan(0),
            reason: 'oMLX must return a non-empty completion',
          );
          expect(report.anchorHash, AnchorRegistry.currentHash);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'completeStream: real streamed answer from oMLX — anchored',
        () async {
          final reason = await target.unreachableReason();
          if (reason != null) return markTestSkipped(reason);

          final fixture = _buildLiveFacade(chat: target);
          final TomBrainSubstrateClient client = fixture.client;
          addTearDown(fixture.dispose);
          await client.open(_liveConfig(chatModel: target.model));

          final events = await client.completeStream(_assistantCall()).toList();

          expect(events, isNotEmpty);
          expect(events.first, isA<LlmRunStarted>());

          final chunks = events.whereType<LlmTextDelta>().toList();
          expect(
            chunks,
            isNotEmpty,
            reason: 'a real streamed completion must emit ≥1 chunk',
          );
          final streamedText = chunks.map((c) => c.text).join();
          expect(
            streamedText.trim(),
            isNotEmpty,
            reason: 'oMLX must stream non-empty completion text',
          );

          final last = events.last;
          if (last is LlmRunCompleted) {
            expect(last.report.providerId, 'omlx');
            expect(last.report.anchorHash, AnchorRegistry.currentHash);
          } else if (last is LlmRunFailed) {
            fail('oMLX stream failed: ${last.failure}');
          } else {
            fail(
              'oMLX stream must terminate with LlmRunCompleted, '
              'got: $last',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('target resolves to a well-formed http endpoint', () {
        expect(target.baseUri.host, isNotEmpty);
        expect(target.baseUri.hasPort, isTrue);
        expect(
          target.baseUri.path,
          endsWith('/'),
          reason:
              'OpenAI client resolves v1/... relatively — the base '
              'URI must end with a slash',
        );
        expect(target.model, isNotEmpty);
      });
    });

    // ─── Ollama embedding row (skipped when Ollama unreachable) ─────
    group('Ollama embeddings via OllamaEmbeddingService', () {
      final target = _LiveTarget.resolve(
        baseUriEnv: 'TOM_BRAIN_OLLAMA_BASE_URI',
        defaultBaseUri: 'http://127.0.0.1:11434/',
        modelEnv: 'TOM_BRAIN_OLLAMA_EMBED_MODEL',
        defaultModel: 'nomic-embed-text',
        daemonName: 'Ollama',
      );

      test(
        'embed: a real 768-d vector through the facade',
        () async {
          final reason = await target.ollamaModelMissingReason();
          if (reason != null) return markTestSkipped(reason);

          final fixture = _buildLiveFacade(embed: target);
          final TomBrainSubstrateClient client = fixture.client;
          addTearDown(fixture.dispose);
          await client.open(_liveConfig(embedModel: target.model));

          final result = await client.embed('the quick brown fox');

          expect(
            result.vec.dimension,
            768,
            reason: 'nomic-embed-text produces 768-dimensional vectors',
          );
          expect(result.modelIdentity.providerId, 'ollama');
          expect(result.modelIdentity.modelId, target.model);
          expect(result.modelIdentity.dims, 768);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test(
        'embedBatch: each input yields a real 768-d vector',
        () async {
          final reason = await target.ollamaModelMissingReason();
          if (reason != null) return markTestSkipped(reason);

          final fixture = _buildLiveFacade(embed: target);
          final TomBrainSubstrateClient client = fixture.client;
          addTearDown(fixture.dispose);
          await client.open(_liveConfig(embedModel: target.model));

          final results = await client.embedBatch(const <String>[
            'alpha',
            'bravo',
            'charlie',
          ]);

          expect(results, hasLength(3));
          for (final r in results) {
            expect(r.vec.dimension, 768);
            expect(r.modelIdentity.modelId, target.model);
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );

      test('target resolves to a well-formed http endpoint', () {
        expect(target.baseUri.host, isNotEmpty);
        expect(target.baseUri.hasPort, isTrue);
        expect(target.model, isNotEmpty);
      });
    });
  });
}

// ─── Live target + async reachability probe ───────────────────────

/// A live daemon target: its (slash-terminated) base URI, the model id
/// to exercise, and a human name for skip messages.
///
/// Resolution is synchronous and never touches the network — it only
/// reads env overrides and normalises the URI. Reachability is a
/// *separate*, async, awaited TCP probe performed inside the test body
/// ([unreachableReason]); skipping is done at runtime via
/// `markTestSkipped` rather than a registration-time `skip:` string.
///
/// Why runtime-skip instead of registration-time `skip:`: a real TCP
/// connect is asynchronous, and a registration-time probe would have to
/// block the isolate's event loop to await it — which prevents the
/// connect callback from ever firing, so it always reports "unreachable"
/// and the live path is never exercised. Awaiting inside the (async)
/// test body lets the connect actually complete.
class _LiveTarget {
  final Uri baseUri;
  final String model;
  final String daemonName;

  _LiveTarget._({
    required this.baseUri,
    required this.model,
    required this.daemonName,
  });

  /// Reads `[baseUriEnv]` (override, default [defaultBaseUri]) and
  /// `[modelEnv]` (override, default [defaultModel]). The base URI is
  /// normalised to carry an explicit port and a trailing slash so the
  /// OpenAI client's relative `v1/...` resolution keeps the host path.
  factory _LiveTarget.resolve({
    required String baseUriEnv,
    required String defaultBaseUri,
    required String modelEnv,
    required String defaultModel,
    required String daemonName,
  }) {
    final env = Platform.environment;
    final model = env[modelEnv] ?? defaultModel;
    Uri parsed;
    try {
      parsed = Uri.parse(env[baseUriEnv] ?? defaultBaseUri);
    } on FormatException {
      parsed = Uri.parse(defaultBaseUri);
    }
    final port = parsed.hasPort
        ? parsed.port
        : (parsed.scheme == 'https' ? 443 : 80);
    final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    final normalised = parsed.replace(port: port, path: path);
    return _LiveTarget._(
      baseUri: normalised,
      model: model,
      daemonName: daemonName,
    );
  }

  /// Performs one awaited `Socket.connect` with a two-second timeout.
  /// Returns `null` when the daemon is reachable, or a skip-rationale
  /// string when it is not (so the caller can `markTestSkipped`).
  Future<String?> unreachableReason() async {
    final host = baseUri.host;
    final port = baseUri.port;
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return null;
    } on Object catch (e) {
      return 'no TCP connect to $host:$port within 2s ($daemonName not '
          'reachable; this live smoke is skipped off-host by design): $e';
    }
  }

  /// [unreachableReason], then asks Ollama's `api/tags` whether [model] is
  /// pulled. A daemon that answers without the model is a machine that has
  /// not been provisioned for this smoke, not a defect in the substrate, so
  /// it is a skip naming the command that provisions it.
  Future<String?> ollamaModelMissingReason() async {
    final unreachable = await unreachableReason();
    if (unreachable != null) return unreachable;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final request = await client.getUrl(baseUri.resolve('api/tags'));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      final body = await response.transform(utf8.decoder).join();
      final models = (jsonDecode(body) as Map<String, Object?>)['models'];
      final names = [
        for (final m in models as List<Object?>)
          if (m is Map<String, Object?> && m['name'] is String)
            m['name']! as String,
      ];
      final pulled = names.any(
        (name) => name == model || name.startsWith('$model:'),
      );
      return pulled
          ? null
          : '$daemonName at $baseUri has no model "$model" (has: '
                '${names.join(', ')}); run `ollama pull $model` to enable '
                'this live smoke';
    } on Object catch (e) {
      return '$daemonName at $baseUri did not list its models: $e';
    } finally {
      client.close(force: true);
    }
  }
}

// ─── Live facade fixture ──────────────────────────────────────────

class _LiveFixture {
  final TomBrainSubstrateClient client;
  final List<void Function()> _disposers;
  _LiveFixture(this.client, this._disposers);

  Future<void> dispose() async {
    await client.close();
    // The facade closes the embedding service but not the underlying
    // chat/embedding providers (it does not own their lifetime), so the
    // test closes them explicitly to avoid leaked sockets.
    for (final d in _disposers) {
      d();
    }
  }
}

/// Builds a facade wired to live daemons. When [chat] is supplied the
/// chat route targets oMLX through an [OpenAiPassthroughProvider]; when
/// [embed] is supplied the embedding service targets Ollama. The two are
/// independent so each daemon family can be exercised in isolation under
/// its own reachability gate.
_LiveFixture _buildLiveFacade({_LiveTarget? chat, _LiveTarget? embed}) {
  final roles = bootstrapRoleRegistry();
  final disposers = <void Function()>[];

  // Chat provider — oMLX (or a stub when this family is not under test).
  final LlmProvider chatProvider;
  final String chatModel;
  if (chat != null) {
    chatModel = chat.model;
    final omlx = OpenAiPassthroughProvider(
      id: 'omlx',
      baseUri: chat.baseUri,
      defaultModel: chatModel,
    );
    disposers.add(omlx.close);
    chatProvider = omlx;
  } else {
    chatModel = 'stub-model';
    chatProvider = StubLlmProvider(id: 'omlx', defaultModel: chatModel);
  }

  final providers = <String, LlmProvider>{'omlx': chatProvider};
  final policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      'assistant_to_user': <RouteEntry>[
        RouteEntry(providerId: 'omlx', model: chatModel),
      ],
    },
  );
  final router = LlmRouter(providers: providers, policy: policy);

  // Embedding service — Ollama (or a noop when this family is not tested).
  final EmbeddingService embeddingService;
  if (embed != null) {
    final ollama = OllamaLlmProvider(
      id: 'ollama',
      baseUri: embed.baseUri,
      defaultModel: embed.model,
    );
    disposers.add(ollama.close);
    embeddingService = OllamaEmbeddingService(
      provider: ollama,
      model: embed.model,
      dims: 768,
      normalize: true,
    );
  } else {
    embeddingService = _NoopEmbeddingService();
  }

  final facade = InProcessTomBrainSubstrate(
    roleRegistry: roles,
    providers: providers,
    router: router,
    embeddingService: embeddingService,
    webSearch: _NoopWebSearch(),
    webFetch: _NoopWebFetch(),
  );
  return _LiveFixture(facade, disposers);
}

SubstrateConfig _liveConfig({
  String chatModel = 'stub-model',
  String embedModel = 'nomic-embed-text',
}) => SubstrateConfig(
  providers: const <ProviderProfile>[],
  roleRoutes: <String, List<RoleRouteEntryConfig>>{
    'assistant_to_user': <RoleRouteEntryConfig>[
      RoleRouteEntryConfig(providerId: 'omlx', model: chatModel),
    ],
  },
  embedding: EmbeddingChoice(
    providerId: 'ollama',
    model: embedModel,
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

LlmCall _assistantCall() => LlmCall(
  roleId: 'assistant_to_user',
  inputs: const <String, Object?>{
    'question': 'Reply with the single word: pong.',
  },
  budget: Budget(
    wallClockMs: 90000,
    tokenSpend: 256,
    toolCalls: 0,
    memoryWrites: 0,
  ),
);

// ─── Collaborator no-ops (web / embed) ────────────────────────────

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
  Future<EmbeddingResult> embed(String text) async =>
      EmbeddingResult(vec: Vec.zero(_identity.dims), modelIdentity: _identity);

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const <EmbeddingResult>[];
    return <EmbeddingResult>[for (final t in texts) await embed(t)];
  }

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async {
    final r = await embed(probeText);
    return EmbeddingProbeResult(
      currentIdentity: _identity,
      probeResult: r,
      driftEvent: null,
    );
  }

  @override
  Future<void> close() async {}
}

final class _NoopWebSearch implements WebSearch {
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
