// Anthropic-format HTTP inbound adapter (plan item #28).
//
// `AnthropicHttpAdapter` is the inbound edge for Anthropic Messages traffic.
// Like the OpenAI (E.11) and Ollama (#27) adapters it exposes a self-contained
// `shelf_router.Router` (a `shelf.Handler`) — here carrying Anthropic's single
// endpoint, `POST /v1/messages`. The channel is wired through the shared
// admission pipeline at plan item #29; this file owns only the Anthropic wire
// dialect: parse → resolve persona → render SSE / JSON.
//
// Flow:
//   * Read and validate the JSON body into an `AnthropicRequest`
//     (`AnthropicRequest.parse`). A non-JSON or parse-invalid body returns
//     Anthropic's `{"type":"error","error":{"type":"invalid_request_error",
//     "message":<message>}}` envelope with a `400`.
//   * Resolve the request's `model` to a `Persona` via the shared
//     `OpenAiPersonaMapping` (the one persona-as-model vocabulary, E.15); the
//     resolved persona's canonical id is the `model` stamped into the rendered
//     output (a recognised id round-trips; an absent / unknown model
//     normalises to `tom-assistant`, AC-5).
//   * A streaming request (`stream` — default *false* for Anthropic, unlike
//     Ollama) renders the SSE `text/event-stream` event sequence from the
//     injected answer source; a non-streaming request buffers the same source
//     into one Message JSON object.
//   * With no source wired (the default until plan item #29 / boot) either
//     render mode answers `501` in the Anthropic error shape (type
//     `api_error`).
//
// Anthropic's error envelope differs from both siblings: it is the nested
// `{"type":"error","error":{"type":…,"message":…}}` shape — not OpenAI's
// `{"error":{...,"code","param"}}` and not Ollama's bare `{"error":<msg>}` —
// with a per-status error `type` (`invalid_request_error` / `not_found_error`
// / `api_error`).

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../openai_http_sse/persona_mapping.dart';
import 'anthropic_json.dart';
import 'anthropic_requests.dart';
import 'anthropic_sse.dart';

/// Produces the answer chunk stream for a parsed [AnthropicRequest].
///
/// The seam between the adapter (which owns the Anthropic wire format) and the
/// cognition that produces the answer — the Anthropic-channel analogue of the
/// OpenAI adapter's `ChatAnswerStream` and Ollama's `OllamaAnswerStream`. At
/// plan item #29 / boot it is wired to the dispatcher through the
/// `DeliveryRegistry`; in tests it is a synthetic stream of [OutboundChunk]s.
/// The adapter never produces chunks itself — it only renders them.
typedef AnthropicAnswerStream = Stream<OutboundChunk> Function(
  AnthropicRequest request,
);

/// The Anthropic-format HTTP inbound adapter.
///
/// Mounts the single Anthropic Messages route on a [Router] and exposes it as
/// a [Handler] via [handler]. Mirrors the OpenAI / Ollama adapters' strategy
/// (a raw `shelf_router.Router`, not annotation classes) so the bespoke
/// Anthropic wire surface stays self-contained and testable in isolation.
class AnthropicHttpAdapter {
  /// `POST` — the Anthropic Messages endpoint.
  static const String messagesPath = '/v1/messages';

  static const String _jsonContentType = 'application/json; charset=utf-8';
  static const String _sseContentType = 'text/event-stream; charset=utf-8';

  /// The injected answer-chunk source, or `null` when no cognition is wired
  /// (the default until plan item #29 / boot). A well-formed request with no
  /// source answers `501`.
  final AnthropicAnswerStream? _answerStream;

  /// Builds the adapter.
  ///
  /// [answerStream] is the seam to the cognition that produces answer chunks.
  /// When omitted, a well-formed request answers `501`; boot supplies the real
  /// dispatcher-backed producer and tests supply a synthetic one.
  AnthropicHttpAdapter({AnthropicAnswerStream? answerStream})
      : _answerStream = answerStream;

