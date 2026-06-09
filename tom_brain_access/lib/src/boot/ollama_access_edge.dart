// OllamaAccessEdge — the live, auth-gated Ollama HTTP channel of the running
// access process (plan-2 #30; proto spec § 5 / § 8 / § 11).
//
// ── What this is, and how it differs from the Ollama format adapter ──
//
// The Ollama wire adapter (`adapters/ollama/`) owns the *format* surface:
// request parsing (`OllamaRequest`), the NDJSON / buffered-JSON renderers, and
// the bare `{"error": <msg>}` envelope, proven in isolation against an injected
// answer stream with no auth and no edge security.
//
// `OllamaAccessEdge` is the *running-process* surface: it drives the E.41
// `AccessAssembler`, so every request runs the full inbound flow — bearer auth →
// identity → rate-limit → quota → anchor → session → classify → delivery →
// `dispatcher.accept`. It owns a fresh router but speaks the *same* Ollama
// dialect (it reuses `OllamaRequest`, the NDJSON / JSON renderers, and the same
// bare-error envelope).
//
// ── How the two response paths differ (streaming vs buffered) ────────
//
// Ollama delivers over a `ChunkStreamDeliveryBinding`: the assembler forwards
// raw `OutboundChunk`s onto an `OutboundChunkSink`, and this edge's renderer
// drains the sink and renders the NDJSON / JSON dialect. The edge-security gates
// all run *before* the first `OutboundChunk` is delivered and throw on
// rejection, so a rejection always fires before any chunk is forwarded. The edge
// exploits exactly that ordering, mirroring `OpenAiAccessEdge`:
//
//   * A *streaming* request (the Ollama default — `stream` absent or `true`)
//     gets true per-token latency. The edge forwards chunks into a live
//     `StreamControllerChunkSink` and returns its `body` stream — rendered to
//     NDJSON — as the `200 application/x-ndjson` response, but only once it has
//     *committed* to the `200`. It commits by racing the first chunk forwarded
//     to the sink (gates passed → `200` stream) against `admitOllama` throwing
//     (a gate / pre-delivery dispatch failure → the bare-error envelope).
//
//   * A *non-streaming* request (`stream: false`) buffers: it captures every
//     forwarded chunk into a `_CapturingChunkSink` and renders the one buffered
//     JSON object from them, because the JSON shape needs the whole answer.

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/ollama/ollama_json.dart';
import '../adapters/ollama/ollama_ndjson.dart';
import '../adapters/ollama/ollama_requests.dart';
import '../adapters/openai_http_sse/persona_mapping.dart';
import '../delivery/chunk_stream_delivery.dart';
import '../edge_security/edge_security.dart';
import '../identity/identity_resolver.dart';
import 'access_assembler.dart';

/// The live, auth-gated Ollama HTTP channel (plan-2 #30).
///
/// Construct one per running process over the booted [AccessAssembler]; mount
/// [handler] on the live port. `POST /api/chat` and `POST /api/generate` each
/// run the full E.41 admission pipeline and render the answer in Ollama's
/// NDJSON (streaming) or buffered-JSON (non-streaming) dialect; any other route
/// is the Ollama bare-error `404`.
class OllamaAccessEdge {
  /// The base path both Ollama routes hang under. Defaults to `/api`.
  static const String defaultBasePath = '/api';

  /// The base path the routes mount under (`/api/chat`, `/api/generate`).
  final String basePath;

  final AccessAssembler _assembler;

  /// Builds the edge over the booted [assembler]. [basePath] defaults to
  /// [defaultBasePath] (`/api`); a config may override it.
  OllamaAccessEdge({
    required AccessAssembler assembler,
    String? basePath,
  })  : _assembler = assembler,
        basePath = basePath ?? defaultBasePath;

  late final Router _router = _buildRouter();

  /// The mountable shelf handler. `Router` is itself a [Handler].
  Handler get handler => _router.call;

  Router _buildRouter() {
    final Router router = Router(notFoundHandler: _handleNotFound);
    router.post('$basePath/chat', _handleChat);
    router.post('$basePath/generate', _handleGenerate);
    return router;
  }

  // --- Routes ------------------------------------------------------------

  /// `POST /api/chat` — the auth-gated chat surface (prompt is the last user
  /// message's content).
  Future<Response> _handleChat(Request request) =>
      _handle(request, OllamaRequest.parseChat);

  /// `POST /api/generate` — the auth-gated generate surface (prompt is the
  /// `prompt` field).
  Future<Response> _handleGenerate(Request request) =>
      _handle(request, OllamaRequest.parseGenerate);

  /// Lifts the bearer token, parses the body with [parse] (chat vs generate),
  /// and drives the admission pipeline.
  Future<Response> _handle(
    Request request,
    Result<OllamaRequest, OllamaParseError> Function(Object? body) parse,
  ) async {
    // ── 1. Bearer credential. A missing / malformed header is a 401 before we
    //    parse the body. ──
    final String bearerToken;
    try {
      bearerToken = parseBearerHeader(request.headers[authorizationHeaderName]);
    } on BearerAuthFailure catch (failure) {
      return _errorFor(failure);
    }

    // ── 2. Parse the Ollama body. ──
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

    // The session the client wants this request associated with (proto spec
    // § 5.2). `null` when the header is absent → routed to the default session.
    final String? sessionId = request.headers[tomSessionHeaderName];

    return parse(json).fold(
      ok: (OllamaRequest parsed) =>
          _admitAndRespond(bearerToken, parsed, sessionId),
      err: (OllamaParseError error) async =>
          _errorResponse(statusCode: 400, message: error.message),
    );
  }

