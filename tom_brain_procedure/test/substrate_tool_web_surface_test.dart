// SubstrateToolWebSurface — adapts the substrate web client into the narrow
// ToolWebSurface the `web.*` tools route through (§ 21.4).
//
// The adapter must (a) forward `search`/`fetch` to the substrate CLIENT (never
// the budget-charging bridge), passing `k`/`budgetBytes` through, and (b) shape
// the typed `WebSearchResult` / `WebFetchResult` into the same plain JSON map
// the scripted `sub.search` / `sub.fetch` bridge produces.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

/// Captures the calls the adapter makes; primes the results it returns.
class _FakeSubstrateClient implements TomBrainSubstrateClient {
  String? lastSearchQuery;
  WebSearchOptions? lastSearchOptions;
  WebSearchResult searchResult = const WebSearchResult(
    provider: 'duckduckgo',
    query: 'q',
    hits: <SearchHit>[],
  );

  Uri? lastFetchUrl;
  WebFetchOptions? lastFetchOptions;
  WebFetchResult fetchResult = WebFetchResult(
    url: Uri.parse('https://example.com'),
    status: 200,
    contentType: 'text/plain',
    text: 'body',
  );

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    lastSearchQuery = query;
    lastSearchOptions = options;
    return searchResult;
  }

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    lastFetchUrl = url;
    lastFetchOptions = options;
    return fetchResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  group('SubstrateToolWebSurface', () {
    test('search forwards query + k and shapes the hit map', () async {
      final client = _FakeSubstrateClient()
        ..searchResult = WebSearchResult(
          provider: 'duckduckgo',
          query: 'dart lang',
          hits: <SearchHit>[
            SearchHit(
              title: 'Dart',
              url: Uri.parse('https://dart.dev'),
              snippet: 'The Dart language',
              rank: 1,
            ),
          ],
        );
      final surface = SubstrateToolWebSurface(client);

      final result = await surface.search('dart lang', k: 5);

      expect(client.lastSearchQuery, 'dart lang');
      expect(client.lastSearchOptions!.k, 5);
      expect(result['provider'], 'duckduckgo');
      expect(result['query'], 'dart lang');
      final hits = result['hits'] as List<Object?>;
      expect(hits, hasLength(1));
      expect(hits.single, <String, Object?>{
        'title': 'Dart',
        'url': 'https://dart.dev',
        'snippet': 'The Dart language',
        'rank': 1,
      });
    });

    test('search defaults k to 10 when omitted', () async {
      final client = _FakeSubstrateClient();
      final surface = SubstrateToolWebSurface(client);

      await surface.search('q');

      expect(client.lastSearchOptions!.k, 10);
    });

    test('fetch forwards url + budgetBytes and shapes the text map', () async {
      final client = _FakeSubstrateClient()
        ..fetchResult = WebFetchResult(
          url: Uri.parse('https://dart.dev/'),
          status: 200,
          contentType: 'text/html',
          text: 'Hello',
          truncated: true,
        );
      final surface = SubstrateToolWebSurface(client);

      final result = await surface.fetch('https://dart.dev', budgetBytes: 2048);

      expect(client.lastFetchUrl, Uri.parse('https://dart.dev'));
      expect(client.lastFetchOptions!.budgetBytes, 2048);
      expect(result, <String, Object?>{
        'url': 'https://dart.dev/',
        'status': 200,
        'contentType': 'text/html',
        'truncated': true,
        'text': 'Hello',
      });
    });

    test('fetch shapes a binary result with its meta and no text/json',
        () async {
      final client = _FakeSubstrateClient()
        ..fetchResult = WebFetchResult(
          url: Uri.parse('https://example.com/x.bin'),
          status: 200,
          contentType: 'application/octet-stream',
          binaryMeta: const BinaryFetchMeta(
            contentType: 'application/octet-stream',
            contentLength: 1234,
          ),
        );
      final surface = SubstrateToolWebSurface(client);

      final result = await surface.fetch('https://example.com/x.bin');

      expect(result['text'], isNull);
      expect(result['json'], isNull);
      expect(result['binaryMeta'], <String, Object?>{
        'contentType': 'application/octet-stream',
        'contentLength': 1234,
      });
    });

    test('fetch shapes a json result', () async {
      final client = _FakeSubstrateClient()
        ..fetchResult = WebFetchResult(
          url: Uri.parse('https://api.example.com'),
          status: 200,
          contentType: 'application/json',
          json: <String, Object?>{'ok': true},
        );
      final surface = SubstrateToolWebSurface(client);

      final result = await surface.fetch('https://api.example.com');

      expect(result['json'], <String, Object?>{'ok': true});
      expect(result.containsKey('text'), isFalse);
    });
  });
}
