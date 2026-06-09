// Ollama-format HTTP inbound adapter (plan item #27).
//
// `OllamaHttpAdapter` is the inbound edge for Ollama-format traffic. Like the
// OpenAI adapter (E.11) it exposes a self-contained `shelf_router.Router`
// (a `shelf.Handler`) — here carrying Ollama's two endpoints,
// `POST /api/chat` and `POST /api/generate`. The two channels are wired
// through the shared admission pipeline at plan item #29; this file owns only
// the Ollama wire dialect: parse → resolve persona → render NDJSON / JSON.
//
// Flow per route:
//   * Read and validate the JSON body into an `OllamaRequest` (`parseChat` /
//     `parseGenerate`). A non-JSON or parse-invalid body returns Ollama's bare
//     `{"error": <message>}` object with a `400`.
//   * Resolve the request's `model` to a `Persona` via the shared
//     `OpenAiPersonaMapping` (the one persona-as-model vocabulary, E.15); the
//     resolved persona's canonical id is the `model` stamped into the rendered
//     output (a recognised id round-trips; an absent / unknown model
//     normalises to `tom-assistant`, AC-5).
//   * A streaming request (`stream` — default true for Ollama) renders the
//     NDJSON `application/x-ndjson` body from the injected answer source; a
//     non-streaming request buffers the same source into one JSON object.
//   * With no source wired (the default until plan item #29 / boot) either
//     render mode answers `501` in the Ollama error shape.
//
// Ollama's wire diverges from OpenAI's in shape (NDJSON not SSE, a `done:true`
// terminator not `[DONE]`, no `id`) and in its error envelope (a bare
// `{"error": <message>}` string, not the OpenAI nested `{"error":{...}}`).

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../openai_http_sse/persona_mapping.dart';
import 'ollama_json.dart';
import 'ollama_ndjson.dart';
import 'ollama_requests.dart';

/// Produces the answer chunk stream for a parsed [OllamaRequest].
///
/// The seam between the adapter (which owns the Ollama wire format) and the
/// cognition that produces the answer — the Ollama-channel analogue of the
/// OpenAI adapter's `ChatAnswerStream`. At plan item #29 / boot it is wired to
/// the dispatcher through the `DeliveryRegistry`; in tests it is a synthetic
/// stream of [OutboundChunk]s. The adapter never produces chunks itself — it
/// only renders them.
typedef OllamaAnswerStream = Stream<OutboundChunk> Function(
  OllamaRequest request,
);

/// The Ollama-format HTTP inbound adapter.
///
/// Mounts the two Ollama routes on a [Router] and exposes it as a [Handler]
/// via [handler]. Mirrors `OpenAiHttpSseAdapter`'s strategy (a raw
/// `shelf_router.Router`, not annotation classes) so the bespoke Ollama wire
/// surface stays self-contained and testable in isolation.
class OllamaHttpAdapter {
  /// `POST` — the chat endpoint (`messages` array → last user prompt).
  static const String chatPath = '/api/chat';

  /// `POST` — the generate endpoint (`prompt` string).
  static const String generatePath = '/api/generate';

  static const String _jsonContentType = 'application/json; charset=utf-8';
  static const String _ndjsonContentType = 'application/x-ndjson';

  /// The injected answer-chunk source, or `null` when no cognition is wired
  /// (the default until plan item #29 / boot). A well-formed request with no
  /// source answers `501`.
  final OllamaAnswerStream? _answerStream;

  /// Builds the adapter.
  ///
  /// [answerStream] is the seam to the cognition that produces answer chunks.
  /// When omitted, a well-formed request answers `501`; boot supplies the real
  /// dispatcher-backed producer and tests supply a synthetic one.
  OllamaHttpAdapter({OllamaAnswerStream? answerStream})
      : _answerStream = answerStream;

  late final Router _router = _buildRouter();

  /// The mountable shelf handler.
  Handler get handler => _router.call;