  /// Drives the admission pipeline and renders the answer for [request].
  ///
  /// A streaming request takes the live NDJSON path ([_admitStreaming]); a
  /// non-streaming request takes the buffered JSON path ([_admitBuffered]).
  Future<Response> _admitAndRespond(
    String bearerToken,
    OllamaRequest request,
    String? sessionId,
  ) {
    return request.stream
        ? _admitStreaming(bearerToken, request, sessionId)
        : _admitBuffered(bearerToken, request, sessionId);
  }

  /// Streams the answer live as Ollama NDJSON (the default path).
  ///
  /// The edge cannot send a `200` body until the edge-security gates pass: a
  /// rejected gate must map onto its bare-error envelope before any byte of a
  /// success body is on the wire. The gates all run before the first
  /// [OutboundChunk] is forwarded, so the edge races the first chunk forwarded
  /// to the live sink (gates passed → `200` stream) against
  /// [AccessAssembler.admitOllama] throwing (a gate / pre-delivery dispatch
  /// failure → the error envelope). Whichever resolves first decides the status.
  Future<Response> _admitStreaming(
    String bearerToken,
    OllamaRequest request,
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
          .admitOllama(
        bearerToken: bearerToken,
        modelId: request.model,
        envelope: envelope,
        sink: sink,
      )
          .then(
        (_) {
          // Delivery finished — release the race if no chunk did.
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

    final OllamaNdjsonRenderer renderer = OllamaNdjsonRenderer.forModel(
      _resolvePersonaId(request.model),
      request.shape,
    );
    final Stream<List<int>> body =
        renderer.render(sink.body).transform(utf8.encoder);
    return Response.ok(
      body,
      headers: <String, String>{
        'content-type': OllamaNdjsonRenderer.contentType,
        'cache-control': 'no-cache',
      },
      context: const <String, Object>{'shelf.io.buffer_output': false},
    );
  }

  /// Buffers the forwarded chunks and renders one Ollama JSON object (the
  /// non-streaming path).
  Future<Response> _admitBuffered(
    String bearerToken,
    OllamaRequest request,
    String? sessionId,
  ) async {
    final _CapturingChunkSink sink = _CapturingChunkSink();
    final InboundRequest envelope = request.toInboundRequest(sessionId: sessionId);
    try {
      await _assembler.admitOllama(
        bearerToken: bearerToken,
        modelId: request.model,
        envelope: envelope,
        sink: sink,
      );
    } catch (error) {
      return _errorFor(error);
    }

    final OllamaJsonRenderer renderer = OllamaJsonRenderer.forModel(
      _resolvePersonaId(request.model),
      request.shape,
    );
    final String body = await renderer.render(Stream.fromIterable(sink.chunks));
    return Response.ok(
      body,
      headers: const <String, String>{
        'content-type': OllamaJsonRenderer.contentType,
      },
    );
  }

  /// Resolves [model] to its persona-as-model id — the id the renderers stamp
  /// into every line / body (the same resolution the assembler runs internally;
  /// an absent / unknown model normalises to `tom-assistant`, AC-5).
  String _resolvePersonaId(String? model) =>
      OpenAiPersonaMapping.resolve(model).personaId;

  /// Any unmatched route → the Ollama bare-error `404`.
  Response _handleNotFound(Request request) => _errorResponse(
        statusCode: 404,
        message: 'Unknown route: ${request.method} /${request.url.path}',
      );

  // --- Error mapping -----------------------------------------------------

  /// Maps a thrown edge / dispatch failure to its Ollama bare-error envelope:
  /// bearer auth / identity → `401`, rate-limit / quota → `429` (with
  /// `Retry-After`), anchor → `400`, anything else → `500`.
  Response _errorFor(Object error) {
    if (error is BearerAuthFailure) {
      return _errorResponse(
        statusCode: bearerAuthHttpStatus,
        message: error.message,
      );
    }
    if (error is IdentityResolutionException) {
      return _errorResponse(
        statusCode: bearerAuthHttpStatus,
        message: error.toString(),
      );
    }
    if (error is RateLimitExceeded) {
      return _errorResponse(
        statusCode: rateLimitHttpStatus,
        message: error.toString(),
        headers: _retryAfterHeader(error.retryAfter),
      );
    }
    if (error is DailyQuotaExceeded) {
      return _errorResponse(
        statusCode: quotaHttpStatus,
        message: error.toString(),
        headers: _retryAfterHeader(error.retryAfter),
      );
    }
    if (error is AnchorPreCheckRejected) {
      return _errorResponse(
        statusCode: anchorPreCheckHttpStatus,
        message: error.toString(),
      );
    }
    return _errorResponse(
      statusCode: 500,
      message: 'The request could not be processed: $error',
    );
  }

  /// Builds an Ollama bare-error envelope: `{"error": <message>}`.
  Response _errorResponse({
    required int statusCode,
    required String message,
    Map<String, String> headers = const <String, String>{},
  }) {
    return Response(
      statusCode,
      body: jsonEncode(<String, Object?>{'error': message}),
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
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
/// it onto a live stream (plan-2 #30).
///
/// `AccessAssembler.admitOllama` forwards raw chunks here; for the non-streaming
/// request the chunks are captured and rendered into one buffered JSON body
/// after `admitOllama` returns. A streaming request uses the live
/// [StreamControllerChunkSink] instead. Never disconnected (there is no live
/// client to drop), so delivery runs to its natural final chunk.
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
