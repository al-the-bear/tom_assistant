// B.29 — `WebHttpClient`: the narrow wire-shape seam between the
// substrate's web tools (`WebSearch` / `WebFetch`) and the underlying
// HTTP transport.
//
// Same pattern as `OllamaHttpClient` (lib/src/llm/ollama_http_client.dart):
// every outbound request the web-tools sub-module makes goes through this
// abstract seam so test doubles can be written without binding a port.
//
// Why a seam at all (vs. calling `package:http` directly inside the
// providers):
//
//   - Provider implementations (`DuckDuckGoHtmlSearchProvider` at B.29,
//     future `BraveSearchProvider` / `SerpApiSearchProvider` /
//     `TavilySearchProvider`, plus B.30's `WebFetch` impl) must be
//     testable without spinning up a fake HTTP server. Mocktail / hand-
//     written fakes against this small interface are dramatically cheaper
//     than `MockClient` against the raw `package:http` surface.
//   - The router-layer retry / circuit-breaker policy (B.31) stacks
//     *around* a `WebHttpClient`, not inside the providers. That keeps
//     the providers focused on protocol shape; B.31 swaps the
//     `DefaultWebHttpClient` for a retry-aware variant without any
//     provider code change.
//   - Cross-tool reuse — `WebSearch` (B.29) and `WebFetch` (B.30) share
//     the same wire seam, so the retry/circuit-breaker policy applies
//     uniformly to both tools. The B.30 fetch impl will extend this
//     interface with byte-budget / streaming knobs; the B.29 surface
//     stays small.
//
// What this file deliberately does NOT own:
//
//   - The retry / backoff / circuit-breaker policy. Lives at B.31 (wire
//     to `tom_core_kernel.HttpClient`).
//   - Bearer-token auth for key-bearing providers (Brave / SerpAPI /
//     Tavily / Kagi). Plug-in providers configure their own auth on the
//     headers they pass into `get` / `postForm`.
//   - Robots.txt enforcement. That is `WebFetch`-side policy (B.30, spec
//     § 8.2) and does not affect search providers.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Narrow wire-shape interface to HTTP for the substrate's web tools
/// (`WebSearch` at B.29, `WebFetch` at B.30).
///
/// Implemented by:
///
///   - [DefaultWebHttpClient] — production, wraps a `package:http`
///     `Client`. B.31 replaces this with a retry / circuit-breaker
///     aware variant backed by `tom_core_kernel.HttpClient`; the
///     provider / fetch code does not change.
///   - Test fakes (e.g. `_FakeWebHttpClient` in
///     `test/b29_web_search_test.dart`). Mandatory: every B.29 test
///     exercises the search providers through a fake of this interface
///     so the suite has zero network dependency.
///
/// Both methods MUST surface backend / transport failures as thrown
/// exceptions. The providers catch them and either repackage as a
/// search-provider-typed error or re-throw (B.31's classifier will wrap
/// them into typed `LlmFailure`-style errors at the router layer once
/// retry policy is in place).
abstract class WebHttpClient {
  /// One non-streaming `GET` round-trip.
  ///
  /// [url] is the target URL (already query-encoded). [headers] are
  /// merged with any defaults the implementation applies (e.g.
  /// `User-Agent`). [requestTimeout] caps the round-trip; `null` ⇒ no
  /// cap.
  ///
  /// Returns a [WebHttpResponse] with the verbatim status and body.
  /// Non-2xx responses are returned as-is (no exception) — providers
  /// decide whether to throw or interpret per their wire shape (for
  /// example DuckDuckGo serves blocked-bot pages with status 200).
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers,
    Duration? requestTimeout,
  });

  /// One non-streaming `POST` of `application/x-www-form-urlencoded`
  /// form data.
  ///
  /// [form] is encoded as `key1=value1&key2=value2` with `Uri.encodeQueryComponent`
  /// on every name and value. The implementation sets
  /// `Content-Type: application/x-www-form-urlencoded` automatically;
  /// any caller-supplied `Content-Type` in [headers] is ignored.
  ///
  /// DuckDuckGo's `https://html.duckduckgo.com/html/` endpoint accepts
  /// either GET or POST; the prototype POSTs because the response
  /// differs less between user-agents on that path.
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers,
    Duration? requestTimeout,
  });

  /// Releases any underlying HTTP client resources.
  void close();
}