  Router _buildRouter() {
    final Router router = Router(notFoundHandler: _handleNotFound);
    router.post(chatPath, _handleChat);
    router.post(generatePath, _handleGenerate);
    return router;
  }

  /// `POST /api/chat`.
  Future<Response> _handleChat(Request request) =>
      _handle(request, OllamaRequest.parseChat);

  /// `POST /api/generate`.
  Future<Response> _handleGenerate(Request request) =>
      _handle(request, OllamaRequest.parseGenerate);

  /// Shared decode → parse → respond pipeline for both endpoints. [parse] is
  /// the per-endpoint parser; everything downstream of a successful parse is
  /// identical across the two routes.
  Future<Response> _handle(
    Request request,
    Result<OllamaRequest, OllamaParseError> Function(Object? body) parse,
  ) async {
    final Object? json;
    try {
      final String raw = await request.readAsString();
      json = raw.trim().isEmpty ? null : jsonDecode(raw);
    } on FormatException catch (e) {
      return _errorResponse(
        statusCode: 400,
        message: 'Request body is not valid JSON: ${e.message}',
      );
    }

    return parse(json).fold(
      ok: _respond,
      err: (OllamaParseError error) async =>
          _errorResponse(statusCode: 400, message: error.message),
    );
  }

  /// Renders the response for a successfully-parsed request.
  ///
  /// With no answer source wired the route answers `501`. Otherwise the
  /// request's `model` is resolved to a persona (the resolved canonical id is
  /// stamped as the response `model`), and the request's `stream` flag selects
  /// the NDJSON streaming path or the buffered JSON path.
  Future<Response> _respond(OllamaRequest request) async {
    final OllamaAnswerStream? answerStream = _answerStream;
    if (answerStream == null) {
      return _errorResponse(
        statusCode: 501,
        message: 'No cognition is wired; this Ollama endpoint cannot answer '
            'yet (wired at the access admission pipeline).',
      );
    }
    final Persona persona = OpenAiPersonaMapping.resolve(request.model);
    if (request.stream) {
      return _streamingResponse(request, answerStream, persona.personaId);
    }
    return _jsonResponse(request, answerStream, persona.personaId);
  }

  /// Builds the Ollama NDJSON streaming response: one `done: false` line per
  /// chunk, a terminal `done: true` line, content-type
  /// `application/x-ndjson`. [modelId] is the resolved persona id.
  Response _streamingResponse(
    OllamaRequest request,
    OllamaAnswerStream answerStream,
    String modelId,
  ) {
    final OllamaNdjsonRenderer renderer =
        OllamaNdjsonRenderer.forModel(modelId, request.shape);
    final Stream<List<int>> body =
        renderer.render(answerStream(request)).transform(utf8.encoder);
    return Response.ok(
      body,
      headers: <String, String>{'content-type': _ndjsonContentType},
    );
  }

  /// Builds the Ollama non-streaming response: one buffered JSON object with
  /// `done: true`. [modelId] is the resolved persona id.
  Future<Response> _jsonResponse(
    OllamaRequest request,
    OllamaAnswerStream answerStream,
    String modelId,
  ) async {
    final OllamaJsonRenderer renderer =
        OllamaJsonRenderer.forModel(modelId, request.shape);
    final String body = await renderer.render(answerStream(request));
    return Response.ok(
      body,
      headers: <String, String>{'content-type': _jsonContentType},
    );
  }

  /// Fallback for any path/verb the router does not match — the Ollama `404`
  /// error object (a bare `{"error": <message>}`).
  Response _handleNotFound(Request request) => _errorResponse(
        statusCode: 404,
        message: 'Unknown route: ${request.method} /${request.url.path}',
      );

  /// Builds a response in Ollama's error envelope: a bare
  /// `{"error": <message>}` object (not the OpenAI nested shape).
  Response _errorResponse({required int statusCode, required String message}) {
    return Response(
      statusCode,
      body: jsonEncode(<String, Object?>{'error': message}),
      headers: <String, String>{'content-type': _jsonContentType},
    );
  }
}
