// OpenAiAccessEdge — the live, auth-gated OpenAI HTTP/SSE channel of the
// running access process (E.45; proto spec § 5 / § 8 / § 11).
//
// ── What this is, and how it differs from `OpenAiHttpSseAdapter` ─────
//
// `OpenAiHttpSseAdapter` (E.11–E.18) is the *wire-format* surface: it owns
// the OpenAI envelope (request parsing, the `chat.completion` / `.chunk`
// shapes, the models list, the error envelope) and was deliberately built
// to render answers from an *injected* `ChatAnswerStream` seam with **no
// auth and no edge security** — it is the format contract, proven in
// isolation against captured fixtures (E.18).
//
// `OpenAiAccessEdge` is the *running-process* surface: it drives the
// E.41 `AccessAssembler`, so every request runs the full inbound flow —
// bearer auth (E.28) → identity (E.24) → rate-limit (E.29) → quota (E.30) →
// anchor (E.31) → session (E.25) → classify (E.33) → delivery (E.37) →
// `dispatcher.accept`. It cannot reuse the adapter's `_handleChatCompletions`
// (that bypasses auth), so it owns a fresh router, but it speaks the *same*
// OpenAI dialect (it reuses `ChatCompletionRequest`, the SSE / JSON
// renderers, the models renderer, and the same error-envelope shape).
//
// ── Why the SSE sink is captured, then replayed ──────────────────────
//
// `AccessAssembler.admitOpenAi` always binds an `SseDeliveryBinding` (E.37)
// and `await`s `dispatcher.accept`, so the answer is fully delivered into
// the sink by the time `admitOpenAi` returns. The edge-security gates all
// run *before* delivery and throw on rejection, so awaiting the whole
// `admitOpenAi` lets the edge map a rejection onto the correct HTTP status
// *before* any byte of a `200` body is sent — the price is that streaming is
// buffered-then-replayed rather than truly incremental. For the prototype
// that trade (correct status codes over incremental flush) is the right one;
// it is logged in the questions doc (Q-E.45.2). A non-streaming request
// reconstructs the one `chat.completion` body from the captured frames
// (Q-E.45.3).

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/openai_http_sse/chat_completion_json.dart';
import '../adapters/openai_http_sse/chat_completion_request.dart';
import '../adapters/openai_http_sse/models_response.dart';
import '../adapters/openai_http_sse/openai_http_sse_adapter.dart'
    show OpenAiHttpSseAdapter;
import '../adapters/openai_http_sse/persona_mapping.dart';
import '../boot/access_assembler.dart';
import '../delivery/sse_delivery.dart';
import '../edge_security/edge_security.dart';
import '../identity/identity_resolver.dart';
import 'json_response.dart';

/// The live, auth-gated OpenAI HTTP/SSE channel (E.45).
///
/// Construct one per running process over the booted [AccessAssembler]; mount
/// [handler] on the live port (the boot root composes it with the health
/// endpoint). Every `POST /v1/chat/completions` runs the full E.41 admission
/// pipeline; `GET /v1/models` is the static persona listing; `POST
/// /v1/embeddings` is `501` (embeddings are a substrate passthrough the access
/// process does not own — the dispatcher path is for cognitions, not
/// embeddings). Any other route is the OpenAI `404` envelope.
class OpenAiAccessEdge {
  /// The base path every route hangs under. Defaults to the adapter's `/v1`.
  final String basePath;

  /// SSE media type for the streaming response.
  static const String _eventStreamContentType =
      'text/event-stream; charset=utf-8';

  final AccessAssembler _assembler;
  final List<String> _models;

  /// Builds the edge over the booted [assembler].
  ///
  /// [basePath] defaults to [OpenAiHttpSseAdapter.basePath] (`/v1`); a config
  /// may override it. [models] is the persona-as-model vocabulary the
  /// `/v1/models` route lists; it defaults to
  /// [OpenAiPersonaMapping.knownModels].
  OpenAiAccessEdge({
    required AccessAssembler assembler,
    String? basePath,
    List<String>? models,
  })  : _assembler = assembler,
        basePath = basePath ?? OpenAiHttpSseAdapter.basePath,
        _models = models ?? OpenAiPersonaMapping.knownModels;