/// Decoded response from a [WebHttpClient] round-trip.
///
/// Kept deliberately small: status, body (already decoded as UTF-8),
/// and the response headers normalised to lower-case keys. B.30 will
/// likely extend the response shape with `bodyBytes` (for binary
/// fetches) and `contentLength` (for byte-budget enforcement); the
/// B.29 surface needs only the text body.
final class WebHttpResponse {
  /// HTTP status code (e.g. `200`, `404`, `503`).
  final int statusCode;

  /// Response body decoded as UTF-8. For non-UTF-8 text bodies the
  /// caller can re-decode using the raw bytes from a later
  /// `bodyBytes` field (added by B.30 when binary support lands).
  final String body;

  /// Response headers, lower-case keys.
  final Map<String, String> headers;

  /// Final URL after any redirects the underlying client followed.
  /// For the prototype this is the same as the request URL when the
  /// underlying transport follows redirects transparently.
  final Uri url;

  const WebHttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.url,
  });
}

/// Thrown by [DefaultWebHttpClient] for transport-level failures
/// (DNS, connection-refused, socket close, timeout). Non-2xx status
/// codes are NOT wrapped — they ride the [WebHttpResponse.statusCode]
/// field so providers can interpret them per their wire shape.
class WebHttpTransportException implements Exception {
  final Uri url;
  final Object cause;

  WebHttpTransportException({required this.url, required this.cause});

  @override
  String toString() => 'WebHttpTransportException($url): $cause';
}

/// Production [WebHttpClient] backed by a `package:http` `Client`.
///
/// The client is acquired the same way `DefaultOllamaHttpClient`
/// acquires its one: B.31 will rewire this to call
/// `tom_core_kernel.HttpClient` so retry / circuit-breaker policy is
/// shared across the substrate's outbound surface. Until then, the
/// caller may inject the `Client` directly so the dependency-discipline
/// test does not bind the substrate to the kernel's static initialiser.
class DefaultWebHttpClient implements WebHttpClient {
  final http.Client _inner;

  /// Whether [close] should also close the underlying [http.Client].
  /// `false` when the caller injected a client whose lifetime they
  /// manage themselves.
  final bool _ownsInner;

  DefaultWebHttpClient({http.Client? client})
      : _inner = client ?? http.Client(),
        _ownsInner = client == null;

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    try {
      final future = _inner.get(url, headers: headers);
      final response = await (requestTimeout == null
          ? future
          : future.timeout(requestTimeout));
      return _wrap(response, url);
    } on Exception catch (e) {
      throw WebHttpTransportException(url: url, cause: e);
    }
  }

  @override
  Future<WebHttpResponse> postForm(
    Uri url, {
    required Map<String, String> form,
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    // Build the form body explicitly — `package:http`'s default
    // form-encoding behaviour swaps in based on the body type, but
    // pinning it here makes the wire shape unambiguous for fakes that
    // verify the request.
    final encoded = form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final mergedHeaders = <String, String>{
      ...headers,
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    try {
      final future = _inner.post(url, headers: mergedHeaders, body: encoded);
      final response = await (requestTimeout == null
          ? future
          : future.timeout(requestTimeout));
      return _wrap(response, url);
    } on Exception catch (e) {
      throw WebHttpTransportException(url: url, cause: e);
    }
  }

  WebHttpResponse _wrap(http.Response response, Uri requestUrl) {
    // `http.Response.body` decodes using the charset from `Content-Type`
    // when present, falling back to latin1. For DDG HTML and most
    // search-provider JSON responses this is UTF-8; if a provider lands
    // that returns non-UTF-8 text the implementation will need to
    // re-decode from `response.bodyBytes`.
    final body = response.body;
    final lowerHeaders = <String, String>{
      for (final entry in response.headers.entries) entry.key.toLowerCase(): entry.value,
    };
    return WebHttpResponse(
      statusCode: response.statusCode,
      body: body,
      headers: lowerHeaders,
      url: requestUrl,
    );
  }

  @override
  void close() {
    if (_ownsInner) {
      _inner.close();
    }
  }
}

/// JSON-decoding helper for providers whose wire shape is JSON
/// (Brave / SerpAPI / Tavily). DuckDuckGo HTML uses the regex-based
/// HTML parser in `duckduckgo_search_provider.dart` and does not call
/// this helper.
///
/// Returns the decoded JSON object. Throws [FormatException] if the
/// body is not valid JSON.
Object? decodeJsonBody(WebHttpResponse response) =>
    jsonDecode(response.body);
