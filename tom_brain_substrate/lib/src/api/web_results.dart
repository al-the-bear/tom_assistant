// B.9 — Web-tool result + option vocabulary.
//
// substrate_specification.md § 3.1 + § 8: the substrate exposes two
// web tools — `webSearch(query, options)` returning
// `WebSearchResult`, and `webFetch(url, options)` returning
// `WebFetchResult`. The api/ layer freezes the surface here so the
// (B.29+) implementations and their tests share the same vocabulary.
//
// Spec § 8 specifics carried into the value types:
//
//   - Search results expose `{ title, url, snippet, rank }` per hit.
//   - Fetch results carry the content-type-aware decoded body —
//     `text?`, `json?`, `binaryMeta?` — exactly one of which is
//     non-null, plus the HTTP status and the resolved URL after
//     redirects.
//   - Fetch options carry a per-call budget (default lives in
//     `SubstrateConfig.webFetch.defaultBudgetBytes`); a response
//     larger than the budget surfaces as a `WebFetchResult` with
//     `truncated: true`, not as an error (spec § 12).

/// One search hit.
final class SearchHit {
  /// Page title.
  final String title;

  /// Canonical URL the search engine surfaced.
  final Uri url;

  /// Engine-supplied snippet. May be empty when the engine returned
  /// no snippet.
  final String snippet;

  /// 1-based rank in the result set. Lets consumers re-rank without
  /// losing the engine's original order.
  final int rank;

  const SearchHit({
    required this.title,
    required this.url,
    required this.snippet,
    required this.rank,
  });
}

/// Result of a `TomBrainSubstrateClient.webSearch` call.
final class WebSearchResult {
  /// Engine that served the query (e.g. `duckduckgo`, `brave`).
  /// Matches `WebSearchOptions.provider` when the caller pinned a
  /// provider; otherwise reports the substrate's default.
  final String provider;

  /// The original query (verbatim).
  final String query;

  /// Hits, in engine-supplied rank order.
  final List<SearchHit> hits;

  const WebSearchResult({
    required this.provider,
    required this.query,
    required this.hits,
  });
}

/// Options for `TomBrainSubstrateClient.webSearch`.
final class WebSearchOptions {
  /// Engine to use. `null` ⇒ substrate config default
  /// (`webSearch.defaultProvider`).
  final String? provider;

  /// Maximum number of hits to return. Engine may return fewer;
  /// substrate does not pad. Default 10.
  final int k;

  const WebSearchOptions({this.provider, this.k = 10});

  /// All-defaults instance.
  static const WebSearchOptions empty = WebSearchOptions();
}

/// Result of a `TomBrainSubstrateClient.webFetch` call.
///
/// Exactly one of [text], [json], [binaryMeta] is non-null,
/// depending on the resolved content-type:
///
///   - `text/html`, `text/plain`, anything plain-text-ish → [text]
///     with the readable-text extraction applied (HTML stripped to
///     prose; plain text passed through verbatim).
///   - `application/json` → [json] with the parsed object.
///   - everything else → [binaryMeta] with size + content-type;
///     [text] and [json] both `null`.
final class WebFetchResult {
  /// The URL fetched, after any redirects. May differ from the URL
  /// the caller passed.
  final Uri url;

  /// HTTP status code of the response.
  final int status;

  /// Content-type the server returned, normalised to the
  /// `type/subtype` form (without parameters).
  final String contentType;

  /// Decoded readable text. Non-null iff the content was a text
  /// type (HTML, plain, etc.). `null` for JSON / binary responses.
  final String? text;

  /// Parsed JSON. Non-null iff the content-type was
  /// `application/json`. `null` for text / binary responses.
  final Object? json;

  /// Metadata for binary responses. Non-null iff the content was
  /// neither text nor JSON.
  final BinaryFetchMeta? binaryMeta;

  /// `true` when the response was truncated to stay within
  /// [WebFetchOptions.budgetBytes]. Lands in
  /// `WebFetchCompleted.truncated` (substrate event § 10.2).
  final bool truncated;

  /// Number of raw body bytes the substrate read off the wire (after
  /// any budget truncation) — i.e. the true size of the fetched body,
  /// independent of the content-type branch. Lands in
  /// `WebFetchCompleted.bytes` (substrate event § 10.2).
  ///
  /// `null` only when the producer did not measure the body (e.g. a
  /// test double that primes a result without a byte count).
  /// [DefaultWebFetch] always sets it. Reporting the byte length here —
  /// rather than `text.length` (a *character* count) or a JSON-path
  /// placeholder — gives every content type a single, honest size: a
  /// JSON response reports its decoded byte length, not `0`/`1`.
  final int? contentBytes;

  const WebFetchResult({
    required this.url,
    required this.status,
    required this.contentType,
    this.text,
    this.json,
    this.binaryMeta,
    this.truncated = false,
    this.contentBytes,
  });
}

/// Metadata for a fetch whose body the substrate did not decode.
///
/// The substrate deliberately does **not** return the bytes (memory
/// is not designed to store arbitrary binary; that is the access
/// layer's problem). Callers that need the bytes use `tom_core_kernel.HttpClient`
/// directly with their own budget enforcement.
final class BinaryFetchMeta {
  /// Total bytes the server reported via `Content-Length`. `null`
  /// when the server sent chunked encoding without a length header.
  final int? contentLength;

  /// `Content-Type` the server returned (verbatim, including any
  /// parameters; cf. [WebFetchResult.contentType] which is the
  /// normalised form).
  final String contentType;

  const BinaryFetchMeta({required this.contentType, this.contentLength});
}

/// Options for `TomBrainSubstrateClient.webFetch`.
final class WebFetchOptions {
  /// Per-call byte budget. The substrate stops reading after this
  /// many bytes and surfaces the result with `truncated: true`.
  /// `null` ⇒ substrate config default
  /// (`webFetch.defaultBudgetBytes`, 256 KiB).
  final int? budgetBytes;

  /// HTTP method. Currently only `GET` is supported. Reserved so
  /// future `POST` / `HEAD` calls (e.g. for content-length probes)
  /// do not require a contract change.
  final String method;

  /// Optional caller-supplied headers (e.g. `Accept-Language`).
  /// `User-Agent` is forced from `SubstrateConfig.webFetch.userAgent`
  /// — callers cannot override it.
  final Map<String, String> headers;

  const WebFetchOptions({
    this.budgetBytes,
    this.method = 'GET',
    this.headers = const <String, String>{},
  });

  /// All-defaults instance.
  static const WebFetchOptions empty = WebFetchOptions();
}