  late final Router _router = _buildRouter();

  /// The mountable shelf handler. `Router` is itself a [Handler].
  Handler get handler => _router.call;

  Router _buildRouter() {
    final Router router = Router(notFoundHandler: _handleNotFound);
    router.post('$basePath/chat/completions', _handleChatCompletions);
    router.post('$basePath/embeddings', _handleEmbeddings);
    router.get('$basePath/models', _handleModels);
    return router;
  }

  // --- Routes ------------------------------------------------------------

  /// `POST /v1/chat/completions` — the auth-gated chat surface.
  ///
  /// Lifts the bearer token from the `Authorization` header, parses the body,
  /// drives [AccessAssembler.admitOpenAi] through a capturing SSE sink, and
  /// renders the captured answer (SSE replay for a streaming request, a
  /// reconstructed `chat.completion` body otherwise). A failure at any edge
  /// gate (or in dispatch) is mapped to the matching OpenAI error envelope.
  Future<Response> _handleChatCompletions(Request request) async {
    // ── 1. Bearer credential (E.28). A missing / malformed header is a 401
    //    before we even parse the body. ──
    final String bearerToken;
    try {
      bearerToken = parseBearerHeader(
        request.headers[authorizationHeaderName],
      );
    } on BearerAuthFailure catch (failure) {
      return _errorFor(failure);
    }

    // ── 2. Parse the OpenAI body (same DTO as the format adapter). ──
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
      ok: (ChatCompletionRequest parsed) =>
          _admitAndRespond(bearerToken, parsed),
      err: (ChatCompletionParseError error) async => _errorResponse(
        statusCode: 400,
        message: error.message,
        type: 'invalid_request_error',
        code: error.code,
        param: error.param,
      ),
    );
  }

  /// Drives the admission pipeline and renders the captured answer.
  Future<Response> _admitAndRespond(
    String bearerToken,
    ChatCompletionRequest request,
  ) async {
    final _CapturingSseSink sink = _CapturingSseSink();
    final InboundRequest envelope = request.toInboundRequest();
    try {
      await _assembler.admitOpenAi(
        bearerToken: bearerToken,
        modelId: request.model,
        envelope: envelope,
        sink: sink,
      );
    } catch (error) {
      return _errorFor(error);
    }

    if (request.stream) {
      return Response.ok(
        sink.frames.join(),
        headers: <String, String>{
          'content-type': _eventStreamContentType,
          'cache-control': 'no-cache',
        },
      );
    }
    return _jsonFromFrames(envelope, sink.frames, request.model);
  }

  /// Rebuilds the non-streaming `chat.completion` body from the captured SSE
  /// frames (Q-E.45.3): concatenate every frame's `choices[0].delta.content`,
  /// read the resolved persona id off the frames' `model` field, and render
  /// the one buffered body via [ChatCompletionJsonRenderer].
  Future<Response> _jsonFromFrames(
    InboundRequest envelope,
    List<String> frames,
    String? requestedModel,
  ) async {
    final StringBuffer content = StringBuffer();
    String? model;
    for (final String frame in frames) {
      final Map<String, Object?>? payload = _decodeFrame(frame);
      if (payload == null) continue;
      model ??= payload['model'] as String?;
      final Object? choices = payload['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final Object? first = choices.first;
      if (first is! Map<String, Object?>) continue;
      final Object? delta = first['delta'];
      if (delta is Map<String, Object?> && delta['content'] is String) {
        content.write(delta['content'] as String);
      }
    }
    final String modelId =
        model ?? OpenAiPersonaMapping.resolve(requestedModel).personaId;
    final ChatCompletionJsonRenderer renderer =
        ChatCompletionJsonRenderer.forModel(modelId);
    final String body = renderer.bodyJson(
      prompt: envelope.text,
      content: content.toString(),
    );
    return jsonResponse(body);
  }

  /// Decodes one `data: {…}\n\n` SSE frame to its JSON payload, or `null` for
  /// the terminal `data: [DONE]` line and any non-data frame.
  Map<String, Object?>? _decodeFrame(String frame) {
    final String line = frame.trim();
    if (!line.startsWith('data:')) return null;
    final String payload = line.substring('data:'.length).trim();
    if (payload.isEmpty || payload == '[DONE]') return null;
    final Object? decoded = jsonDecode(payload);
    return decoded is Map<String, Object?> ? decoded : null;
  }

  /// `POST /v1/embeddings` — `501`.
  ///
  /// Embeddings are a substrate passthrough (proto spec § 5.6); the running
  /// access process drives the dispatcher, which is for cognitions, not the
  /// embedding service. A higher assembly that needs embeddings mounts the
  /// format adapter's embeddings route with a substrate-backed source; the
  /// auth-gated edge does not.
  Future<Response> _handleEmbeddings(Request request) async {
    return _errorResponse(
      statusCode: 501,
      message: 'The embeddings surface is not served by the access process '
          '(it drives the cognition dispatcher, not the embedding service).',
      type: 'not_implemented',
      code: 'not_implemented',
    );
  }

  /// `GET /v1/models` — the static persona listing (no auth, no body).
  Future<Response> _handleModels(Request request) async {
    final String body = const ModelsResponseRenderer().bodyJson(models: _models);
    return jsonResponse(body);
  }

  /// Any unmatched route → the OpenAI `404` envelope.
  Response _handleNotFound(Request request) {
    return _errorResponse(
      statusCode: 404,
      message: 'Unknown route: ${request.method} /${request.url.path}',
      type: 'invalid_request_error',
      code: 'not_found',
    );
  }

  // --- Error mapping -----------------------------------------------------

  /// Maps a thrown edge / dispatch failure to its OpenAI error envelope
  /// (proto spec § 8 / § 13.2): bearer auth / identity → `401`, rate-limit /
  /// quota → `429`, anchor → `400`, anything else (a dispatch / engine
  /// failure) → `500`.
  Response _errorFor(Object error) {
    if (error is BearerAuthFailure) {
      return _errorResponse(
        statusCode: bearerAuthHttpStatus,
        message: error.message,
        type: 'invalid_request_error',
        code: 'invalid_api_key',
      );
    }
    if (error is IdentityResolutionException) {
      return _errorResponse(
        statusCode: bearerAuthHttpStatus,
        message: error.toString(),
        type: 'invalid_request_error',
        code: 'identity_unresolved',
      );
    }
    if (error is RateLimitExceeded) {
      return _errorResponse(
        statusCode: rateLimitHttpStatus,
        message: error.toString(),
        type: 'rate_limit_exceeded',
        code: 'rate_limit_exceeded',
      );
    }
    if (error is DailyQuotaExceeded) {
      return _errorResponse(
        statusCode: quotaHttpStatus,
        message: error.toString(),
        type: 'insufficient_quota',
        code: 'insufficient_quota',
      );
    }
    if (error is AnchorPreCheckRejected) {
      return _errorResponse(
        statusCode: anchorPreCheckHttpStatus,
        message: error.toString(),
        type: 'invalid_request_error',
        code: 'content_screened',
      );
    }
    return _errorResponse(
      statusCode: 500,
      message: 'The request could not be processed: $error',
      type: 'server_error',
      code: 'dispatch_failed',
    );
  }

  /// Builds an OpenAI error-envelope response:
  /// `{ "error": { "message", "type", "param", "code" } }`.
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
    return jsonResponse(jsonEncode(body), status: statusCode);
  }
}

/// An [SseSink] that records every written frame instead of pushing it onto a
/// live socket (E.45).
///
/// `AccessAssembler.admitOpenAi` always binds an SSE delivery (E.37); for the
/// buffered-then-replayed edge (Q-E.45.2) the frames are captured here and
/// rendered after `admitOpenAi` returns. Never disconnected (there is no live
/// client to drop), so delivery runs to its natural `[DONE]`.
class _CapturingSseSink implements SseSink {
  /// The frames written by the SSE delivery, in order, including the terminal
  /// `data: [DONE]\n\n`.
  final List<String> frames = <String>[];
  bool _closed = false;

  @override
  void write(String frame) => frames.add(frame);

  @override
  Future<void> close() async => _closed = true;

  @override
  bool get isClosed => _closed;

  @override
  bool get isDisconnected => false;
}
