// B.30 — `WebFetch`: substrate-side abstract surface for the
// `webFetch(url, options)` method on `TomBrainSubstrateClient`.
//
// substrate_specification.md § 8.2: the substrate exposes
// `WebFetch.fetch(url, { budget, followRedirects, userAgent })` and
// returns `WebFetchResult { url, status, contentType, text?, json?,
// binaryMeta?, truncated }` with content-type aware extraction. The
// consumer-facing surface (`TomBrainSubstrateClient.webFetch`) is
// already in place from B.9 (`lib/src/api/tom_brain_substrate_client.dart`)
// with the value vocabulary in `web_results.dart`.
//
// This file declares the *substrate-internal* `WebFetch` abstract
// surface — the contract the facade (B.40+) binds against. The
// `WebFetch` interface is to web-fetching what `WebSearch` is to
// web-searching: one abstract type, swappable implementations, the
// facade holds exactly one concrete instance per substrate.
//
// At B.30 the only concrete implementation is `DefaultWebFetch`
// (`default_web_fetch.dart`), which streams through the shared
// `WebHttpClient` seam (`web_http_client.dart`), dispatches on
// content-type, and surfaces budget truncation + typed HTTP errors.

import '../api/web_results.dart';

/// Substrate-side web-fetch contract.
///
/// One implementation per fetch strategy:
///
///   - `DefaultWebFetch` (B.30) — single-URL fetch through the shared
///     `WebHttpClient` seam, with content-type-aware extraction
///     (HTML → readable text, JSON → passthrough, binary → metadata).
///     The substrate's default; the facade (B.40+) constructs one of
///     these from `SubstrateConfig`.
///   - Future variants (not in scope at B.30) — could fan out to a
///     cache layer, fall back across mirrors, or pre-filter against a
///     robots-policy decider. They implement this same surface; the
///     facade swap is a constructor argument.
///
/// **Failure surfaces:**
///
///   - `WebFetchHttpException` — server returned a non-2xx status.
///   - `WebFetchUnsupportedType` — server returned a content-type the
///     substrate explicitly refuses to materialise (e.g. PDF at
///     B.30 — spec § 8.2 table marks it out of scope for v1).
///   - `WebHttpTransportException` (`web_http_client.dart`) — transport
///     failed before any HTTP response arrived.
///
/// Budget overflows are NOT failures: a response larger than the
/// caller-supplied budget returns as a `WebFetchResult` with
/// `truncated: true` (spec § 8.2 + § 12).
abstract class WebFetch {
  /// Fetches [url] under [options] and returns the content-type-aware
  /// decoded result.
  ///
  /// The returned [WebFetchResult] carries exactly one non-null body
  /// field — [WebFetchResult.text], [WebFetchResult.json], or
  /// [WebFetchResult.binaryMeta] — chosen by the resolved
  /// content-type (spec § 8.2). [WebFetchResult.truncated] is `true`
  /// when the substrate stopped reading at [WebFetchOptions.budgetBytes]
  /// (or the implementation's default when the option was null);
  /// `false` otherwise.
  ///
  /// Non-2xx responses raise [WebFetchHttpException]; unsupported
  /// content types raise [WebFetchUnsupportedType]; transport
  /// failures propagate the underlying transport exception unchanged.
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  });

  /// Releases any backend resources this engine owns. Idempotent.
  void close();
}

/// Thrown by [WebFetch.fetch] when the server returned a non-2xx
/// status code.
///
/// Distinct from `WebHttpTransportException` (transport failed before
/// any response arrived) and from `WebFetchUnsupportedType` (response
/// arrived with a 2xx status but a content-type the substrate
/// refuses). The router-layer retry / circuit-breaker policy (B.31)
/// reads [statusCode] to decide retry-vs-fail.
class WebFetchHttpException implements Exception {
  /// The URL the substrate fetched (after any redirects the
  /// underlying transport followed).
  final Uri url;

  /// HTTP status code the server returned (e.g. `404`, `503`).
  final int statusCode;

  /// `Content-Type` header on the error response, when present.
  /// `null` when the server omitted it.
  final String? contentType;

  /// First ~512 bytes of the response body, decoded as UTF-8 with
  /// `allowMalformed: true`. Empty when the body was empty or the
  /// substrate read nothing (budget = 0). Useful for the trail —
  /// many APIs return their error message in the body.
  final String bodyExcerpt;

  WebFetchHttpException({
    required this.url,
    required this.statusCode,
    this.contentType,
    this.bodyExcerpt = '',
  });

  @override
  String toString() =>
      'WebFetchHttpException($url status=$statusCode'
      '${contentType == null ? '' : ' contentType=$contentType'})'
      '${bodyExcerpt.isEmpty ? '' : ': $bodyExcerpt'}';
}

/// Thrown by [WebFetch.fetch] when the server returned a 2xx response
/// whose content-type the substrate explicitly refuses to
/// materialise.
///
/// At B.30 this fires for `application/pdf` only — spec § 8.2 marks
/// PDF as "Out of scope for v1. Returns `WebFetchUnsupportedType`".
/// All other binary content-types fall through to the `binaryMeta`
/// path (metadata only, no body bytes).
///
/// The exception type exists as a separate failure mode (spec § 12 row
/// "Web fetch unsupported content type") so the caller's policy
/// (procedure code at the dispatcher layer) can react differently
/// from a transport / HTTP failure — typically by routing to a
/// PDF-aware tool rather than retrying the same URL.
class WebFetchUnsupportedType implements Exception {
  /// The URL the substrate fetched (after any redirects).
  final Uri url;

  /// The unsupported `Content-Type` (normalised to `type/subtype`
  /// without parameters; cf. the raw header for the verbatim value).
  final String contentType;

  /// The raw `Content-Type` header the server returned (with any
  /// parameters such as `; charset=utf-8` intact).
  final String rawContentType;

  WebFetchUnsupportedType({
    required this.url,
    required this.contentType,
    required this.rawContentType,
  });

  @override
  String toString() =>
      'WebFetchUnsupportedType($url contentType=$contentType '
      '(raw="$rawContentType")): the substrate refuses to materialise '
      'responses of this type at v1';
}
