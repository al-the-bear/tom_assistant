// TomBrainClient — the product-side consumer of the Tom Brain cognition.
//
// Tom Brain exposes an OpenAI-format HTTP gateway (`tom_brain_access`,
// `tom_brain_access_specification.md`): `POST /v1/chat/completions` (buffered
// and SSE-streamed), `GET /v1/models`, bearer-token auth. This client is the
// seam through which a Tom Assistant process points at a stood-up Tom Brain and
// consumes it as an OpenAI-format server — the quest `tom_brain` UB6 / OT9 wire.
//
// The client speaks the OpenAI wire format only (no compile dependency on any
// `tom_brain_*` package): a request is `{model, messages, stream}`, a buffered
// answer is `choices[0].message.content`, a streamed answer is the concatenation
// of the `choices[0].delta.content` fields across `data:` SSE frames terminated
// by `data: [DONE]`. That contract is the published surface of the gateway, so
// the consumer depends on the contract, not on brain internals.
//
// Boundary discipline: this is a system boundary (an external HTTP service), so
// a non-2xx status is surfaced as a typed [TomBrainClientException] carrying the
// status + body rather than swallowed. Nothing below the wire is defended
// against here.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A single OpenAI-format chat message (`{role, content}`).
///
/// The named constructors are the three roles a Tom Assistant turn uses; the
/// generative constructor covers any other role the caller needs.
class TomBrainMessage {
  /// The message role — `user`, `system`, or `assistant`.
  final String role;

  /// The message text.
  final String content;

  /// A message with an explicit [role].
  const TomBrainMessage({required this.role, required this.content});

  /// A `user` message carrying [content].
  const TomBrainMessage.user(this.content) : role = 'user';

  /// A `system` message carrying [content].
  const TomBrainMessage.system(this.content) : role = 'system';

  /// An `assistant` message carrying [content].
  const TomBrainMessage.assistant(this.content) : role = 'assistant';

  /// The OpenAI wire object for this message.
  Map<String, Object?> toJson() =>
      <String, Object?>{'role': role, 'content': content};
}

/// The buffered result of a `stream=false` chat completion.
class TomBrainCompletion {
  /// The assistant answer text (`choices[0].message.content`).
  final String content;

  /// The `choices[0].finish_reason` the gateway reported (e.g. `stop`), or
  /// `null` when the body omitted it.
  final String? finishReason;

  /// The `model` the gateway echoed, or `null` when the body omitted it.
  final String? model;

  /// The `chatcmpl-…` completion id, or `null` when the body omitted it.
  final String? id;

  /// Builds a completion from its parsed parts.
  const TomBrainCompletion({
    required this.content,
    this.finishReason,
    this.model,
    this.id,
  });
}

/// Thrown when the gateway answers a chat-completion request with a non-2xx
/// status — the boundary error carrying the [statusCode] and the raw [body] so
/// the caller can distinguish a `401` auth failure from a `5xx` and surface the
/// gateway's OpenAI error envelope.
class TomBrainClientException implements Exception {
  /// The HTTP status the gateway returned.
  final int statusCode;

  /// The raw response body (typically the OpenAI `{error: {...}}` envelope).
  final String body;

  /// Builds an exception for a [statusCode] / [body] pair.
  const TomBrainClientException({required this.statusCode, required this.body});

  @override
  String toString() =>
      'TomBrainClientException($statusCode): $body';
}

/// An OpenAI-format client for a stood-up Tom Brain gateway.
///
/// [baseUrl] is the gateway origin (e.g. `http://127.0.0.1:8080`); the client
/// appends [apiPrefix] (default `/v1`) + the route. [bearerToken] authenticates
/// every request. [model] is the default model id sent on each request (the
/// gateway maps it to the configured cognition).
///
/// A caller that shares an [http.Client] passes it in and owns its lifecycle;
/// otherwise the client owns an internal one that [close] disposes.
class TomBrainClient {
  /// The gateway origin — scheme + host + port, e.g. `http://127.0.0.1:8080`.
  final Uri baseUrl;

  /// The bearer token sent as `Authorization: Bearer <token>` on every request.
  final String bearerToken;

  /// The default `model` id sent on each request.
  final String model;

  /// The gateway API path prefix, normalised to a leading-slash, no-trailing-
  /// slash form (default `/v1`).
  final String _apiPrefix;

  final http.Client _httpClient;
  final bool _ownsHttpClient;

