// OpenAI-format HTTP/SSE inbound adapter — router, chat-request parsing,
// the SSE streaming response, and the non-streaming JSON response
// (E.11 scaffold, E.12 request parsing, E.13 streaming render, E.14
// non-streaming JSON render).
//
// `OpenAiHttpSseAdapter` is the inbound edge for OpenAI-format traffic. It
// exposes a self-contained `shelf_router.Router` (a `shelf.Handler`)
// carrying the three prototype routes under the `/v1/` base path. The boot
// root (E.41) mounts `handler`; the E.5 loopback (Q-E.5.2) drives it by
// synthesising a `shelf.Request` and calling `handler` directly — no socket.
//
// Per-route behaviour lands across substeps; each route names the step that
// fills it:
//   - chat/completions request parsing → E.12 (wired)
//   - SSE streaming response           → E.13 (wired)
//   - non-streaming JSON response      → E.14 (this step — wired below)
//   - model-id → persona mapping       → E.15
//   - `/v1/embeddings` passthrough     → E.16
//   - `/v1/models` listing             → E.17
//   - wire-format conformance tests    → E.18
//
// At E.14 the chat route renders a real response for either render mode of a
// well-formed request — provided a chunk source has been injected (the
// `answerStream` seam): a *streaming* request (`stream: true`) gets the SSE
// `text/event-stream` body (E.13); a *non-streaming* request gets a buffered
// `chat.completion` JSON body (E.14). The chunk source itself (the
// dispatcher/engine, via the `DeliveryRegistry`) is wired at boot (E.41+);
// until one is injected, *either* render mode answers `501`. The embeddings
// and models routes remain `501` stubs until their own substeps. Every route
// speaks the OpenAI dialect.

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'chat_completion_json.dart';
import 'chat_completion_request.dart';
import 'chat_completion_sse.dart';

/// Produces the answer chunk stream for a parsed [ChatCompletionRequest].
///
/// This is the seam between the adapter (which owns the OpenAI wire format)
/// and the cognition that produces the answer. At boot (E.41+) it is wired
/// to the dispatcher/engine through the `DeliveryRegistry` (E.36); in tests
/// it is a synthetic stream of [OutboundChunk]s. The adapter never produces
/// chunks itself — it only renders them.
typedef ChatAnswerStream = Stream<OutboundChunk> Function(
  ChatCompletionRequest request,
);

/// The OpenAI-format HTTP/SSE inbound adapter.
///
/// Mounts the prototype's three `/v1/` routes on a [Router] and exposes it
/// as a [Handler] via [handler]. Strategy 2 of Q-E.3.2 (a raw
/// `shelf_router.Router`, not `tom_core_server` annotation classes): the
/// OpenAI wire surface — non-standard SSE framing and bespoke JSON shapes —
/// stays self-contained in this one file, which keeps it testable in
/// isolation against captured OpenAI fixtures (E.53).
///
/// At E.11 the routes are inert stubs. See the file header for the substep
/// that fills each one.
class OpenAiHttpSseAdapter {
  /// The base path every prototype route hangs under.
  static const String basePath = '/v1';

  /// `POST` — the primary chat-completions surface (streaming + not).
  static const String chatCompletionsPath = '$basePath/chat/completions';

  /// `POST` — the embeddings passthrough to substrate (E.16).
  static const String embeddingsPath = '$basePath/embeddings';

  /// `GET` — the persona-as-model listing (E.17).
  static const String modelsPath = '$basePath/models';

  /// JSON media type for every JSON response this adapter emits.
  static const String _jsonContentType = 'application/json; charset=utf-8';

  /// SSE media type for the streaming chat-completions response (E.13).
  static const String _eventStreamContentType =
      'text/event-stream; charset=utf-8';

  /// The model id echoed into SSE frames when the request omits `model`.
  /// This is a literal placeholder, NOT persona resolution — the real
  /// `model` → `Persona` mapping (and its default) is E.15.
  static const String _defaultModel = 'tom-assistant';

  /// The injected answer-chunk source, or `null` when no cognition is wired
  /// (the prototype's default until boot, E.41+). A streaming request with
  /// no source answers `501`.
  final ChatAnswerStream? _answerStream;

  /// Builds the adapter.
  ///
  /// [answerStream] is the seam to the cognition that produces answer
  /// chunks. When omitted, the chat route has no chunk source and a
  /// streaming request answers `501`; boot (E.41+) supplies the real
  /// dispatcher-backed producer, and tests supply a synthetic one.
  OpenAiHttpSseAdapter({ChatAnswerStream? answerStream})
      : _answerStream = answerStream;

  late final Router _router = _buildRouter();

  /// The mountable shelf handler. `Router` is itself a [Handler]; the boot
  /// root mounts this and the loopback calls it directly.
  Handler get handler => _router.call;

  Router _buildRouter() {
    final Router router = Router(notFoundHandler: _handleNotFound);
    router.post(chatCompletionsPath, _handleChatCompletions);
    router.post(embeddingsPath, _handleEmbeddings);
    router.get(modelsPath, _handleModels);
    return router;
  }

  // --- Route handlers ----------------------------------------------------

