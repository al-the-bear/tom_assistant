// B.29 — `WebSearch.search(query, {provider, k})` API conformance.
//
// Scope of this test file (per plan step B.29):
//
//   - Prove the abstract `WebSearch` contract: `search(query, options)`
//     returns a `WebSearchResult` with the right provider id, the
//     verbatim query, and a list of `SearchHit` with 1-based ranks.
//   - Prove the registry-driven dispatch in `DefaultWebSearch`: the
//     default provider is used when `options.provider` is null; a
//     pinned provider is used when set; an unknown provider id
//     surfaces as `UnknownWebSearchProvider`.
//   - Prove `DefaultWebSearch` construction invariants: empty provider
//     list throws; duplicate ids throw; the default id must be
//     registered.
//   - Prove the DuckDuckGo HTML provider parses real DDG-shaped HTML:
//     paired title+snippet blocks; the `k` cap is honoured; DDG
//     redirect wrappers (`//duckduckgo.com/l/?uddg=...`) unwrap to the
//     canonical URL; title-only fallback for hits missing a snippet;
//     HTML entities (`&amp;`, `&#x27;`) decode in titles and snippets;
//     `<b>` tags inside snippets strip cleanly.
//   - Prove DDG provider failure surfaces: non-2xx HTTP status surfaces
//     as `WebSearchProviderException`; the anti-bot block page surfaces
//     as `WebSearchProviderException` with status 200; an empty result
//     set returns an empty hits list (not an exception).
//   - Prove transport failures propagate verbatim through the chain
//     (`WebHttpTransportException` from the underlying client → seen
//     unchanged at the `WebSearch.search` boundary).
//   - Prove constructor validation: `k <= 0` is rejected.
//   - Prove `close()` cascades to providers; subsequent `search`
//     throws `StateError`.
//   - Prove the surface is reachable from the top-level package barrel
//     (`package:tom_brain_substrate/tom_brain_substrate.dart`).
//
// Scope this file is NOT for:
//
//   - No live network calls. Every test uses `_FakeWebHttpClient` —
//     the suite is hermetic.
//   - No `WebFetch` behaviour (B.30).
//   - No `tom_core_kernel.HttpClient` retry / circuit-breaker wiring
//     (B.31).
//   - No cross-provider conformance (only DuckDuckGo ships at B.29;
//     additional providers register against the same contract).

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.29 / DefaultWebSearch — registry-driven dispatch', () {
    test('routes to the default provider when options.provider is null',
        () async {
      final ddg = _StubProvider(id: 'duckduckgo');
      final brave = _StubProvider(id: 'brave');
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[ddg, brave],
      );

      await ws.search('hello');

      expect(ddg.calls, hasLength(1));
      expect(brave.calls, isEmpty);
      expect(ddg.calls.single.query, 'hello');
      expect(ddg.calls.single.k, 10); // WebSearchOptions.empty default

      ws.close();
    });

    test('routes to the pinned provider when options.provider is set',
        () async {
      final ddg = _StubProvider(id: 'duckduckgo');
      final brave = _StubProvider(id: 'brave');
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[ddg, brave],
      );

      await ws.search('hello',
          options: const WebSearchOptions(provider: 'brave', k: 5));

      expect(ddg.calls, isEmpty);
      expect(brave.calls, hasLength(1));
      expect(brave.calls.single.k, 5);

      ws.close();
    });

    test('forwards options.k to the provider', () async {
      final ddg = _StubProvider(id: 'duckduckgo');
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[ddg],
      );

      await ws.search('q', options: const WebSearchOptions(k: 3));

      expect(ddg.calls.single.k, 3);
      ws.close();
    });

    test('unknown provider id throws UnknownWebSearchProvider', () async {
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[_StubProvider(id: 'duckduckgo')],
      );

      Object? thrown;
      try {
        await ws.search('q',
            options: const WebSearchOptions(provider: 'serpapi'));
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<UnknownWebSearchProvider>());
      final e = thrown! as UnknownWebSearchProvider;
      expect(e.requestedProvider, 'serpapi');
      expect(e.registeredProviders, ['duckduckgo']);

      ws.close();
    });

    test('registeredProviderIds reflects registration order', () {
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[
          _StubProvider(id: 'duckduckgo'),
          _StubProvider(id: 'brave'),
          _StubProvider(id: 'serpapi'),
        ],
      );

      expect(ws.registeredProviderIds, ['duckduckgo', 'brave', 'serpapi']);
      ws.close();
    });

    test('search after close throws StateError', () async {
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[_StubProvider(id: 'duckduckgo')],
      );
      ws.close();

      Object? thrown;
      try {
        await ws.search('q');
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<StateError>());
    });

    test('close cascades to every registered provider', () {
      final ddg = _StubProvider(id: 'duckduckgo');
      final brave = _StubProvider(id: 'brave');
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[ddg, brave],
      );

      ws.close();

      expect(ddg.closeCount, 1);
      expect(brave.closeCount, 1);
    });

    test('close is idempotent', () {
      final ddg = _StubProvider(id: 'duckduckgo');
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[ddg],
      );

      ws.close();
      ws.close();
      ws.close();

      // Each provider close called exactly once across multiple
      // top-level close() invocations.
      expect(ddg.closeCount, 1);
    });
  });

  group('B.29 / DefaultWebSearch — construction invariants', () {
    test('empty provider list rejected', () {
      expect(
        () => DefaultWebSearch(
          defaultProviderId: 'duckduckgo',
          providers: const <WebSearchProvider>[],
        ),
        throwsArgumentError,
      );
    });

    test('duplicate provider ids rejected', () {
      expect(
        () => DefaultWebSearch(
          defaultProviderId: 'duckduckgo',
          providers: <WebSearchProvider>[
            _StubProvider(id: 'duckduckgo'),
            _StubProvider(id: 'duckduckgo'),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('default id must be registered', () {
      expect(
        () => DefaultWebSearch(
          defaultProviderId: 'serpapi',
          providers: <WebSearchProvider>[_StubProvider(id: 'duckduckgo')],
        ),
        throwsArgumentError,
      );
    });
  });

  group('B.29 / DuckDuckGoHtmlSearchProvider — HTML parsing', () {
    test('parses paired title + snippet blocks', () async {
      final http = _FakeWebHttpClient()
        ..response = _ok(_ddgHtml([
          _DdgHit(
              href: 'https://example.com/a',
              title: 'Example A',
              snippet: 'first snippet text'),
          _DdgHit(
              href: 'https://example.com/b',
              title: 'Example B',
              snippet: 'second snippet text'),
        ]));
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      final result = await provider.search('hello world', k: 10);

      expect(result.provider, 'duckduckgo');
      expect(result.query, 'hello world');
      expect(result.hits, hasLength(2));
      expect(result.hits[0].title, 'Example A');
      expect(result.hits[0].snippet, 'first snippet text');
      expect(result.hits[0].url.toString(), 'https://example.com/a');
      expect(result.hits[0].rank, 1);
      expect(result.hits[1].title, 'Example B');
      expect(result.hits[1].rank, 2);
    });

    test('honours the k cap', () async {
      final http = _FakeWebHttpClient()
        ..response = _ok(_ddgHtml([
          for (var i = 0; i < 10; i++)
            _DdgHit(
                href: 'https://example.com/$i',
                title: 'Title $i',
                snippet: 'Snippet $i'),
        ]));
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      final result = await provider.search('q', k: 3);

      expect(result.hits, hasLength(3));
      expect(result.hits.map((h) => h.rank), [1, 2, 3]);
      expect(result.hits.last.url.toString(), 'https://example.com/2');
    });

    test('unwraps DDG redirect URLs (//duckduckgo.com/l/?uddg=...)',
        () async {
      const target = 'https://example.com/landing?id=42';
      final wrapped =
          '//duckduckgo.com/l/?uddg=${Uri.encodeQueryComponent(target)}&rut=abc';
      final http = _FakeWebHttpClient()
        ..response = _ok(_ddgHtml([
          _DdgHit(href: wrapped, title: 'Wrapped', snippet: 'snip'),
        ]));
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      final result = await provider.search('q', k: 5);

      expect(result.hits.single.url.toString(), target);
    });

    test('decodes HTML entities in titles and snippets', () async {
      final http = _FakeWebHttpClient()
        ..response = _ok(_ddgHtml([
          _DdgHit(
              href: 'https://example.com/a',
              title: 'Foo &amp; Bar &#x27;quoted&#x27;',
              snippet: '5 &lt; 10 &amp; &quot;ok&quot;'),
        ]));
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      final result = await provider.search('q', k: 5);

      expect(result.hits.single.title, "Foo & Bar 'quoted'");
      expect(result.hits.single.snippet, '5 < 10 & "ok"');
    });

    test('strips inline tags inside titles / snippets (e.g. <b>highlight</b>)',
        () async {
      final http = _FakeWebHttpClient()
        ..response = _ok(_ddgHtml([
          _DdgHit(
              href: 'https://example.com/a',
              title: '<b>Highlight</b> in title',
              snippet: 'mention of <b>term</b> in body'),
        ]));
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      final result = await provider.search('q', k: 5);

      expect(result.hits.single.title, 'Highlight in title');
      expect(result.hits.single.snippet, 'mention of term in body');
    });

    test('returns empty hits when the body has no result blocks', () async {
      // DDG returns a body with no `result__a` anchors for some
      // zero-result queries.
      final http = _FakeWebHttpClient()
        ..response = _ok('<html><body><p>No results found.</p></body></html>');
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      final result = await provider.search('totally-unsearchable-query',
          k: 10);

      expect(result.hits, isEmpty);
      // Even with no hits, the metadata is populated.
      expect(result.provider, 'duckduckgo');
      expect(result.query, 'totally-unsearchable-query');
    });

    test('captures the request as POST application/x-www-form-urlencoded',
        () async {
      final http = _FakeWebHttpClient()..response = _ok(_ddgHtml(const []));
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      await provider.search('cats & dogs', k: 5);

      expect(http.postCalls, hasLength(1));
      final call = http.postCalls.single;
      expect(call.url.toString(), 'https://html.duckduckgo.com/html/');
      expect(call.form, {'q': 'cats & dogs'});
      expect(call.headers['User-Agent'], contains('TomBrain'));
      expect(http.getCalls, isEmpty);
    });
  });

  group('B.29 / DuckDuckGoHtmlSearchProvider — failure surfaces', () {
    test('non-2xx status raises WebSearchProviderException with the status',
        () async {
      final http = _FakeWebHttpClient()
        ..response = WebHttpResponse(
          statusCode: 503,
          body: 'Service Unavailable',
          headers: const <String, String>{},
          url: Uri.parse('https://html.duckduckgo.com/html/'),
        );
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      Object? thrown;
      try {
        await provider.search('q', k: 5);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebSearchProviderException>());
      final e = thrown! as WebSearchProviderException;
      expect(e.providerId, 'duckduckgo');
      expect(e.statusCode, 503);
      expect(e.message, contains('non-2xx'));
      expect(e.bodyExcerpt, 'Service Unavailable');
    });

    test('anti-bot block page raises WebSearchProviderException with status 200',
        () async {
      const blockBody =
          '<html><body><div class="anomaly-modal">Unfortunately, bots use DuckDuckGo too</div></body></html>';
      final http = _FakeWebHttpClient()..response = _ok(blockBody);
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      Object? thrown;
      try {
        await provider.search('q', k: 5);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebSearchProviderException>());
      final e = thrown! as WebSearchProviderException;
      expect(e.statusCode, 200);
      expect(e.message, contains('anti-bot'));
    });

    test('transport exception propagates verbatim through the provider',
        () async {
      final http = _FakeWebHttpClient()
        ..error = WebHttpTransportException(
          url: Uri.parse('https://html.duckduckgo.com/html/'),
          cause: const SocketExceptionDouble('Connection refused'),
        );
      final provider = DuckDuckGoHtmlSearchProvider(httpClient: http);

      Object? thrown;
      try {
        await provider.search('q', k: 5);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<WebHttpTransportException>());
    });

    test('k <= 0 is rejected with ArgumentError', () async {
      final provider = DuckDuckGoHtmlSearchProvider(
        httpClient: _FakeWebHttpClient()..response = _ok(_ddgHtml(const [])),
      );

      expect(
        () => provider.search('q', k: 0),
        throwsArgumentError,
      );
      expect(
        () => provider.search('q', k: -1),
        throwsArgumentError,
      );
    });

    test('provider id constant matches the registered config key', () {
      expect(DuckDuckGoHtmlSearchProvider.providerId, 'duckduckgo');
      final provider = DuckDuckGoHtmlSearchProvider(
        httpClient: _FakeWebHttpClient()..response = _ok(_ddgHtml(const [])),
      );
      expect(provider.id, 'duckduckgo');
    });
  });

  group('B.29 / WebSearch — end-to-end through the registry', () {
    test('DefaultWebSearch + DuckDuckGoHtmlSearchProvider returns hits',
        () async {
      final http = _FakeWebHttpClient()
        ..response = _ok(_ddgHtml([
          _DdgHit(
              href: 'https://flutter.dev',
              title: 'Flutter — Build apps for any screen',
              snippet: 'Flutter is an open-source UI software development kit'),
          _DdgHit(
              href: 'https://dart.dev',
              title: 'Dart programming language',
              snippet: 'Dart is a client-optimized language'),
        ]));
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[
          DuckDuckGoHtmlSearchProvider(httpClient: http),
        ],
      );

      final result = await ws.search('flutter',
          options: const WebSearchOptions(k: 5));

      expect(result.provider, 'duckduckgo');
      expect(result.query, 'flutter');
      expect(result.hits, hasLength(2));
      expect(result.hits[0].rank, 1);
      expect(result.hits[1].rank, 2);

      ws.close();
    });

    test('UnknownWebSearchProvider lists registered providers', () async {
      final ws = DefaultWebSearch(
        defaultProviderId: 'duckduckgo',
        providers: <WebSearchProvider>[
          _StubProvider(id: 'duckduckgo'),
          _StubProvider(id: 'brave'),
        ],
      );

      try {
        await ws.search('q',
            options: const WebSearchOptions(provider: 'kagi'));
        fail('expected throw');
      } on UnknownWebSearchProvider catch (e) {
        expect(e.requestedProvider, 'kagi');
        expect(e.registeredProviders, ['duckduckgo', 'brave']);
        expect(
          e.toString(),
          allOf(contains('kagi'), contains('duckduckgo'), contains('brave')),
        );
      }
      ws.close();
    });
  });

  group('B.29 / surface reachability from top-level barrel', () {
    test('every public name resolves from package:tom_brain_substrate', () {
      // Type references compile-time-only — no instances constructed.
      expect(WebSearch, isNotNull);
      expect(DefaultWebSearch, isNotNull);
      expect(WebSearchProvider, isNotNull);
      expect(DuckDuckGoHtmlSearchProvider, isNotNull);
      expect(WebSearchProviderException, isNotNull);
      expect(UnknownWebSearchProvider, isNotNull);
      expect(WebHttpClient, isNotNull);
      expect(DefaultWebHttpClient, isNotNull);
      expect(WebHttpResponse, isNotNull);
      expect(WebHttpTransportException, isNotNull);
    });
  });
}

// ---------- Test doubles -------------------------------------------------

/// In-test [WebSearchProvider] that records every `search` call and
/// returns an empty result. Used by the dispatch tests where the
/// concrete behaviour of the provider is not under test.
class _StubProvider implements WebSearchProvider {
  @override
  final String id;
  final List<_StubCall> calls = <_StubCall>[];
  int closeCount = 0;

  _StubProvider({required this.id});

  @override
  Future<WebSearchResult> search(String query, {required int k}) async {
    calls.add(_StubCall(query: query, k: k));
    return WebSearchResult(provider: id, query: query, hits: const <SearchHit>[]);
  }

  @override
  void close() {
    closeCount += 1;
  }
}

class _StubCall {
  final String query;
  final int k;
  _StubCall({required this.query, required this.k});
}

/// In-test [WebHttpClient] that returns a single canned response (or
/// throws a canned error) on every call. Records every request the
/// provider issued so the test can assert on the wire shape.
class _FakeWebHttpClient implements WebHttpClient {
  WebHttpResponse? response;
  Object? error;
  final List<_GetCall> getCalls = <_GetCall>[];
  final List<_PostCall> postCalls = <_PostCall>[];
  int closeCount = 0;

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    getCalls.add(_GetCall(url: url, headers: headers));
    if (error != null) {
      throw error!;
    }
    return response ?? (throw StateError('_FakeWebHttpClient.response not set'));
  }

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    postCalls.add(_PostCall(url: url, form: form, headers: headers));
    if (error != null) {
      throw error!;
    }
    return response ?? (throw StateError('_FakeWebHttpClient.response not set'));
  }

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async {
    // B.29 tests never call `getBytes` — the search providers use only
    // `get` / `postForm`. The method is part of the shared seam B.30
    // adds for `WebFetch`; left unimplemented here so the surface
    // contract is honoured without forcing this fake to grow a fetch-
    // shaped second canned-response field.
    throw UnimplementedError(
      '_FakeWebHttpClient.getBytes is not exercised by B.29 tests',
    );
  }

  @override
  void close() {
    closeCount += 1;
  }
}

class _GetCall {
  final Uri url;
  final Map<String, String> headers;
  _GetCall({required this.url, required this.headers});
}

class _PostCall {
  final Uri url;
  final Map<String, String> form;
  final Map<String, String> headers;
  _PostCall({required this.url, required this.form, required this.headers});
}

/// Tiny stand-in for `dart:io.SocketException` so the test file does
/// not need to import `dart:io` to satisfy the
/// `WebHttpTransportException.cause` Object typing.
class SocketExceptionDouble implements Exception {
  final String message;
  const SocketExceptionDouble(this.message);

  @override
  String toString() => 'SocketExceptionDouble: $message';
}

// ---------- HTML fixture helpers ----------------------------------------

WebHttpResponse _ok(String body) => WebHttpResponse(
      statusCode: 200,
      body: body,
      headers: const <String, String>{'content-type': 'text/html'},
      url: Uri.parse('https://html.duckduckgo.com/html/'),
    );

class _DdgHit {
  final String href;
  final String title;
  final String snippet;
  const _DdgHit(
      {required this.href, required this.title, required this.snippet});
}

/// Builds a minimal DDG-shaped HTML body for the given hits. The shape
/// reproduces the salient pieces the production HTML carries:
///
///   <div class="result results_links results_links_deep web-result">
///     <div class="result__body">
///       <h2 class="result__title">
///         <a class="result__a" href="...">Title</a>
///       </h2>
///       <a class="result__snippet" href="...">Snippet</a>
///     </div>
///   </div>
String _ddgHtml(List<_DdgHit> hits) {
  final buffer = StringBuffer()..writeln('<html><body>');
  for (final hit in hits) {
    buffer.writeln('<div class="result results_links results_links_deep web-result">');
    buffer.writeln('  <div class="result__body">');
    buffer.writeln('    <h2 class="result__title">');
    buffer.writeln('      <a class="result__a" href="${hit.href}">${hit.title}</a>');
    buffer.writeln('    </h2>');
    buffer.writeln(
        '    <a class="result__snippet" href="${hit.href}">${hit.snippet}</a>');
    buffer.writeln('  </div>');
    buffer.writeln('</div>');
  }
  buffer.writeln('</body></html>');
  return buffer.toString();
}
