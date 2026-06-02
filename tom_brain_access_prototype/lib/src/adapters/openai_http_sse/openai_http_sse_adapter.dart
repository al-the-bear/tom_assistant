// OpenAI-format HTTP/SSE inbound adapter — router scaffold (E.11).
//
// `OpenAiHttpSseAdapter` is the inbound edge for OpenAI-format traffic. It
// exposes a self-contained `shelf_router.Router` (a `shelf.Handler`)
// carrying the three prototype routes under the `/v1/` base path. The boot
// root (E.41) mounts `handler`; the E.5 loopback (Q-E.5.2) drives it by
// synthesising a `shelf.Request` and calling `handler` directly — no socket.
//
// Scope of E.11 (Plan § Phase E, substep E.11): the router and the three
// routes only. The per-route behaviour lands in later substeps and each
// stub names the step that fills it:
//   - request parsing                 → E.12
//   - SSE streaming response          → E.13
//   - non-streaming JSON response     → E.14
//   - model-id → persona mapping      → E.15
//   - `/v1/embeddings` passthrough    → E.16
//   - `/v1/models` listing            → E.17
//   - wire-format conformance tests   → E.18
//
// Until then every route answers with a wire-shaped `501 Not Implemented`
// in the OpenAI error envelope, so the scaffold is honest about what is and
// is not wired while still speaking the OpenAI dialect.

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

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

  // --- Route stubs (behaviour lands in E.12 – E.17) ----------------------

  Future<Response> _handleChatCompletions(Request request) async =>
      _notImplemented('chat/completions parsing + streaming/non-streaming '
          'response', 'E.12 – E.15');

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
  /// `{ "error": { "message", "type", "code" } }`.
  Response _errorResponse({
    required int statusCode,
    required String message,
    required String type,
    required String code,
  }) {
    final Map<String, Object?> body = <String, Object?>{
      'error': <String, Object?>{
        'message': message,
        'type': type,
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
