// B.2.3 — shared wire-client transport base.
//
// `OllamaHttpClient` (B.14) and `OpenAiHttpClient` (B.15) are wire-shape
// twins. Before this extraction each `Default…` client owned a verbatim
// copy of all of the following:
//
//   * the owned-`http.Client` skeleton (`_inner` + `_ownsInner` + the
//     `close()` that disposes only what it owns);
//   * the JSON `POST` round-trip (encode body, apply headers, honour an
//     optional per-call timeout, map a non-2xx status onto a typed wire
//     exception);
//   * the `GET` round-trip with the same timeout + status discipline;
//   * the streaming `POST` open (send the request, drain + throw on a
//     non-2xx status, expose the body as UTF-8 decoded lines);
//   * the B.3.1 decode-or-throw that maps a malformed / non-object 2xx
//     body onto the same typed wire exception so a bare `FormatException`
//     never escapes the router's route-walk.
//
// This base owns those transport mechanics; each backend keeps only what
// is genuinely backend-specific:
//
//   * Endpoint paths + payload shaping — `/api/chat` + Ollama's
//     `options` / `format` map vs `/v1/chat/completions` + OpenAI's
//     `stream_options` / `response_format` fields.
//   * Headers — Ollama sends only `Content-Type`; OpenAI adds
//     `Authorization: Bearer …` plus caller `extraHeaders`.
//   * Value types + decoders — the response / fragment / embedding
//     shapes differ field-for-field.
//   * The per-line parse loop — Ollama treats every NDJSON line as a
//     frame and carries a terminal `done: true`; OpenAI strips the SSE
//     `data:` prefix, skips comment lines, and ends on the `[DONE]`
//     sentinel. Only the *line transport* (open + status-check + UTF-8
//     line split) is shared; the framing stays per-backend.
//   * The named exception subtype — [OllamaHttpException] /
//     [OpenAiHttpException] keep the backend-family signal the trail and
//     the B.3.1 conformance tests read. The mapping that *throws* them
//     is shared here; only the constructed type differs, supplied by
//     each subclass through [DefaultWireHttpClientBase.wireException].
//
// What this base deliberately does NOT own (same boundary as B.14/B.15):
//
//   * Retry / backoff / circuit-breaker policy — the router (B.18+).
//   * Failure classification — the router maps [WireHttpException] onto
//     the spec § 5.4 taxonomy (`LlmFailureClassifier`).
//   * Cancellation-token transport. The per-line loop checks the token
//     between frames (best-effort, B.14/B.15 posture); a transport-level
//     cancellable client lands at B.18.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tom_core_agentic/tom_core_agentic.dart' show textPreview;

/// Base for the typed wire exceptions a `Default…` HTTP client throws
/// when a backend answers with a non-2xx status or a malformed 2xx body.
///
/// Concrete subtypes ([OllamaHttpException], [OpenAiHttpException]) add
/// only the backend-family [label]. The carried fields and the
/// status→failure mapping are identical across families, so the router's
/// `LlmFailureClassifier` matches the [WireHttpException] supertype
/// rather than each subtype.
///
/// It is *not* a typed `LlmFailure` — that translation belongs to the
/// router, not the wire layer.
abstract class WireHttpException implements Exception {
  /// The non-2xx status the backend answered with — or the status the
  /// 2xx response carried when the body failed to decode (B.3.1).
  final int statusCode;

  /// The raw response body (for a non-2xx status) or a diagnostic
  /// excerpt (for a malformed 2xx body).
  final String body;

  /// The endpoint the failed round-trip targeted.
  final Uri endpoint;

  const WireHttpException({
    required this.statusCode,
    required this.body,
    required this.endpoint,
  });

  /// Backend-family tag used in [toString] (e.g. `OllamaHttpException`).
  String get label;

  @override
  String toString() => '$label($statusCode at $endpoint): $body';
}

/// Sentinel raised by a streaming wire client when its cancellation
/// token signals between frames. Translated to
/// `LlmFailure(cancelled_by_consumer)` at the router (B.18). Internal —
/// not exported from the package barrel.
class WireStreamCancelled implements Exception {
  /// Backend-family label for diagnostics (e.g. `Ollama`, `OpenAI`).
  final String backend;

  const WireStreamCancelled(this.backend);

  @override
  String toString() => '$backend wire stream cancelled by consumer';
}

