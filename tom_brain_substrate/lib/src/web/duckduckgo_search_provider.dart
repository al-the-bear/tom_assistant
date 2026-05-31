// B.29 — `DuckDuckGoHtmlSearchProvider`: substrate's no-key default
// web-search provider.
//
// substrate_specification.md § 8.1 names it as "DuckDuckGo HTML — no
// key, default for the prototype". The plan step B.29 makes it the
// concrete deliverable while the rest of the plug-in surface
// (`WebSearchProvider`, `DefaultWebSearch`) is the contract layer.
//
// Wire shape:
//
//   - POST `https://html.duckduckgo.com/html/` with
//     `application/x-www-form-urlencoded` body `q=<query>`.
//     The HTML endpoint is DDG's "no JavaScript" variant; the main
//     `duckduckgo.com` endpoint requires JS rendering and is not
//     usable from a server-side fetcher. The HTML endpoint is the
//     same one `dduckduckgo-search` (Python), `ddg.gg` proxies, and
//     several other research projects use.
//   - Response is HTML. Each result is a block:
//
//       <div class="result results_links results_links_deep web-result">
//         <div class="result__body">
//           <h2 class="result__title">
//             <a class="result__a" href="<url>">Title text</a>
//           </h2>
//           <a class="result__snippet" href="<url>">Snippet text</a>
//         </div>
//       </div>
//
//   - DDG sometimes wraps the result URL in a redirect of the form
//     `//duckduckgo.com/l/?uddg=<percent-encoded-target>&rut=<rut>`.
//     The provider unwraps these so consumers receive the canonical
//     target URL.
//
// Failure surfaces:
//
//   - Transport failure → `WebHttpTransportException` (from the
//     underlying `WebHttpClient`).
//   - Non-2xx HTTP status → `WebSearchProviderException` with the
//     status carried through.
//   - DDG anti-bot block page (status 200 with body containing
//     `class="anomaly-modal"` or `Unfortunately, bots use DuckDuckGo too`)
//     → `WebSearchProviderException` with `statusCode: 200` and a
//     descriptive message so the trail captures the block.
//   - Empty result set → returns an empty `WebSearchResult.hits`.
//     The substrate does not treat zero hits as an error.
//
// What this provider deliberately does NOT do:
//
//   - Use a full HTML parser. The DDG HTML structure is stable enough
//     that a regex-based extractor covers it; pulling in `package:html`
//     just for the prototype would balloon the dep surface for one
//     wire shape. If a second HTML-scraping provider lands, both
//     should share a parser — but that is a future-reuse-extraction
//     concern (Phase D), not B.29.
//   - Set safeSearch / locale knobs. The spec § 8.1 names them but
//     they are not in the B.29 plan step's surface (`{provider, k}`);
//     they land when `WebSearchOptions` grows the corresponding fields.
//     The provider sends DDG's default (moderate safe search, no
//     locale pin) until then.
//   - Honour `robots.txt`. Search-engine endpoints are explicitly
//     designed to be hit by external clients; robots enforcement is
//     a `WebFetch` concern (B.30, spec § 8.2).

import '../api/web_results.dart';
import 'web_http_client.dart';
import 'web_search_provider.dart';

/// DuckDuckGo HTML scraping provider — substrate's no-key default.
class DuckDuckGoHtmlSearchProvider implements WebSearchProvider {
  /// Stable provider id. Matches `substrate_specification.md` § 9's
  /// `webSearch.providers.duckduckgo` configuration key.
  static const String providerId = 'duckduckgo';

  /// The endpoint the provider POSTs to.
  ///
  /// Exposed as a field so tests can point at a localhost fake; in
  /// production callers should not override it.
  final Uri endpoint;

  /// User-Agent string. The spec § 9 attributes the substrate-wide
  /// user agent to `SubstrateConfig.webFetch.userAgent`; until that
  /// loader lands (B.36), the provider falls back to a stable
  /// identifier the substrate's web-fetch tool will share at B.30.
  final String userAgent;

  /// Per-request timeout. `null` ⇒ no timeout (the HTTP client's
  /// underlying socket timeout still applies). Default 15 s — long
  /// enough for DDG under load, short enough that a stalled call
  /// surfaces before the consumer's own deadline.
  final Duration? requestTimeout;

  final WebHttpClient _http;

  /// Whether [close] should also close the underlying [WebHttpClient].
  /// `false` when the caller injected a client whose lifetime they
  /// manage themselves.
  final bool _ownsClient;

