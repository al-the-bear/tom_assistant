// B.29 / B.30 — `WebHttpClient`: the narrow wire-shape seam between the
// substrate's web tools (`WebSearch` / `WebFetch`) and the underlying
// HTTP transport.
//
// B.30 extends the seam with a third method, `getBytes`, that streams a
// response body up to a caller-supplied byte budget and returns the
// raw bytes plus a `truncated` flag. `WebFetch` uses this; `WebSearch`
// providers continue to use the existing string-bodied `get` / `postForm`.
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
import 'dart:typed_data';

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

  /// Streams a `GET` response body up to [byteBudget] bytes and returns
  /// the raw bytes plus a [WebHttpBytesResponse.truncated] flag.
  ///
  /// Used by `WebFetch` (B.30) so:
  ///
  ///   - The substrate never materialises a response body larger than
  ///     the caller's per-call budget (`WebFetchOptions.budgetBytes`).
  ///   - Binary responses can be inspected for size + content-type
  ///     without paying decode cost on bytes the caller will discard.
  ///   - Truncation is observable (`WebFetchResult.truncated = true`)
  ///     rather than silently lost — the caller decides whether to
  ///     re-fetch with a larger budget or accept the partial body.
  ///
  /// [byteBudget] = `null` ⇒ no cap (the implementation reads the full
  /// body). A cap of `0` returns an empty body with `truncated = true`
  /// only when the server reported a non-zero `Content-Length`; an
  /// empty body with no length header reports `truncated = false`.
  ///
  /// Non-2xx responses are returned as-is (no exception); the caller
  /// (`WebFetch`) inspects the status code and raises
  /// `WebFetchHttpException` per its own policy.
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers,
    Duration? requestTimeout,
    int? byteBudget,
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

/// Decoded byte-shaped response from a [WebHttpClient.getBytes]
/// streaming round-trip.
///
/// Mirrors [WebHttpResponse] in spirit (status / headers / final URL)
/// but carries the response body as raw bytes plus a [truncated] flag
/// so `WebFetch` (B.30) can:
///
///   - Decide content-type-aware extraction *after* the bytes are in
///     hand (HTML → readable text, JSON → parse, binary → metadata
///     only) without paying for a string decode on bytes that turn
///     out to be binary.
///   - Surface budget truncation to the caller as
///     `WebFetchResult.truncated = true` rather than silently losing
///     the rest of the response.
///
/// [contentLength] reflects the server's `Content-Length` header
/// verbatim (parsed as int when present). It is independent of
/// [bodyBytes.length]: a truncated 2 MiB response with a 256 KiB
/// budget reports `contentLength = 2 * 1024 * 1024` and
/// `bodyBytes.length = 256 * 1024`.
final class WebHttpBytesResponse {
  /// HTTP status code (e.g. `200`, `404`, `503`).
  final int statusCode;

  /// Raw response body bytes, truncated to the budget the caller
  /// passed via `WebHttpClient.getBytes(byteBudget:)`. May be empty
  /// when the server sent an empty body or when the caller passed a
  /// budget of `0`.
  final List<int> bodyBytes;

  /// Response headers, lower-case keys.
  final Map<String, String> headers;

  /// Final URL after any redirects the underlying client followed.
  final Uri url;

  /// `Content-Length` header parsed as int when the server sent one;
  /// `null` when absent or unparseable.
  final int? contentLength;

  /// `true` when the substrate stopped reading at the budget. `false`
  /// when the body fit within the budget (or no budget was passed).
  final bool truncated;

  const WebHttpBytesResponse({
    required this.statusCode,
    required this.bodyBytes,
    required this.headers,
    required this.url,
    required this.contentLength,
    required this.truncated,
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

  @override
  Future<WebHttpBytesResponse> getBytes(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
    int? byteBudget,
  }) async {
    if (byteBudget != null && byteBudget < 0) {
      throw ArgumentError.value(
        byteBudget,
        'byteBudget',
        'byteBudget must be >= 0 (or null for no cap)',
      );
    }
    final request = http.Request('GET', url);
    request.headers.addAll(headers);
    // Disable redirect-following at the request layer so we observe
    // the final URL ourselves; package:http's BaseClient follows by
    // default on platforms where the underlying client supports it.
    request.followRedirects = true;

    final http.StreamedResponse streamed;
    try {
      final sendFuture = _inner.send(request);
      streamed = await (requestTimeout == null
          ? sendFuture
          : sendFuture.timeout(requestTimeout));
    } on Exception catch (e) {
      throw WebHttpTransportException(url: url, cause: e);
    }

    final lowerHeaders = <String, String>{
      for (final entry in streamed.headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final declaredLength = int.tryParse(lowerHeaders['content-length'] ?? '');

    // Read the stream, stopping at `byteBudget` if set. We collect
    // into a single `BytesBuilder` so the final byte list is one
    // contiguous allocation rather than a chain of small chunks.
    final builder = BytesBuilder(copy: false);
    var read = 0;
    var truncated = false;
    try {
      await for (final chunk in streamed.stream) {
        if (byteBudget == null) {
          builder.add(chunk);
          read += chunk.length;
          continue;
        }
        final remaining = byteBudget - read;
        if (remaining <= 0) {
          truncated = true;
          break;
        }
        if (chunk.length <= remaining) {
          builder.add(chunk);
          read += chunk.length;
        } else {
          builder.add(chunk.sublist(0, remaining));
          read += remaining;
          truncated = true;
          break;
        }
      }
    } on Exception catch (e) {
      throw WebHttpTransportException(url: url, cause: e);
    }

    // If the server reported a Content-Length larger than what we
    // actually read, the response was truncated even if the stream
    // ended naturally (HTTP/1.1 chunked + Content-Length disagreement,
    // or a closed connection mid-body). Mark it.
    if (!truncated &&
        declaredLength != null &&
        declaredLength > builder.length) {
      truncated = true;
    }

    return WebHttpBytesResponse(
      statusCode: streamed.statusCode,
      bodyBytes: builder.takeBytes(),
      headers: lowerHeaders,
      url: url,
      contentLength: declaredLength,
      truncated: truncated,
    );
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