/// Shared transport for the `Default…` wire clients (Ollama, OpenAI).
///
/// `base`: subclasses `extend` it within the package (so they inherit
/// the transport plumbing) but nothing outside re-implements the
/// transport by hand — that is exactly the duplication this class
/// removes.
///
/// Subclasses supply [wireException] (the backend-family exception
/// factory) plus their endpoint paths, headers, payload shaping, and
/// decoders; the round-trip / timeout / status / decode plumbing lives
/// here.
abstract base class DefaultWireHttpClientBase {
  final http.Client _inner;

  /// Whether [close] should also close the underlying [http.Client].
  /// `false` when the caller injected a client whose lifetime they
  /// manage themselves.
  final bool _ownsInner;

  DefaultWireHttpClientBase({http.Client? client})
      : _inner = client ?? http.Client(),
        _ownsInner = client == null;

  /// Builds the backend-specific [WireHttpException] subtype. The
  /// transport methods below call this so the thrown type keeps the
  /// backend-family signal while the mapping logic stays shared.
  WireHttpException wireException({
    required int statusCode,
    required String body,
    required Uri endpoint,
  });

  /// One JSON `POST` round-trip. Encodes [jsonBody], applies [headers],
  /// honours [requestTimeout], and throws [wireException] on a non-2xx
  /// status. Returns the raw 2xx response for the caller to decode.
  Future<http.Response> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Object? jsonBody,
    Duration? requestTimeout,
  }) async {
    final future = _inner.post(url, headers: headers, body: jsonEncode(jsonBody));
    final response = await _awaitWithTimeout(future, requestTimeout);
    _throwIfNotOk(response, url);
    return response;
  }

  /// One `GET` round-trip with the same timeout + status discipline as
  /// [postJson]. [headers] may be `null` for unauthenticated endpoints.
  Future<http.Response> getUrl({
    required Uri url,
    Map<String, String>? headers,
    Duration? requestTimeout,
  }) async {
    final future = _inner.get(url, headers: headers);
    final response = await _awaitWithTimeout(future, requestTimeout);
    _throwIfNotOk(response, url);
    return response;
  }

  /// Opens a streaming `POST` and yields the response body as UTF-8
  /// decoded lines. Applies [headers] + [requestTimeout], drains the
  /// error body and throws [wireException] on a non-2xx status. The
  /// per-line parsing (frame decode, SSE prefix handling, terminal
  /// sentinel, cancellation checks) is the caller's concern.
  Stream<String> sendForLines({
    required Uri url,
    required Map<String, String> headers,
    required String body,
    Duration? requestTimeout,
  }) async* {
    final request = http.Request('POST', url)
      ..headers.addAll(headers)
      ..body = body;
    final sendFuture = _inner.send(request);
    final response = await _awaitWithTimeout(sendFuture, requestTimeout);
    if (_isNotOk(response.statusCode)) {
      final errBody = await response.stream.bytesToString();
      throw wireException(
        statusCode: response.statusCode,
        body: errBody,
        endpoint: url,
      );
    }
    yield* response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
  }

  /// B.3.1 — decode [body] as a JSON object on a 2xx response. Maps a
  /// malformed-JSON `FormatException` and a valid-but-non-object body
  /// onto [wireException], carrying [endpoint] and a body excerpt so the
  /// router classifies it instead of letting a bare `FormatException`
  /// escape the route-walk.
  ///
  /// [shape] names the expected structure; it is reused for both the
  /// malformed-JSON message and the valid-JSON-but-not-an-object branch
  /// so the error envelopes are uniform.
  Map<String, Object?> decodeJsonObject(
    String body, {
    required int statusCode,
    required Uri endpoint,
    required String shape,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw wireException(
        statusCode: statusCode,
        body: 'Malformed JSON ($shape expected): ${e.message}. '
            'Body: ${textPreview(body)}',
        endpoint: endpoint,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw wireException(
        statusCode: statusCode,
        body: 'Expected $shape, got: ${textPreview(body)}',
        endpoint: endpoint,
      );
    }
    return decoded;
  }

  /// Releases the owned [http.Client]; a no-op when the caller injected
  /// the client and manages its lifetime.
  void close() {
    if (_ownsInner) _inner.close();
  }

  void _throwIfNotOk(http.Response response, Uri url) {
    if (_isNotOk(response.statusCode)) {
      throw wireException(
        statusCode: response.statusCode,
        body: response.body,
        endpoint: url,
      );
    }
  }

  static bool _isNotOk(int statusCode) =>
      statusCode < 200 || statusCode >= 300;

  static Future<T> _awaitWithTimeout<T>(Future<T> future, Duration? timeout) =>
      timeout == null ? future : future.timeout(timeout);
}