  late final Router _router = _buildRouter();

  /// The mountable shelf handler.
  Handler get handler => _router.call;

  Router _buildRouter() {
    final Router router = Router(notFoundHandler: _handleNotFound);
    router.post(messagesPath, _handleMessages);
    return router;
  }

  /// `POST /v1/messages`.
  Future<Response> _handleMessages(Request request) async {
    final Object? json;
    try {
      final String raw = await request.readAsString();
      json = raw.trim().isEmpty ? null : jsonDecode(raw);
    } on FormatException catch (e) {
      return _errorResponse(
        statusCode: 400,
        type: 'invalid_request_error',
        message: 'Request body is not valid JSON: ${e.message}',
      );
    }

    return AnthropicRequest.parse(json).fold(
      ok: _respond,
      err: (AnthropicParseError error) async => _errorResponse(
        statusCode: 400,
        type: 'invalid_request_error',
        message: error.message,
      ),
    );
  }

  /// Renders the response for a successfully-parsed request.
  ///
  /// With no answer source wired the route answers `501`. Otherwise the
  /// request's `model` is resolved to a persona (the resolved canonical id is
  /// stamped as the response `model`), and the request's `stream` flag selects
  /// the SSE streaming path or the buffered JSON path.
  Future<Response> _respond(AnthropicRequest request) async {
    final AnthropicAnswerStream? answerStream = _answerStream;
    if (answerStream == null) {
      return _errorResponse(
        statusCode: 501,
        type: 'api_error',
        message: 'No cognition is wired; this Anthropic endpoint cannot answer '
            'yet (wired at the access admission pipeline).',
      );
    }
    final Persona persona = OpenAiPersonaMapping.resolve(request.model);
    if (request.stream) {
      return _streamingResponse(request, answerStream, persona.personaId);
    }
    return _jsonResponse(request, answerStream, persona.personaId);
  }

  /// Builds the Anthropic SSE streaming response: the canonical
  /// `message_start` → … → `message_stop` event sequence, content-type
  /// `text/event-stream`. [modelId] is the resolved persona id.
  Response _streamingResponse(
    AnthropicRequest request,
    AnthropicAnswerStream answerStream,
    String modelId,
  ) {
    final AnthropicSseRenderer renderer =
        AnthropicSseRenderer.forModel(modelId);
    final Stream<List<int>> body = renderer
        .render(prompt: request.prompt, chunks: answerStream(request))
        .transform(utf8.encoder);
    return Response.ok(
      body,
      headers: <String, String>{
        'content-type': _sseContentType,
        'cache-control': 'no-cache',
      },
    );
  }

  /// Builds the Anthropic non-streaming response: one buffered Message object.
  /// [modelId] is the resolved persona id.
  Future<Response> _jsonResponse(
    AnthropicRequest request,
    AnthropicAnswerStream answerStream,
    String modelId,
  ) async {
    final AnthropicJsonRenderer renderer =
        AnthropicJsonRenderer.forModel(modelId);
    final String body = await renderer.render(
      prompt: request.prompt,
      chunks: answerStream(request),
    );
    return Response.ok(
      body,
      headers: <String, String>{'content-type': _jsonContentType},
    );
  }

  /// Fallback for any path/verb the router does not match — the Anthropic
  /// `404` not_found_error.
  Response _handleNotFound(Request request) => _errorResponse(
        statusCode: 404,
        type: 'not_found_error',
        message: 'Unknown route: ${request.method} /${request.url.path}',
      );

  /// Builds a response in Anthropic's error envelope: the nested
  /// `{"type":"error","error":{"type":<type>,"message":<message>}}` shape.
  Response _errorResponse({
    required int statusCode,
    required String type,
    required String message,
  }) {
    return Response(
      statusCode,
      body: jsonEncode(<String, Object?>{
        'type': 'error',
        'error': <String, Object?>{'type': type, 'message': message},
      }),
      headers: <String, String>{'content-type': _jsonContentType},
    );
  }
}
