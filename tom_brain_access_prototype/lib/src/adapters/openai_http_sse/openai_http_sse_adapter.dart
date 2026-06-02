// OpenAI-format HTTP/SSE inbound adapter — router + chat-request parsing
// (E.11 scaffold, E.12 chat/completions request parsing).
//
// `OpenAiHttpSseAdapter` is the inbound edge for OpenAI-format traffic. It
// exposes a self-contained `shelf_router.Router` (a `shelf.Handler`)
// carrying the three prototype routes under the `/v1/` base path. The boot
// root (E.41) mounts `handler`; the E.5 loopback (Q-E.5.2) drives it by
// synthesising a `shelf.Request` and calling `handler` directly — no socket.
//
// Per-route behaviour lands across substeps; each route names the step that
// fills it:
//   - chat/completions request parsing → E.12 (this step — wired below)
//   - SSE streaming response           → E.13
//   - non-streaming JSON response      → E.14
//   - model-id → persona mapping       → E.15
//   - `/v1/embeddings` passthrough     → E.16
//   - `/v1/models` listing             → E.17
//   - wire-format conformance tests    → E.18
//
// At E.12 the chat route validates its request body (returning the OpenAI
// `400 invalid_request_error` envelope on malformed input) and then, having
// nowhere yet to send a well-formed request, answers `501` naming the
// response substeps. The embeddings and models routes remain `501` stubs
// until their own substeps. Every route speaks the OpenAI dialect.

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'chat_completion_request.dart';

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

  /// JSON media type for every response this adapter emits.
  static const String _jsonContentType = 'application/json; charset=utf-8';

  /// Builds the adapter with an empty (stub) routing table.
  OpenAiHttpSseAdapter();

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
  /// E.12 wires the **request parsing** half: read and validate the JSON
  /// body into a [ChatCompletionRequest] (`messages` → prompt text, `model`
  /// → persona id, `stream` → render flag). A malformed body returns the
  /// OpenAI `400 invalid_request_error` envelope carrying the offending
  /// `param`. A *well-formed* request currently has nowhere to go — response
  /// generation (E.13 / E.14), persona resolution (E.15), and the dispatcher
  /// wiring (boot, E.41+) are not yet in place — so it answers `501`, now
  /// naming the response substeps rather than the parsing one.
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
      ok: (_) => _notImplemented(
        'chat/completions response generation',
        'E.13 – E.15',
      ),
      err: (ChatCompletionParseError error) => _errorResponse(
        statusCode: 400,
        message: error.message,
        type: 'invalid_request_error',
        code: error.code,
        param: error.param,
      ),
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
