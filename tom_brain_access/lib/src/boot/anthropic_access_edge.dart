// AnthropicAccessEdge — the live, auth-gated Anthropic Messages HTTP channel of
// the running access process (plan-2 #31; proto spec § 5 / § 8 / § 11).
//
// ── What this is, and how it differs from the Anthropic format adapter ──
//
// The Anthropic wire adapter (`adapters/anthropic/`) owns the *format* surface:
// request parsing (`AnthropicRequest`), the named-SSE / buffered-Message
// renderers, and the nested `{"type":"error","error":{...}}` envelope, proven
// in isolation against an injected answer stream with no auth and no edge
// security.
//
// `AnthropicAccessEdge` is the *running-process* surface: it drives the E.41
// `AccessAssembler`, so every `POST /v1/messages` runs the full inbound flow —
// auth → identity → rate-limit → quota → anchor → session → classify → delivery
// → `dispatcher.accept`. It owns a fresh router but speaks the *same* Anthropic
// dialect (it reuses `AnthropicRequest`, the SSE / JSON renderers, and the same
// nested error envelope).
//
// ── Credential header ────────────────────────────────────────────────
//
// Real Anthropic SDKs send the key in the `x-api-key` header (a raw token, no
// `Bearer` prefix), not `Authorization: Bearer`. The edge reads `x-api-key`
// first and falls back to a standard `Authorization: Bearer` header, so both an
// Anthropic SDK and a generic bearer client authenticate against the one shared
// `bearerTokenBindings` set.
//
// ── How the two response paths differ (streaming vs buffered) ────────
//
// Anthropic delivers over a `ChunkStreamDeliveryBinding`: the assembler forwards
// raw `OutboundChunk`s onto an `OutboundChunkSink`, and this edge's renderer
// drains the sink and renders the Anthropic dialect. The gates run before the
// first chunk is forwarded, so a rejection fires before any chunk; the edge
// exploits that ordering exactly as the OpenAI / Ollama edges do. Anthropic
// streams only on an explicit `stream: true` (default `false`), so an
// stream-absent request takes the buffered Message-JSON path.

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/anthropic/anthropic_json.dart';
import '../adapters/anthropic/anthropic_requests.dart';
import '../adapters/anthropic/anthropic_sse.dart';
import '../adapters/openai_http_sse/persona_mapping.dart';
import '../delivery/chunk_stream_delivery.dart';
import '../edge_security/edge_security.dart';
import '../identity/identity_resolver.dart';
import 'access_assembler.dart';

/// The live, auth-gated Anthropic Messages HTTP channel (plan-2 #31).
///
/// Construct one per running process over the booted [AccessAssembler]; mount
/// [handler] on the live port. `POST /v1/messages` runs the full E.41 admission
/// pipeline and renders the answer in Anthropic's named-SSE (streaming) or
/// buffered Message-JSON (non-streaming) dialect; any other route is the
/// Anthropic `not_found_error` `404`.
class AnthropicAccessEdge {
  /// The base path the Messages route hangs under. Defaults to `/v1`.
  static const String defaultBasePath = '/v1';

  /// The Anthropic SDK credential header (a raw token, no `Bearer` prefix).
  static const String apiKeyHeaderName = 'x-api-key';

  static const String _sseContentType = 'text/event-stream; charset=utf-8';
  static const String _jsonContentType = 'application/json; charset=utf-8';

  /// The base path the Messages route mounts under (`$basePath/messages`).
  final String basePath;

  final AccessAssembler _assembler;

  /// Builds the edge over the booted [assembler]. [basePath] defaults to
  /// [defaultBasePath] (`/v1`); a config may override it.
  AnthropicAccessEdge({
    required AccessAssembler assembler,
    String? basePath,
  })  : _assembler = assembler,
        basePath = basePath ?? defaultBasePath;

  late final Router _router = _buildRouter();

  /// The mountable shelf handler. `Router` is itself a [Handler].
  Handler get handler => _router.call;

  Router _buildRouter() {
    final Router router = Router(notFoundHandler: _handleNotFound);
    router.post('$basePath/messages', _handleMessages);
    return router;
  }

  // --- Routes ------------------------------------------------------------

