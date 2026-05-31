// B.32 — Cross-implementation conformance suite for the substrate's
// web tools: `WebSearch` (B.29) + `WebFetch` (B.30).
//
// `prototype_implementation_plan.md` step B.32 (verbatim):
//
//   > Tests: search returns structured results; fetch respects the
//   > budget; large-page fetch truncates to the budget; non-200
//   > surfaces as a typed error.
//
// Scope of this file:
//
//   The per-impl suites at `test/b29_*` and `test/b30_*` already
//   exercise the wire-shape details of the shipped concrete
//   implementations (DDG HTML parsing, exact header merge order, k-cap
//   truncation, JSON dispatch, PDF refusal, etc.). This file lifts the
//   four plan-specified guarantees onto the abstract `WebSearch` /
//   `WebFetch` contracts and runs them against *every* registered
//   implementation harness — so a future Brave / Tavily provider or a
//   cache-layer `WebFetch` variant gets cross-impl coverage by
//   registering one harness class below `main()`, with zero changes to
//   the contract driver.
//
//   This is the harness pattern from `b28_embedding_service_conformance_test.dart`
//   (Q-B.29.6 and Q-B.30.7 both recommend adopting it).
//
// What is on contract at B.32 (the four plan-specified guarantees):
//
//   1. **Search returns structured results.** `WebSearch.search(q)`
//      returns a `WebSearchResult` whose `provider`/`query` round-trip
//      verbatim and whose `hits` are well-formed `SearchHit` records
//      (1-based ranks in engine order, `url` is a `Uri`, `title` and
//      `snippet` are strings). Empty result sets return as an empty
//      `hits` list — not as an exception.
//
//   2. **Fetch respects the budget.** When the response body fits
//      within the caller-supplied `WebFetchOptions.budgetBytes`,
//      `WebFetch.fetch(url, options)` returns a
//      `WebFetchResult` with `truncated: false` and a full body.
//
//   3. **Large-page fetch truncates to the budget.** When the
//      response body exceeds the caller-supplied budget,
//      `WebFetch.fetch(url, options)` returns
//      `WebFetchResult.truncated: true` with at most `budgetBytes` of
//      body (text or JSON path; we use plain-text bodies to keep the
//      contract decode-agnostic). The substrate MUST NOT surface
//      truncation as an exception — the partial body is the caller's
//      decision to act on.
//
//   4. **Non-200 surfaces as a typed error.** For `WebFetch`, a
//      non-2xx HTTP response surfaces as `WebFetchHttpException` with
//      the verbatim status code. For `WebSearch`, a provider-side
//      engine error surfaces as `WebSearchProviderException` (the
//      substrate's typed-error answer to "the search did not return
//      structured results"). Both errors stay inside the substrate's
//      typed-error taxonomy — no raw `http`-layer exceptions leak.
//
// What is NOT on contract at B.32:
//
//   - Concrete wire shapes (DDG HTML structure, `+json` content-type
//     dispatch nuances, anti-bot heuristic, redirect URL unwrap).
//     Those bind to specific provider / impl semantics and live in
//     the per-impl suites.
//   - Retry / circuit-breaker behaviour (B.31 lives one layer up).
//   - Lifecycle invariants (close-cascade, idempotency) — pinned by
//     the per-impl suites and not part of the plan-step's four
//     contract assertions.
//
// Design:
//
//   - Two harness interfaces (`_WebSearchHarness`, `_WebFetchHarness`)
//     own a `service` plus a small priming surface that lets the
//     contract driver inject the next response (structured hits,
//     full-body fetch, truncated-body fetch, typed-error fetch).
//   - Two harnesses per tool register today:
//       * Search: `_DefaultDdgHarness` (the production stack —
//         `DefaultWebSearch` over `DuckDuckGoHtmlSearchProvider` over a
//         fake `WebHttpClient`) and `_DirectStubSearchHarness` (a
//         minimal in-test `WebSearch` impl that takes prepared answers
//         directly, no dispatch layer, no DDG parse logic).
//       * Fetch: `_DefaultFetchHarness` (the production
//         `DefaultWebFetch` over a budget-aware fake `WebHttpClient`)
//         and `_DirectStubFetchHarness` (a minimal in-test `WebFetch`
//         impl that honours the contract directly).
//     The stub harnesses anchor the contract on a second concrete
//     impl: if a contract assertion quietly only holds for the default
//     impl, the stub run fails too. Adding a real second backend
//     (Brave, Tavily, cache-layer fetch) is a one-class drop-in.
//   - The contract drivers (`_runSearchConformance`,
//     `_runFetchConformance`) register one outer `group(...)` per
//     harness and the same set of contract assertions under each, so
//     an edit to a contract test lands against every impl in one
//     place — same convention as B.28.

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.32 / WebSearch / DefaultWebSearch+DDG', () {
    _runSearchConformance(_DefaultDdgHarness.new);
  });
  group('B.32 / WebSearch / DirectStubWebSearch (test fixture)', () {
    _runSearchConformance(_DirectStubSearchHarness.new);
  });

  group('B.32 / WebFetch / DefaultWebFetch', () {
    _runFetchConformance(_DefaultFetchHarness.new);
  });
  group('B.32 / WebFetch / DirectStubWebFetch (test fixture)', () {
    _runFetchConformance(_DirectStubFetchHarness.new);
  });
}