  /// Builds a client for the gateway at [baseUrl].
  TomBrainClient({
    required this.baseUrl,
    required this.bearerToken,
    this.model = 'tom-brain',
    String apiPrefix = '/v1',
    http.Client? httpClient,
  })  : _apiPrefix = _normalisePrefix(apiPrefix),
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  /// Sends [prompt] as a single `user` message and returns the buffered answer.
  /// Convenience over [complete] for the common single-turn case.
  Future<TomBrainCompletion> ask(String prompt) =>
      complete(<TomBrainMessage>[TomBrainMessage.user(prompt)]);

  /// Sends [messages] as a `stream=false` chat completion and returns the
  /// buffered answer. Throws [TomBrainClientException] on a non-2xx status.
  Future<TomBrainCompletion> complete(List<TomBrainMessage> messages) async {
    final http.Response response = await _httpClient.post(
      _endpoint('chat/completions'),
      headers: _jsonHeaders,
      body: jsonEncode(_requestBody(messages, stream: false)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TomBrainClientException(
        statusCode: response.statusCode,
        body: utf8.decode(response.bodyBytes),
      );
    }
    final Map<String, Object?> json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>;
    return _parseCompletion(json);
  }

  /// Sends [prompt] as a single `user` message and streams the answer deltas.
  /// Convenience over [stream] for the common single-turn case.
  Stream<String> askStream(String prompt) =>
      stream(<TomBrainMessage>[TomBrainMessage.user(prompt)]);

  /// Sends [messages] as a `stream=true` chat completion and yields the answer
  /// content deltas (`choices[0].delta.content`) in arrival order, ending at the
  /// `data: [DONE]` terminator. Throws [TomBrainClientException] on a non-2xx
  /// status (surfaced before any delta, since the gateway gates before the SSE
  /// branch).
  Stream<String> stream(List<TomBrainMessage> messages) async* {
    final http.Request request = http.Request('POST', _endpoint('chat/completions'))
      ..headers.addAll(_jsonHeaders)
      ..body = jsonEncode(_requestBody(messages, stream: true));
    final http.StreamedResponse response = await _httpClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String body = await response.stream.bytesToString();
      throw TomBrainClientException(statusCode: response.statusCode, body: body);
    }
    final Stream<String> lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final String line in lines) {
      if (!line.startsWith('data:')) continue;
      final String data = line.substring('data:'.length).trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') break;
      final Map<String, Object?> json = jsonDecode(data) as Map<String, Object?>;
      final String? delta = _deltaContent(json);
      if (delta != null && delta.isNotEmpty) yield delta;
    }
  }

  /// Disposes the internal [http.Client] when this client owns one. A no-op when
  /// the caller supplied its own client (the caller owns that lifecycle).
  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  Map<String, String> get _jsonHeaders => <String, String>{
        'content-type': 'application/json; charset=utf-8',
        'authorization': 'Bearer $bearerToken',
      };

  Map<String, Object?> _requestBody(
    List<TomBrainMessage> messages, {
    required bool stream,
  }) =>
      <String, Object?>{
        'model': model,
        'messages': <Object?>[for (final TomBrainMessage m in messages) m.toJson()],
        'stream': stream,
      };

  Uri _endpoint(String route) {
    final String origin =
        baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$origin$_apiPrefix/$route');
  }

  static String _normalisePrefix(String prefix) {
    var normalised = prefix.trim();
    if (!normalised.startsWith('/')) normalised = '/$normalised';
    normalised = normalised.replaceAll(RegExp(r'/+$'), '');
    return normalised;
  }

  static TomBrainCompletion _parseCompletion(Map<String, Object?> json) {
    final Object? choices = json['choices'];
    var content = '';
    String? finishReason;
    if (choices is List && choices.isNotEmpty) {
      final Object? first = choices.first;
      if (first is Map) {
        final Object? message = first['message'];
        if (message is Map && message['content'] is String) {
          content = message['content'] as String;
        }
        final Object? reason = first['finish_reason'];
        if (reason is String) finishReason = reason;
      }
    }
    return TomBrainCompletion(
      content: content,
      finishReason: finishReason,
      model: json['model'] is String ? json['model'] as String : null,
      id: json['id'] is String ? json['id'] as String : null,
    );
  }

  static String? _deltaContent(Map<String, Object?> json) {
    final Object? choices = json['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final Object? first = choices.first;
    if (first is! Map) return null;
    final Object? delta = first['delta'];
    if (delta is! Map) return null;
    final Object? content = delta['content'];
    return content is String ? content : null;
  }
}