  /// `POST /v1/messages` — the auth-gated Anthropic Messages surface.
  Future<Response> _handleMessages(Request request) async {
    // ── 1. Credential (x-api-key, then Authorization: Bearer). A missing /
    //    malformed credential is a 401 before we parse the body. ──
    final String bearerToken;
    try {
      bearerToken = _resolveCredential(request);
    } on BearerAuthFailure catch (failure) {
      return _errorFor(failure);
    }

    // ── 2. Parse the Anthropic body. ──
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

    // The session the client wants this request associated with (proto spec
    // § 5.2). `null` when the header is absent → routed to the default session.
    final String? sessionId = request.headers[tomSessionHeaderName];

    return AnthropicRequest.parse(json).fold(
      ok: (AnthropicRequest parsed) =>
          _admitAndRespond(bearerToken, parsed, sessionId),
      err: (AnthropicParseError error) async => _errorResponse(
        statusCode: 400,
        type: 'invalid_request_error',
        message: error.message,
      ),
    );
  }

  /// Reads the bearer credential from the `x-api-key` header (the Anthropic SDK
  /// shape — a raw token) or, failing that, a standard `Authorization: Bearer`
  /// header. Throws [BearerAuthFailure] when neither carries a token.
  String _resolveCredential(Request request) {
    final String? apiKey = request.headers[apiKeyHeaderName]?.trim();
    if (apiKey != null && apiKey.isNotEmpty) {
      return apiKey;
    }
    return parseBearerHeader(request.headers[authorizationHeaderName]);
  }

  /// Drives the admission pipeline and renders the answer for [request].
  ///
  /// A streaming request takes the live named-SSE path ([_admitStreaming]); a
  /// non-streaming request takes the buffered Message-JSON path
  /// ([_admitBuffered]).
  Future<Response> _admitAndRespond(
    String bearerToken,
    AnthropicRequest request,
    String? sessionId,
  ) {
    return request.stream
        ? _admitStreaming(bearerToken, request, sessionId)
        : _admitBuffered(bearerToken, request, sessionId);
  }

  /// Streams the answer live as the Anthropic named-SSE event sequence.
  ///
  /// The edge cannot send a `200` body until the gates pass: a rejected gate
  /// must map onto its error envelope before any byte of a success body is on
  /// the wire. The edge races the first chunk forwarded to the live sink (gates
  /// passed → `200` stream) against [AccessAssembler.admitAnthropic] throwing (a
  /// gate / pre-delivery dispatch failure → the error envelope).
  Future<Response> _admitStreaming(
    String bearerToken,
    AnthropicRequest request,
    String? sessionId,
  ) async {
    final Completer<void> committed = Completer<void>();
    final StreamControllerChunkSink sink = StreamControllerChunkSink(
      onFirstChunk: () {
        if (!committed.isCompleted) committed.complete();
      },
    );
    final InboundRequest envelope = request.toInboundRequest(sessionId: sessionId);

    unawaited(
      _assembler
          .admitAnthropic(
        bearerToken: bearerToken,
        modelId: request.model,
        envelope: envelope,
        sink: sink,
      )
          .then(
        (_) {
          if (!committed.isCompleted) committed.complete();
        },
        onError: (Object error, StackTrace _) {
          if (!committed.isCompleted) {
            committed.completeError(error);
          } else {
            unawaited(sink.close());
          }
        },
      ),
    );

    try {
      await committed.future;
    } catch (error) {
      return _errorFor(error);
    }

    final AnthropicSseRenderer renderer =
        AnthropicSseRenderer.forModel(_resolvePersonaId(request.model));
    final Stream<List<int>> body = renderer
        .render(prompt: request.prompt, chunks: sink.body)
        .transform(utf8.encoder);
    return Response.ok(
      body,
      headers: <String, String>{
        'content-type': _sseContentType,
        'cache-control': 'no-cache',
      },
      context: const <String, Object>{'shelf.io.buffer_output': false},
    );
  }

  /// Buffers the forwarded chunks and renders one Anthropic Message object (the
  /// non-streaming path, the Anthropic default).
  Future<Response> _admitBuffered(
    String bearerToken,
    AnthropicRequest request,
    String? sessionId,
  ) async {
    final _CapturingChunkSink sink = _CapturingChunkSink();
    final InboundRequest envelope = request.toInboundRequest(sessionId: sessionId);
    try {
      await _assembler.admitAnthropic(
        bearerToken: bearerToken,
        modelId: request.model,
        envelope: envelope,
        sink: sink,
      );
    } catch (error) {
      return _errorFor(error);
    }

    final AnthropicJsonRenderer renderer =
        AnthropicJsonRenderer.forModel(_resolvePersonaId(request.model));
    final String body = await renderer.render(
      prompt: request.prompt,
      chunks: Stream.fromIterable(sink.chunks),
    );
    return Response.ok(
      body,
      headers: const <String, String>{'content-type': _jsonContentType},
    );
  }