// ─── Search contract driver ────────────────────────────────────────────

typedef _SearchHarnessBuilder = _WebSearchHarness Function();

void _runSearchConformance(_SearchHarnessBuilder buildHarness) {
  group('contract — search returns structured results', () {
    test('non-empty result carries provider, query, and hits verbatim',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeHits([
        SearchHit(
          title: 'Tom Brain',
          url: Uri.parse('https://example.com/tom-brain'),
          snippet: 'cognition layer for Tom Assistant',
          rank: 1,
        ),
        SearchHit(
          title: 'Substrate',
          url: Uri.parse('https://example.com/substrate'),
          snippet: 'LLM router + provider abstraction',
          rank: 2,
        ),
      ]);

      final result = await h.service.search('tom brain substrate');

      expect(result.provider, h.expectedProviderId);
      expect(result.query, 'tom brain substrate');
      expect(result.hits, hasLength(2));
    });

    test('hits carry well-formed fields (title/snippet strings, url Uri, '
        '1-based ranks in engine order)', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeHits([
        SearchHit(
          title: 'first',
          url: Uri.parse('https://example.com/a'),
          snippet: 'snippet a',
          rank: 1,
        ),
        SearchHit(
          title: 'second',
          url: Uri.parse('https://example.com/b'),
          snippet: 'snippet b',
          rank: 2,
        ),
        SearchHit(
          title: 'third',
          url: Uri.parse('https://example.com/c'),
          snippet: 'snippet c',
          rank: 3,
        ),
      ]);

      final result = await h.service.search('any query');

      expect(result.hits.map((h) => h.rank), [1, 2, 3],
          reason: 'ranks must be 1-based and preserve engine order; '
              'consumers re-rank without losing the original order');
      for (final hit in result.hits) {
        expect(hit.title, isA<String>());
        expect(hit.snippet, isA<String>());
        expect(hit.url, isA<Uri>());
      }
    });

    test('empty result returns empty hits, not an exception', () async {
      // Substrate § 8.1 + the WebSearch class doc: "no results" is a
      // legitimate engine answer, not a failure mode.
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeHits(const <SearchHit>[]);

      final result = await h.service.search('zero-result query');

      expect(result.hits, isEmpty);
      expect(result.query, 'zero-result query');
      expect(result.provider, h.expectedProviderId);
    });
  });

  group('contract — non-200 surfaces as a typed error', () {
    test('engine-side error raises WebSearchProviderException with the '
        'engine id and status code', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeProviderException(WebSearchProviderException(
        providerId: h.expectedProviderId,
        statusCode: 503,
        message: 'service unavailable',
        bodyExcerpt: 'maintenance',
      ));

      await expectLater(
        () => h.service.search('triggers error'),
        throwsA(isA<WebSearchProviderException>()
            .having((e) => e.providerId, 'providerId', h.expectedProviderId)
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('engine-side error on a 200 body still surfaces as the typed '
        'exception (no demotion to a generic throw)', () async {
      // Some engines wrap engine errors inside a 200 OK body (DDG's
      // anti-bot page is the canonical example). The substrate's
      // contract is that those still fire `WebSearchProviderException`
      // — whether the impl carries the underlying 200 in `statusCode`
      // or leaves it null is an impl choice (DDG forwards 200; other
      // impls may set null when the engine error is inferred without
      // an HTTP response). The contract asserts only the typed-throw
      // and the providerId.
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeProviderException(WebSearchProviderException(
        providerId: h.expectedProviderId,
        message: 'anti-bot block page',
      ));

      await expectLater(
        () => h.service.search('q'),
        throwsA(isA<WebSearchProviderException>()
            .having((e) => e.providerId, 'providerId', h.expectedProviderId)),
      );
    });
  });
}

// ─── Fetch contract driver ─────────────────────────────────────────────

typedef _FetchHarnessBuilder = _WebFetchHarness Function();

void _runFetchConformance(_FetchHarnessBuilder buildHarness) {
  group('contract — fetch respects the budget (body within budget)', () {
    test('body within budget → truncated=false and full body returned',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      const body = 'hello world — fits in the budget';
      h.primeTextBody(body, contentType: 'text/plain');

      final result = await h.service.fetch(
        Uri.parse('https://example.com/ok'),
        options: const WebFetchOptions(budgetBytes: 1024),
      );

      expect(result.truncated, isFalse);
      expect(result.text, body);
      expect(result.status, 200);
    });
  });

  group('contract — large-page fetch truncates to the budget', () {
    test('body larger than budget → truncated=true and body length ≤ budget',
        () async {
      // 8 KiB body, 1 KiB budget. The contract: truncated=true, and
      // the surfaced text is at most budget bytes (we encode ASCII so
      // bytes == characters).
      final h = buildHarness();
      addTearDown(h.dispose);

      final body = 'x' * (8 * 1024);
      h.primeTextBody(body, contentType: 'text/plain');

      final result = await h.service.fetch(
        Uri.parse('https://example.com/big'),
        options: const WebFetchOptions(budgetBytes: 1024),
      );

      expect(result.truncated, isTrue,
          reason: 'truncation MUST be observable to the caller');
      expect(result.text, isNotNull);
      expect(utf8.encode(result.text!).length, lessThanOrEqualTo(1024),
          reason: 'returned body must not exceed the requested budget');
    });

    test('large body + zero budget → truncated=true and (near-)empty text',
        () async {
      // Edge case: caller asks for 0 bytes. The substrate should still
      // surface a typed result with truncated=true rather than raising.
      final h = buildHarness();
      addTearDown(h.dispose);

      final body = 'y' * 4096;
      h.primeTextBody(body, contentType: 'text/plain');

      final result = await h.service.fetch(
        Uri.parse('https://example.com/zero'),
        options: const WebFetchOptions(budgetBytes: 0),
      );

      expect(result.truncated, isTrue);
      expect(result.text, isNotNull);
      expect(utf8.encode(result.text!).length, lessThanOrEqualTo(0));
    });
  });

  group('contract — non-200 surfaces as a typed error', () {
    test('404 raises WebFetchHttpException with the verbatim status code',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeNon200(statusCode: 404, contentType: 'text/plain');

      await expectLater(
        () => h.service.fetch(Uri.parse('https://example.com/missing')),
        throwsA(isA<WebFetchHttpException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('503 raises WebFetchHttpException with the verbatim status code',
        () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeNon200(statusCode: 503, contentType: 'text/plain');

      await expectLater(
        () => h.service.fetch(Uri.parse('https://example.com/down')),
        throwsA(isA<WebFetchHttpException>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('non-2xx never returns a WebFetchResult — typed throw is mandatory',
        () async {
      // Defence against an impl that "softens" non-2xx into a result
      // (e.g. by setting `truncated: true` on a 500 body). The contract
      // is sharp: a non-2xx HTTP response on the fetch path is a typed
      // exception, period.
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeNon200(statusCode: 500, contentType: 'text/plain');

      Object? caught;
      try {
        await h.service.fetch(Uri.parse('https://example.com/boom'));
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<WebFetchHttpException>());
    });
  });

  group('contract — structured fetch result', () {
    test('full-body fetch returns WebFetchResult with url, status, '
        'contentType set', () async {
      final h = buildHarness();
      addTearDown(h.dispose);

      h.primeTextBody('hello', contentType: 'text/plain');

      final url = Uri.parse('https://example.com/structured');
      final result = await h.service.fetch(url);

      expect(result.url, url);
      expect(result.status, 200);
      expect(result.contentType, 'text/plain');
      expect(result.text, 'hello');
      expect(result.json, isNull);
      expect(result.binaryMeta, isNull);
    });
  });
}

// ─── Search harness contract ───────────────────────────────────────────

abstract class _WebSearchHarness {
  WebSearch get service;

  /// The provider id the implementation will stamp on its
  /// [WebSearchResult.provider] field. The DDG-backed harness reports
  /// `duckduckgo`; the stub harness reports whatever id it was
  /// constructed with.
  String get expectedProviderId;

  /// Prime the engine: the next [WebSearch.search] call returns a
  /// result whose hits are exactly [hits] (engine order, ranks
  /// preserved).
  void primeHits(List<SearchHit> hits);

  /// Prime the engine: the next [WebSearch.search] call throws
  /// [exception] verbatim.
  void primeProviderException(WebSearchProviderException exception);

  Future<void> dispose();
}

// ─── Search harness 1: production DefaultWebSearch + DDG over a fake
//     WebHttpClient that produces DDG-flavoured HTML or engine errors.

class _DefaultDdgHarness implements _WebSearchHarness {
  late final _DdgHarnessFakeHttp _fakeHttp;
  late final DefaultWebSearch _engine;

  _DefaultDdgHarness() {
    _fakeHttp = _DdgHarnessFakeHttp();
    _engine = DefaultWebSearch(
      defaultProviderId: DuckDuckGoHtmlSearchProvider.providerId,
      providers: [
        DuckDuckGoHtmlSearchProvider(httpClient: _fakeHttp),
      ],
    );
  }

  @override
  WebSearch get service => _engine;

  @override
  String get expectedProviderId =>
      DuckDuckGoHtmlSearchProvider.providerId;

  @override
  void primeHits(List<SearchHit> hits) {
    _fakeHttp.response = WebHttpResponse(
      statusCode: 200,
      body: _ddgHtmlFor(hits),
      headers: const <String, String>{'content-type': 'text/html'},
      url: Uri.parse('https://html.duckduckgo.com/html/'),
    );
    _fakeHttp.error = null;
  }

  @override
  void primeProviderException(WebSearchProviderException exception) {
    if (exception.statusCode != null) {
      // Engine returned a non-2xx HTTP response. DDG provider
      // converts that into a WebSearchProviderException with
      // the verbatim status code.
      _fakeHttp.response = WebHttpResponse(
        statusCode: exception.statusCode!,
        body: exception.bodyExcerpt,
        headers: const <String, String>{'content-type': 'text/html'},
        url: Uri.parse('https://html.duckduckgo.com/html/'),
      );
      _fakeHttp.error = null;
    } else {
      // Engine returned a 200 body containing an anti-bot block page
      // (the canonical "status 200 but typed error" case for DDG).
      _fakeHttp.response = WebHttpResponse(
        statusCode: 200,
        body: '<html><body><div class="anomaly-modal" id="anomaly_dl_modal">'
            'Unfortunately, bots use DuckDuckGo too. We need to verify…'
            '</div></body></html>',
        headers: const <String, String>{'content-type': 'text/html'},
        url: Uri.parse('https://html.duckduckgo.com/html/'),
      );
      _fakeHttp.error = null;
    }
  }

  @override
  Future<void> dispose() async {
    _engine.close();
  }

  /// Build a minimal-but-realistic DDG HTML body from a list of
  /// `SearchHit`s. The DDG parser is regex-based and anchors on
  /// `result__a` / `result__snippet`; reproducing that shape is
  /// sufficient for the contract assertions (we are not testing the
  /// parser here, only that the engine surfaces the parsed hits).
  String _ddgHtmlFor(List<SearchHit> hits) {
    if (hits.isEmpty) {
      return '<html><body><div class="results"></div></body></html>';
    }
    final buf = StringBuffer('<html><body>');
    for (final h in hits) {
      buf.write('<div class="result results_links">');
      buf.write('<h2 class="result__title">');
      buf.write(
          '<a class="result__a" href="${h.url.toString()}">${_htmlEscape(h.title)}</a>');
      buf.write('</h2>');
      buf.write(
          '<a class="result__snippet" href="${h.url.toString()}">${_htmlEscape(h.snippet)}</a>');
      buf.write('</div>');
    }
    buf.write('</body></html>');
    return buf.toString();
  }

  String _htmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

class _DdgHarnessFakeHttp implements WebHttpClient {
  WebHttpResponse? response;
  Object? error;

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    if (error != null) throw error!;
    return response ??
        (throw StateError('_DdgHarnessFakeHttp.response not set'));
  }

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    if (error != null) throw error!;
    return response ??
        (throw StateError('_DdgHarnessFakeHttp.response not set'));
  }

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async =>
      throw UnimplementedError(
        '_DdgHarnessFakeHttp.getBytes is not exercised by the search harness',
      );

  @override
  void close() {}
}

// ─── Search harness 2: direct in-test stub `WebSearch` implementation
//     that bypasses `DefaultWebSearch` / `WebSearchProvider` entirely.

class _DirectStubSearchHarness implements _WebSearchHarness {
  static const String _stubId = 'stub-search';
  final _DirectStubWebSearch _service = _DirectStubWebSearch(_stubId);

  @override
  WebSearch get service => _service;

  @override
  String get expectedProviderId => _stubId;

  @override
  void primeHits(List<SearchHit> hits) {
    _service.primedHits = hits;
    _service.primedException = null;
  }

  @override
  void primeProviderException(WebSearchProviderException exception) {
    _service.primedHits = null;
    _service.primedException = exception;
  }

  @override
  Future<void> dispose() async {
    _service.close();
  }
}

class _DirectStubWebSearch implements WebSearch {
  final String providerId;
  List<SearchHit>? primedHits;
  WebSearchProviderException? primedException;
  bool _closed = false;

  _DirectStubWebSearch(this.providerId);

  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    if (_closed) {
      throw StateError('_DirectStubWebSearch.search after close()');
    }
    if (primedException != null) {
      throw primedException!;
    }
    final hits = primedHits ?? const <SearchHit>[];
    final capped = hits.length > options.k ? hits.sublist(0, options.k) : hits;
    return WebSearchResult(
      provider: providerId,
      query: query,
      hits: capped,
    );
  }

  @override
  void close() {
    _closed = true;
  }
}

// ─── Fetch harness contract ────────────────────────────────────────────

abstract class _WebFetchHarness {
  WebFetch get service;

  /// Prime the next [WebFetch.fetch] call: returns a 200 response
  /// with the given UTF-8 body and content-type, honouring the
  /// caller's budget (if [body.length] ≤ budget, returns the full
  /// body with `truncated: false`; otherwise returns the first
  /// `budget` bytes with `truncated: true`).
  void primeTextBody(String body, {required String contentType});

  /// Prime the next [WebFetch.fetch] call: returns a non-2xx response
  /// that the engine surfaces as `WebFetchHttpException`.
  void primeNon200({
    required int statusCode,
    String? contentType,
    String body = '',
  });

  Future<void> dispose();
}

// ─── Fetch harness 1: production DefaultWebFetch over a budget-aware
//     fake WebHttpClient.

class _DefaultFetchHarness implements _WebFetchHarness {
  late final _BudgetAwareFakeHttp _fakeHttp;
  late final DefaultWebFetch _engine;

  _DefaultFetchHarness() {
    _fakeHttp = _BudgetAwareFakeHttp();
    _engine = DefaultWebFetch(httpClient: _fakeHttp);
  }

  @override
  WebFetch get service => _engine;

  @override
  void primeTextBody(String body, {required String contentType}) {
    _fakeHttp.primedBytes = utf8.encode(body);
    _fakeHttp.primedContentType = contentType;
    _fakeHttp.primedStatus = 200;
    _fakeHttp.primedError = null;
  }

  @override
  void primeNon200({
    required int statusCode,
    String? contentType,
    String body = '',
  }) {
    _fakeHttp.primedBytes = utf8.encode(body);
    _fakeHttp.primedContentType = contentType;
    _fakeHttp.primedStatus = statusCode;
    _fakeHttp.primedError = null;
  }

  @override
  Future<void> dispose() async {
    _engine.close();
  }
}

/// Fake [WebHttpClient] that honours the caller's `byteBudget` on
/// `getBytes` — produces a truncated body + `truncated: true` when the
/// primed body exceeds the budget. Mirrors `DefaultWebHttpClient`'s
/// streaming semantics without binding a real port.
class _BudgetAwareFakeHttp implements WebHttpClient {
  List<int> primedBytes = const <int>[];
  String? primedContentType;
  int primedStatus = 200;
  Object? primedError;

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async {
    if (primedError != null) throw primedError!;
    final fullLength = primedBytes.length;
    final List<int> body;
    final bool truncated;
    if (byteBudget == null || fullLength <= byteBudget) {
      body = primedBytes;
      truncated = false;
    } else {
      body = primedBytes.sublist(0, byteBudget);
      truncated = true;
    }
    final headersMap = <String, String>{
      'content-length': fullLength.toString(),
    };
    final ct = primedContentType;
    if (ct != null) headersMap['content-type'] = ct;
    return WebHttpBytesResponse(
      statusCode: primedStatus,
      bodyBytes: body,
      headers: headersMap,
      url: url,
      contentLength: fullLength,
      truncated: truncated,
    );
  }

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async =>
      throw UnimplementedError(
        '_BudgetAwareFakeHttp.get is not exercised by the fetch harness',
      );

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async =>
      throw UnimplementedError(
        '_BudgetAwareFakeHttp.postForm is not exercised by the fetch harness',
      );

  @override
  void close() {}
}

// ─── Fetch harness 2: direct in-test stub `WebFetch` implementation.

class _DirectStubFetchHarness implements _WebFetchHarness {
  final _DirectStubWebFetch _service = _DirectStubWebFetch();

  @override
  WebFetch get service => _service;

  @override
  void primeTextBody(String body, {required String contentType}) {
    _service.primedTextBody = body;
    _service.primedContentType = contentType;
    _service.primedNon200Status = null;
    _service.primedNon200Body = '';
  }

  @override
  void primeNon200({
    required int statusCode,
    String? contentType,
    String body = '',
  }) {
    _service.primedTextBody = null;
    _service.primedContentType = contentType;
    _service.primedNon200Status = statusCode;
    _service.primedNon200Body = body;
  }

  @override
  Future<void> dispose() async {
    _service.close();
  }
}

class _DirectStubWebFetch implements WebFetch {
  String? primedTextBody;
  String? primedContentType;
  int? primedNon200Status;
  String primedNon200Body = '';
  bool _closed = false;

  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    if (_closed) {
      throw StateError('_DirectStubWebFetch.fetch after close()');
    }
    if (primedNon200Status != null) {
      throw WebFetchHttpException(
        url: url,
        statusCode: primedNon200Status!,
        contentType: primedContentType,
        bodyExcerpt: primedNon200Body,
      );
    }
    final body = primedTextBody ?? '';
    final ct = primedContentType ?? 'text/plain';
    final bytes = utf8.encode(body);
    final budget = options.budgetBytes;
    final bool truncated;
    final String surfaced;
    if (budget == null || bytes.length <= budget) {
      surfaced = body;
      truncated = false;
    } else {
      surfaced = utf8.decode(bytes.sublist(0, budget), allowMalformed: true);
      truncated = true;
    }
    return WebFetchResult(
      url: url,
      status: 200,
      contentType: ct,
      text: surfaced,
      truncated: truncated,
    );
  }

  @override
  void close() {
    _closed = true;
  }
}

