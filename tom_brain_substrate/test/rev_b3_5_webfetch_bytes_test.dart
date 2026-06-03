// Review fix B.3.5 — `WebFetchCompleted.bytes` reports the real decoded
// body byte length on the JSON path.
//
// `prototype_review_result.md` § B.3.5 flagged that the facade computed
// the event's `bytes` field as `result.json == null ? 0 : 1` on the
// JSON branch — a placeholder, not the actual size. `WebFetchResult`
// carried no byte count, so the facade had nothing real to report for a
// JSON response.
//
// The fix carries the measured body byte length on `WebFetchResult`
// (`contentBytes` = the number of raw body bytes the substrate read,
// which `DefaultWebFetch` sets to `response.bodyBytes.length` on every
// content-type branch). The facade reports `contentBytes` directly, so
// JSON responses report their true size — and text responses now report
// bytes rather than the previous character count.
//
// These tests pin:
//   1. `DefaultWebFetch` sets `contentBytes` to the real decoded byte
//      length on the JSON path (proven with a multi-byte UTF-8 body so
//      bytes != characters), not the 0/1 placeholder.
//   2. The facade emits `WebFetchCompleted.bytes == result.contentBytes`
//      for a JSON fetch.

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.3.5 / DefaultWebFetch carries the real body byte length', () {
    test('JSON path sets contentBytes to the decoded byte length', () async {
      // A body with a multi-byte UTF-8 character (€ = 3 bytes) so the
      // byte length is strictly greater than the character length —
      // proving the field is bytes, not `String.length`.
      const body = '{"price":"10€","note":"café"}';
      final byteLen = utf8.encode(body).length;
      expect(byteLen, greaterThan(body.length));

      final http = _FakeBytesHttpClient()
        ..response = _okJsonBytes(body);
      final fetch = DefaultWebFetch(httpClient: http);
      addTearDown(fetch.close);

      final result = await fetch.fetch(Uri.parse('https://example.com/'));

      expect(result.json, isA<Map>());
      expect(result.contentBytes, byteLen);
      // The old placeholder would have been 1.
      expect(result.contentBytes, greaterThan(1));
    });

    test('text path also reports bytes (not character count)', () async {
      const body = 'café'; // 4 chars, 5 UTF-8 bytes.
      final http = _FakeBytesHttpClient()
        ..response = _okTextBytes(body);
      final fetch = DefaultWebFetch(httpClient: http);
      addTearDown(fetch.close);

      final result = await fetch.fetch(Uri.parse('https://example.com/'));
      expect(result.text, body);
      expect(result.contentBytes, utf8.encode(body).length);
      expect(result.contentBytes, greaterThan(body.length));
    });
  });

  group('B.3.5 / facade reports contentBytes on WebFetchCompleted', () {
    test('JSON fetch emits the real byte length, not a 0/1 placeholder',
        () async {
      const decodedBytes = 4096;
      final f = _buildFacade(
        webFetch: _PrimedWebFetch(
          result: WebFetchResult(
            url: Uri.parse('https://example.com/data.json'),
            status: 200,
            contentType: 'application/json',
            json: const <String, Object?>{'ok': true},
            contentBytes: decodedBytes,
          ),
        ),
      );
      await f.open(_minimalConfig());
      addTearDown(f.close);

      final events = <SubstrateEvent>[];
      final sub = f.events().listen(events.add);
      addTearDown(sub.cancel);

      await f.webFetch(Uri.parse('https://example.com/data.json'));
      await Future<void>.delayed(Duration.zero);

      final ev = events.whereType<WebFetchCompleted>().single;
      expect(ev.bytes, decodedBytes);
    });
  });
}

// ─── Fixtures ─────────────────────────────────────────────────────

InProcessTomBrainSubstrate _buildFacade({required WebFetch webFetch}) {
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
  return InProcessTomBrainSubstrate(
    roleRegistry: roles,
    providers: providers,
    router: LlmRouter(providers: providers, policy: policy),
    embeddingService: _NoopEmbeddingService(),
    webSearch: _NoopWebSearch(),
    webFetch: webFetch,
  );
}

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

final class _PrimedWebFetch implements WebFetch {
  final WebFetchResult result;
  _PrimedWebFetch({required this.result});

  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async =>
      result;

  @override
  void close() {}
}

/// Fake `WebHttpClient` exposing only `getBytes` (the surface
/// `WebFetch` uses). Mirrors `_FakeBytesHttpClient` from
/// `b30_web_fetch_test.dart`.
class _FakeBytesHttpClient implements WebHttpClient {
  WebHttpBytesResponse? response;

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async =>
      response ??
      (throw StateError('_FakeBytesHttpClient.response not set'));

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async =>
      throw UnimplementedError();

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async =>
      throw UnimplementedError();

  @override
  void close() {}
}

WebHttpBytesResponse _okJsonBytes(String body) => _okBytes(
      body,
      contentType: 'application/json',
    );

WebHttpBytesResponse _okTextBytes(String body) => _okBytes(
      body,
      contentType: 'text/plain',
    );

WebHttpBytesResponse _okBytes(String body, {required String contentType}) {
  final bytes = utf8.encode(body);
  return WebHttpBytesResponse(
    statusCode: 200,
    bodyBytes: bytes,
    headers: <String, String>{
      'content-type': contentType,
      'content-length': bytes.length.toString(),
    },
    url: Uri.parse('https://example.com/'),
    contentLength: bytes.length,
    truncated: false,
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
  Future<EmbeddingResult> embed(String text) async =>
      EmbeddingResult(vec: Vec(Float32List(_identity.dims)),
          modelIdentity: _identity);

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
      WebSearchResult(provider: 'noop', query: query, hits: const []);

  @override
  void close() {}
}