  /// `POST /v1/chat/completions`.
  ///
  /// E.12 wired the **request parsing** half; E.13 wired the **streaming
  /// response**; E.14 wires the **non-streaming JSON response**. Flow:
  ///
  ///   * Read and validate the JSON body into a [ChatCompletionRequest]. A
  ///     malformed body returns the OpenAI `400 invalid_request_error`
  ///     envelope carrying the offending `param`.
  ///   * A well-formed **streaming** request (`stream: true`) renders an
  ///     SSE `text/event-stream` response from the injected answer-chunk
  ///     source ([_answerStream]).
  ///   * A well-formed **non-streaming** request buffers the same source
  ///     into one `chat.completion` JSON body.
  ///   * With no source wired (the default until boot, E.41+) *either*
  ///     render mode answers `501`.
  ///
  /// Persona resolution (E.15) and the real chunk source (boot, E.41+) are
  /// still out of scope here.
  Future<Response> _handleChatCompletions(Request request) async {
    final Object? json;
    try {
      final String raw = await request.readAsString();
      json = raw.trim().isEmpty ? null : jsonDecode(raw);
    } on FormatException catch (e) {
      return _errorResponse(
        statusCode: 400,
        message: 'Request body is not valid JSON: ${e.message}',
        type: 'invalid_request_error',
        code: 'invalid_body',
      );
    }

    return ChatCompletionRequest.parse(json).fold(
      ok: _respondToChatCompletion,
      err: (ChatCompletionParseError error) async => _errorResponse(
        statusCode: 400,
        message: error.message,
        type: 'invalid_request_error',
        code: error.code,
        param: error.param,
      ),
    );
  }

  /// Renders the response for a successfully-parsed chat request.
  ///
  /// Both render modes need the injected answer-chunk source; with none
  /// wired (the default until boot, E.41+) the route answers `501`. A
  /// streaming request gets the E.13 SSE path; a non-streaming request gets
  /// the E.14 buffered JSON body.
  Future<Response> _respondToChatCompletion(
    ChatCompletionRequest request,
  ) async {
    final ChatAnswerStream? answerStream = _answerStream;
    if (answerStream == null) {
      return _notImplemented(
        'chat/completions answer source (no cognition wired)',
        'boot E.41+',
      );
    }
    if (request.stream) {
      return _streamingChatResponse(request, answerStream);
    }
    return _jsonChatResponse(request, answerStream);
  }

  /// Builds the OpenAI non-streaming `chat.completion` JSON response (proto
  /// spec § 5.4).
  ///
  /// Buffers every [OutboundChunk] from [answerStream] into one answer body
  /// via [ChatCompletionJsonRenderer], then returns it as an
  /// `application/json` response. `usage` token counts are the renderer's
  /// approximate char/4 estimate (Q-E.2.1) until the run surfaces real
  /// effort metrics.
  Future<Response> _jsonChatResponse(
    ChatCompletionRequest request,
    ChatAnswerStream answerStream,
  ) async {
    final ChatCompletionJsonRenderer renderer =
        ChatCompletionJsonRenderer.forModel(request.model ?? _defaultModel);
    final String body = await renderer.render(
      prompt: request.prompt,
      chunks: answerStream(request),
    );
    return Response.ok(
      body,
      headers: <String, String>{'content-type': _jsonContentType},
    );
  }

  /// Builds the OpenAI SSE streaming response (proto spec § 5.3).
  ///
  /// Each [OutboundChunk] from [answerStream] becomes one `data: {…}\n\n`
  /// `chat.completion.chunk` frame; the stream is terminated by a final
  /// `data: [DONE]\n\n` line. The body is a lazily-rendered UTF-8 byte
  /// stream, so chunks reach the client as the cognition produces them.
  Response _streamingChatResponse(
    ChatCompletionRequest request,
    ChatAnswerStream answerStream,
  ) {
    final ChatCompletionSseRenderer renderer =
        ChatCompletionSseRenderer.forModel(request.model ?? _defaultModel);
    final Stream<List<int>> body =
        renderer.render(answerStream(request)).transform(utf8.encoder);
    return Response.ok(
      body,
      headers: <String, String>{
        'content-type': _eventStreamContentType,
        'cache-control': 'no-cache',
      },
    );
  }

  Future<Response> _handleEmbeddings(Request request) async =>
      _notImplemented('embeddings passthrough', 'E.16');

  Future<Response> _handleModels(Request request) async =>
      _notImplemented('models listing', 'E.17');

  /// Fallback for any path/verb the router does not match. Returns the
  /// OpenAI `404` error envelope rather than shelf's plain-text default so
  /// even unknown routes speak the OpenAI dialect.
  Response _handleNotFound(Request request) {
    return _errorResponse(
      statusCode: 404,
      message: 'Unknown route: ${request.method} /${request.url.path}',
      type: 'invalid_request_error',
      code: 'not_found',
    );
  }

  /// A wire-shaped `501` for a route whose behaviour is not yet wired.
  Response _notImplemented(String surface, String step) {
    return _errorResponse(
      statusCode: 501,
      message: 'The $surface surface is not yet implemented '
          '(lands at $step).',
      type: 'not_implemented',
      code: 'not_implemented',
    );
  }

  /// Builds a response in the OpenAI error envelope:
  /// `{ "error": { "message", "type", "param", "code" } }`. [param] is the
  /// offending request parameter (e.g. `messages`); it is included as an
  /// explicit `null` for non-parameter errors, matching the OpenAI shape.
  Response _errorResponse({
    required int statusCode,
    required String message,
    required String type,
    required String code,
    String? param,
  }) {
    final Map<String, Object?> body = <String, Object?>{
      'error': <String, Object?>{
        'message': message,
        'type': type,
        'param': param,
        'code': code,
      },
    };
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: <String, String>{'content-type': _jsonContentType},
    );
  }
}