  DuckDuckGoHtmlSearchProvider({
    WebHttpClient? httpClient,
    Uri? endpoint,
    String? userAgent,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _http = httpClient ?? DefaultWebHttpClient(),
        _ownsClient = httpClient == null,
        endpoint = endpoint ?? Uri.parse('https://html.duckduckgo.com/html/'),
        userAgent =
            userAgent ?? 'TomBrain/0.1 (+https://tom-brain.local) DDG-HTML';

  @override
  String get id => providerId;

  @override
  Future<WebSearchResult> search(String query, {required int k}) async {
    if (k <= 0) {
      throw ArgumentError.value(k, 'k', 'must be > 0');
    }
    final response = await _http.postForm(
      endpoint,
      form: <String, String>{'q': query},
      headers: <String, String>{
        'User-Agent': userAgent,
        // DDG's anti-bot heuristics are noticeably gentler when the
        // caller advertises that it speaks plain HTML and not the
        // SPA. The header is informational; DDG does not require it.
        'Accept': 'text/html,application/xhtml+xml',
      },
      requestTimeout: requestTimeout,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebSearchProviderException(
        providerId: providerId,
        statusCode: response.statusCode,
        message: 'DuckDuckGo HTML endpoint returned non-2xx',
        bodyExcerpt: _excerpt(response.body),
      );
    }

    if (_isAntiBotBlock(response.body)) {
      throw WebSearchProviderException(
        providerId: providerId,
        statusCode: response.statusCode,
        message:
            'DuckDuckGo HTML endpoint returned an anti-bot block page; '
            'no results extractable',
        bodyExcerpt: _excerpt(response.body),
      );
    }

    final hits = _parseHits(response.body, limit: k);
    return WebSearchResult(
      provider: providerId,
      query: query,
      hits: hits,
    );
  }

  @override
  void close() {
    if (_ownsClient) {
      _http.close();
    }
  }

  // ---- HTML parsing -------------------------------------------------

  /// Regex matching one DDG result block.
  ///
  /// DDG's HTML wraps each hit in:
  ///
  ///   <a ... class="result__a" ... href="...">Title</a>
  ///
  /// followed (within the same `result__body`) by:
  ///
  ///   <a ... class="result__snippet" ... >Snippet text</a>
  ///
  /// We tolerate ordering and attribute variation by anchoring the
  /// regex on the two class names and using `[\s\S]*?` for the
  /// non-greedy gap between them.
  static final RegExp _resultBlock = RegExp(
    r'<a[^>]*class="[^"]*\bresult__a\b[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>'
    r'[\s\S]*?'
    r'<a[^>]*class="[^"]*\bresult__snippet\b[^"]*"[^>]*>([\s\S]*?)</a>',
    multiLine: true,
    caseSensitive: false,
  );

  /// Some DDG layouts surface the title link inside a `<h2 class="result__title">`
  /// without a paired `result__snippet`; in that case we still want the
  /// title + url with an empty snippet rather than dropping the hit.
  static final RegExp _titleOnlyFallback = RegExp(
    r'<a[^>]*class="[^"]*\bresult__a\b[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
    multiLine: true,
    caseSensitive: false,
  );

  List<SearchHit> _parseHits(String html, {required int limit}) {
    final hits = <SearchHit>[];
    final paired = _resultBlock.allMatches(html).toList(growable: false);
    final pairedHrefs = <String>{};
    for (final match in paired) {
      if (hits.length >= limit) break;
      final href = match.group(1)!;
      final title = _stripTags(match.group(2)!).trim();
      final snippet = _stripTags(match.group(3)!).trim();
      final url = _unwrapDdgRedirect(href);
      if (url == null) continue;
      hits.add(SearchHit(
        title: title,
        url: url,
        snippet: snippet,
        rank: hits.length + 1,
      ));
      pairedHrefs.add(href);
    }

    // Title-only fallback: capture hits whose snippet anchor was
    // missing or out of order. We skip any href we already counted in
    // the paired pass to avoid duplicates.
    if (hits.length < limit) {
      for (final match in _titleOnlyFallback.allMatches(html)) {
        if (hits.length >= limit) break;
        final href = match.group(1)!;
        if (pairedHrefs.contains(href)) continue;
        final title = _stripTags(match.group(2)!).trim();
        final url = _unwrapDdgRedirect(href);
        if (url == null) continue;
        hits.add(SearchHit(
          title: title,
          url: url,
          snippet: '',
          rank: hits.length + 1,
        ));
      }
    }

    return hits;
  }

  /// Strips HTML tags and decodes the small set of HTML entities DDG
  /// emits in titles / snippets (`&amp;`, `&lt;`, `&gt;`, `&quot;`,
  /// `&#x27;`, `&#39;`). A full HTML-entity decoder is overkill for
  /// the prototype.
  static String _stripTags(String fragment) {
    final noTags = fragment.replaceAll(RegExp(r'<[^>]+>'), '');
    return noTags
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  /// DDG sometimes wraps the result URL as
  /// `//duckduckgo.com/l/?uddg=<percent-encoded-target>&rut=...`.
  /// This helper unwraps it; absolute / scheme-relative non-DDG URLs
  /// pass through untouched.
  ///
  /// Returns `null` when the URL is malformed and cannot be parsed —
  /// the caller drops the hit.
  static Uri? _unwrapDdgRedirect(String raw) {
    var candidate = raw.trim();
    if (candidate.isEmpty) return null;
    if (candidate.startsWith('//')) {
      candidate = 'https:$candidate';
    }
    Uri? parsed;
    try {
      parsed = Uri.parse(candidate);
    } on FormatException {
      return null;
    }
    if (parsed.host == 'duckduckgo.com' && parsed.path == '/l/') {
      final inner = parsed.queryParameters['uddg'];
      if (inner != null && inner.isNotEmpty) {
        try {
          return Uri.parse(inner);
        } on FormatException {
          return null;
        }
      }
    }
    return parsed;
  }

  /// Heuristic anti-bot detector. DDG's anomaly page carries the
  /// `anomaly-modal` class and the phrase "Unfortunately, bots use
  /// DuckDuckGo too". Either signal is enough.
  static bool _isAntiBotBlock(String body) {
    if (body.contains('class="anomaly-modal"')) return true;
    if (body.contains('anomaly_dl_modal')) return true;
    if (body.contains('Unfortunately, bots use DuckDuckGo too')) return true;
    return false;
  }

  /// First 512 chars of the body for forensic logging.
  static String _excerpt(String body) {
    if (body.length <= 512) return body;
    return body.substring(0, 512);
  }
}
