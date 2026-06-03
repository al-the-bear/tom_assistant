// B.31 — `TomKernelWebHttpClient`: a `WebHttpClient` implementation
// that acquires its underlying `package:http.Client` from
// `tom_core_kernel`'s `TomHttpClientFactory`.
//
// Why this exists:
//
//   `DefaultWebHttpClient` (shipped at B.29 / B.30) builds its
//   `package:http.Client` directly with `http.Client()`. That works,
//   but every other workspace HTTP consumer goes through
//   `tom_core_kernel.TomHttpClientFactory` so the workspace can swap
//   the underlying client implementation in one place (TLS settings,
//   custom factories, in-test stubbing via
//   `TomHttpClientFactory.setGlobalHttpClientFactory`). The substrate's
//   web tools join that convention by routing through this adapter.
//
//   Pairing this adapter with `RetryingWebHttpClient` (B.31's
//   retry + circuit-breaker decorator) yields the full B.31 stack:
//
//   ```dart
//   final webHttp = RetryingWebHttpClient(
//     inner: TomKernelWebHttpClient(),
//   );
//   ```
//
// What this class does NOT own:
//
//   - Retry / circuit-breaker policy. Lives in
//     `RetryingWebHttpClient` (this adapter is intentionally policy-
//     free so the decorator stays composable with other inner
//     clients — e.g. fakes in tests).
//   - Header injection. Caller provides headers verbatim.
//   - Auth. Caller's headers carry any bearer / API-key auth.
//
// The byte-streaming + budget-enforcement logic mirrors
// `DefaultWebHttpClient.getBytes` exactly — the two adapters differ
// only in how they get hold of the underlying `package:http.Client`.
// Q-B.31.2 tracks whether the two implementations should be folded
// into one parameterised-factory variant.

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart' as kernel;

import 'web_http_client.dart';

/// `WebHttpClient` backed by a `package:http.Client` sourced from
/// `tom_core_kernel.TomHttpClientFactory`.
///
/// **Lifecycle:**
///
///   - When constructed with `factory: null` (the default), this class
///     acquires its client via `TomHttpClientFactory().getClient()` —
///     the same path every other workspace HTTP consumer uses. The
///     client is cached for the lifetime of the adapter; `close()`
///     releases it.
///   - When constructed with a caller-supplied `factory`, that factory
///     is used instead. Test wiring leans on this to inject a
///     `MockClient`-backed factory without touching the global state.
///   - When constructed with a caller-supplied `client`, that client
///     is used directly and never closed by [close] (caller-owned).
class TomKernelWebHttpClient with CloseGuard implements WebHttpClient {
  final kernel.TomHttpClientFactory? _factory;
  http.Client? _client;
  final bool _ownsClient;

  /// Default construction: pulls a `package:http.Client` from a
  /// `kernel.TomHttpClientFactory()` on first use. The acquired client
  /// is closed on [close].
  TomKernelWebHttpClient({kernel.TomHttpClientFactory? factory})
      : _factory = factory ?? kernel.TomHttpClientFactory(),
        _client = null,
        _ownsClient = true;

  /// Caller-supplied-client construction: uses the given client
  /// directly. [close] does NOT close the client.
  TomKernelWebHttpClient.withClient(http.Client client)
      : _factory = null,
        _client = client,
        _ownsClient = false;

  http.Client _acquire() {
    ensureOpen('TomKernelWebHttpClient');
    final cached = _client;
    if (cached != null) return cached;
    final factory = _factory!;
    final fresh = factory.getClient();
    _client = fresh;
    return fresh;
  }

  @override
  Future<WebHttpResponse> get(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    final client = _acquire();
    try {
      final future = client.get(url, headers: headers);
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
    final client = _acquire();
    final encoded = form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final mergedHeaders = <String, String>{
      ...headers,
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    try {
      final future = client.post(url, headers: mergedHeaders, body: encoded);
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
    final client = _acquire();
    final request = http.Request('GET', url);
    request.headers.addAll(headers);
    request.followRedirects = true;

    final http.StreamedResponse streamed;
    try {
      final sendFuture = client.send(request);
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
    final body = response.body;
    final lowerHeaders = <String, String>{
      for (final entry in response.headers.entries)
        entry.key.toLowerCase(): entry.value,
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
    if (!markClosed()) return;
    if (_ownsClient) {
      _client?.close();
    }
    _client = null;
  }
}