  /// Resolves [model] to its persona-as-model id — the id the renderers stamp
  /// into the Message envelope (the same resolution the assembler runs
  /// internally; an absent / unknown model normalises to `tom-assistant`, AC-5).
  String _resolvePersonaId(String? model) =>
      OpenAiPersonaMapping.resolve(model).personaId;

  /// Any unmatched route → the Anthropic `not_found_error` `404`.
  Response _handleNotFound(Request request) => _errorResponse(
        statusCode: 404,
        type: 'not_found_error',
        message: 'Unknown route: ${request.method} /${request.url.path}',
      );

  // --- Error mapping -----------------------------------------------------

  /// Maps a thrown edge / dispatch failure to its Anthropic error envelope:
  /// bearer auth / identity → `401` `authentication_error`, rate-limit / quota →
  /// `429` `rate_limit_error` (with `Retry-After`), anchor → `400`
  /// `invalid_request_error`, anything else → `500` `api_error`.
  Response _errorFor(Object error) {
    if (error is BearerAuthFailure) {
      return _errorResponse(
        statusCode: bearerAuthHttpStatus,
        type: 'authentication_error',
        message: error.message,
      );
    }
    if (error is IdentityResolutionException) {
      return _errorResponse(
        statusCode: bearerAuthHttpStatus,
        type: 'authentication_error',
        message: error.toString(),
      );
    }
    if (error is RateLimitExceeded) {
      return _errorResponse(
        statusCode: rateLimitHttpStatus,
        type: 'rate_limit_error',
        message: error.toString(),
        headers: _retryAfterHeader(error.retryAfter),
      );
    }
    if (error is DailyQuotaExceeded) {
      return _errorResponse(
        statusCode: quotaHttpStatus,
        type: 'rate_limit_error',
        message: error.toString(),
        headers: _retryAfterHeader(error.retryAfter),
      );
    }
    if (error is AnchorPreCheckRejected) {
      return _errorResponse(
        statusCode: anchorPreCheckHttpStatus,
        type: 'invalid_request_error',
        message: error.toString(),
      );
    }
    return _errorResponse(
      statusCode: 500,
      type: 'api_error',
      message: 'The request could not be processed: $error',
    );
  }

  /// Builds the Anthropic error envelope:
  /// `{"type":"error","error":{"type":<type>,"message":<message>}}`.
  Response _errorResponse({
    required int statusCode,
    required String type,
    required String message,
    Map<String, String> headers = const <String, String>{},
  }) {
    return Response(
      statusCode,
      body: jsonEncode(<String, Object?>{
        'type': 'error',
        'error': <String, Object?>{'type': type, 'message': message},
      }),
      headers: <String, String>{
        'content-type': _jsonContentType,
        ...headers,
      },
    );
  }

  /// The `Retry-After` header advertising the back-off until a retry can
  /// succeed. Whole seconds rounded *up* (a sub-second wait still advertises
  /// `1`).
  static Map<String, String> _retryAfterHeader(Duration retryAfter) {
    final int seconds = (retryAfter.inMilliseconds / 1000).ceil();
    return <String, String>{'retry-after': '${seconds < 1 ? 1 : seconds}'};
  }
}

/// An [OutboundChunkSink] that records every forwarded chunk instead of pushing
/// it onto a live stream (plan-2 #31).
///
/// `AccessAssembler.admitAnthropic` forwards raw chunks here; for the
/// non-streaming request the chunks are captured and rendered into one buffered
/// Message body after `admitAnthropic` returns. A streaming request uses the
/// live [StreamControllerChunkSink] instead. Never disconnected (there is no
/// live client to drop), so delivery runs to its natural final chunk.
class _CapturingChunkSink implements OutboundChunkSink {
  /// The chunks forwarded by the delivery path, in order.
  final List<OutboundChunk> chunks = <OutboundChunk>[];
  bool _closed = false;

  @override
  void add(OutboundChunk chunk) => chunks.add(chunk);

  @override
  Future<void> close() async => _closed = true;

  @override
  bool get isClosed => _closed;

  @override
  bool get isDisconnected => false;
}
