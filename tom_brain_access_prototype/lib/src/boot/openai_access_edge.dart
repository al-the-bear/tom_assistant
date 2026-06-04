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
// ── How the two response paths differ (streaming vs buffered) ────────
//
// `AccessAssembler.admitOpenAi` always binds an `SseDeliveryBinding` (E.37)
// and `await`s `dispatcher.accept`, so the answer is fully delivered into the
// sink by the time `admitOpenAi` returns. The edge-security gates (auth →
// identity → rate-limit → quota → anchor) all run *before* the first
// `OutboundChunk` is delivered and throw on rejection, so a rejection always
// fires before any frame is written. The edge exploits exactly that ordering:
//
//   * A *streaming* request (`stream: true`, P1.3 #9) gets true per-token
//     latency. The edge writes into a live `StreamControllerSseSink` and
//     returns its `body` stream as the `200 text/event-stream` response —
//     but only once it has *committed* to the `200`. It commits by racing two
//     outcomes: the first frame written to the sink (gates passed, delivery
//     started → `200` stream) against `admitOpenAi` throwing (a gate / pre-
//     delivery dispatch failure → the matching `4xx`/`500` envelope). Because
//     a gate rejection always precedes the first frame, the status is still
//     correct *before* any byte of the `200` body is on the wire. A failure
//     *after* the first frame is a mid-run failure: the `200` is already
//     committed, so the edge can only terminate the wire, not change status.
//
//   * A *non-streaming* request still buffers: it captures every frame into a
//     `_CapturingSseSink` and reconstructs the one `chat.completion` body from
//     them (Q-E.45.3), because the JSON shape needs the whole answer at once.

import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../adapters/openai_http_sse/chat_completion_json.dart';
import '../adapters/openai_http_sse/chat_completion_request.dart';
import '../adapters/openai_http_sse/embeddings_request.dart';
import '../adapters/openai_http_sse/embeddings_response.dart';
import '../adapters/openai_http_sse/models_response.dart';
import '../adapters/openai_http_sse/openai_http_sse_adapter.dart'
    show EmbeddingSource, OpenAiHttpSseAdapter;
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
/// /v1/embeddings` is an auth-gated substrate passthrough (Q-E.51.1): it
/// bearer-auth-gates the request through the assembler's auth gate (the same
/// gate the chat route runs) and then embeds the inputs through the injected
/// [EmbeddingSource], rendering the OpenAI list body. Embeddings are a
/// passthrough, not a cognition (proto spec § 5.6), so the route runs auth and
/// identity but *not* rate-limit / quota / anchor (Q-E.2.2 reserves that
/// mediation) and never touches the dispatcher. With no [EmbeddingSource]
/// wired (the CLI default), the route answers `501` — the same no-source
/// discipline the format adapter uses. Any other route is the OpenAI `404`
/// envelope.
class OpenAiAccessEdge {
  /// The base path every route hangs under. Defaults to the adapter's `/v1`.
  final String basePath;

  /// SSE media type for the streaming response.
  static const String _eventStreamContentType =
      'text/event-stream; charset=utf-8';

  final AccessAssembler _assembler;
  final List<String> _models;

  /// The injected embeddings passthrough source, or `null` when no substrate
  /// embedding service is wired (the CLI default). A well-formed, authenticated
  /// embeddings request with no source answers `501`. Keeping this a function —
  /// not a `tom_brain_substrate` type — is what keeps the access edge free of a
  /// substrate dependency (Plan E.7).
  final EmbeddingSource? _embeddingSource;

  /// Builds the edge over the booted [assembler].
  ///
  /// [basePath] defaults to [OpenAiHttpSseAdapter.basePath] (`/v1`); a config
  /// may override it. [models] is the persona-as-model vocabulary the
  /// `/v1/models` route lists; it defaults to
  /// [OpenAiPersonaMapping.knownModels]. [embeddingSource] is the passthrough
  /// seam to substrate's `EmbeddingService` (proto spec § 5.6, Q-E.51.1); when
  /// omitted (the CLI default) the auth-gated `/v1/embeddings` route answers
  /// `501`, and boot supplies the real substrate-backed producer.
  OpenAiAccessEdge({
    required AccessAssembler assembler,
    String? basePath,
    List<String>? models,
    EmbeddingSource? embeddingSource,
  })  : _assembler = assembler,
        basePath = basePath ?? OpenAiHttpSseAdapter.basePath,
        _models = models ?? OpenAiPersonaMapping.knownModels,
        _embeddingSource = embeddingSource;

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
  /// and drives [AccessAssembler.admitOpenAi]. A streaming request
  /// (`stream: true`) streams the answer live as SSE; a non-streaming request
  /// captures the frames and reconstructs the one `chat.completion` body. A
  /// failure at any edge gate (or in pre-delivery dispatch) is mapped to the
  /// matching OpenAI error envelope before any `200` byte is sent.
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

  /// Drives the admission pipeline and renders the answer for [request].
  ///
  /// A streaming request takes the live SSE path ([_admitStreaming]); a
  /// non-streaming request takes the buffered path ([_admitBuffered]).
  Future<Response> _admitAndRespond(
    String bearerToken,
    ChatCompletionRequest request,
  ) {
    return request.stream
        ? _admitStreaming(bearerToken, request)
        : _admitBuffered(bearerToken, request);
  }

  /// Streams the answer live as SSE, emitting real per-token frames (P1.3 #9).
  ///
  /// The edge cannot send a `200` body until the edge-security gates have
  /// passed, because a rejected gate must map onto its `4xx` envelope before
  /// any byte of a success body is on the wire. The gates all run *before* the
  /// first [OutboundChunk] is delivered, so the edge races two outcomes: the
  /// first frame written to the live sink (gates passed, delivery started →
  /// commit to the `200` stream) against [AccessAssembler.admitOpenAi] throwing
  /// (a gate / pre-delivery dispatch failure → the error envelope). Whichever
  /// resolves first decides the status. A throw *after* the first frame is a
  /// mid-run failure: the `200` is already committed, so the edge only
  /// terminates the wire (the half-written stream) rather than changing status.
  Future<Response> _admitStreaming(
    String bearerToken,
    ChatCompletionRequest request,
  ) async {
    // Completes when delivery has begun (first frame), or with the gate error
    // when admission throws before any frame — the status-decision race.
    final Completer<void> committed = Completer<void>();
    final StreamControllerSseSink sink = StreamControllerSseSink(
      onFirstFrame: () {
        if (!committed.isCompleted) committed.complete();
      },
    );
    final InboundRequest envelope = request.toInboundRequest();

    // Run admission concurrently with the race. It is not awaited here: the
    // edge returns as soon as the status is decided and the run keeps streaming
    // into `sink` behind the already-returned `body`.
    unawaited(
      _assembler
          .admitOpenAi(
        bearerToken: bearerToken,
        modelId: request.model,
        envelope: envelope,
        sink: sink,
      )
          .then(
        (_) {
          // Delivery finished. A successful run always writes at least the
          // terminal chunk, so the race is normally already won by the first
          // frame; release it here only to cover a run that produced none.
          if (!committed.isCompleted) committed.complete();
        },
        onError: (Object error, StackTrace _) {
          if (!committed.isCompleted) {
            // Failure before any frame → a gate / pre-delivery dispatch
            // rejection: lose the race so the edge sends the error envelope.
            committed.completeError(error);
          } else {
            // Failure after the `200` began: the status is already on the wire
            // and cannot change. Terminate the half-written stream so the
            // client is not left hanging on an open, never-closed wire.
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

    // Gates passed and delivery began: commit to the live SSE stream. The
    // `buffer_output: false` context disables shelf's response buffering so
    // each frame flushes to the socket as it is written (true first-chunk
    // latency); frames written before shelf subscribes are buffered on the
    // controller and flushed on subscription, so none are lost.
    return Response.ok(
      sink.body,
      headers: <String, String>{
        'content-type': _eventStreamContentType,
        'cache-control': 'no-cache',
      },
      context: const <String, Object>{'shelf.io.buffer_output': false},
    );
  }

  /// Buffers the captured frames and reconstructs one `chat.completion` body
  /// (the non-streaming path, Q-E.45.3).
  Future<Response> _admitBuffered(
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

  /// `POST /v1/embeddings` — the auth-gated substrate passthrough (Q-E.51.1).
  ///
  /// Embeddings are a passthrough, not a cognition (proto spec § 5.6), so the
  /// route does not drive the dispatcher. It still runs the assembler's auth
  /// gate ([AccessAssembler.authenticateOpenAi]) — the live edge has no
  /// unauthenticated surface — but, being a passthrough, it runs *no*
  /// rate-limit / quota / anchor mediation (Q-E.2.2 reserves that). Flow:
  ///
  ///   1. Lift the bearer token (a missing / malformed header is a `401`).
  ///   2. Authenticate + resolve identity through the assembler (`401` on a
  ///      rejected credential or an unresolved identity).
  ///   3. Parse the body into an [EmbeddingsRequest] (`400` on a malformed
  ///      body or a bad parameter).
  ///   4. With no [EmbeddingSource] wired (the CLI default) answer `501`;
  ///      otherwise embed the inputs through the source and render the OpenAI
  ///      list body.
  Future<Response> _handleEmbeddings(Request request) async {
    // ── 1. Bearer credential (E.28). ──
    final String bearerToken;
    try {
      bearerToken = parseBearerHeader(
        request.headers[authorizationHeaderName],
      );
    } on BearerAuthFailure catch (failure) {
      return _errorFor(failure);
    }

    // ── 2. Auth gate: authenticate + resolve identity (no cognition gates). ──
    try {
      _assembler.authenticateOpenAi(bearerToken);
    } catch (error) {
      return _errorFor(error);
    }

    // ── 3. Parse the OpenAI body (same DTO as the format adapter). ──
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

    return EmbeddingsRequest.parse(json).fold(
      ok: _respondToEmbeddings,
      err: (EmbeddingsParseError error) async => _errorResponse(
        statusCode: 400,
        message: error.message,
        type: 'invalid_request_error',
        code: error.code,
        param: error.param,
      ),
    );
  }

  /// Renders the response for an authenticated, successfully-parsed embeddings
  /// request.
  ///
  /// With no [EmbeddingSource] wired (the CLI default) the route answers `501`
  /// — the same no-source discipline the format adapter uses. Otherwise the
  /// inputs are embedded through the injected source and rendered into the
  /// OpenAI list body; the response `model` is the substrate embedding model's
  /// actual identity (from the batch), not the request's informational `model`
  /// string (proto spec § 5.6).
  Future<Response> _respondToEmbeddings(EmbeddingsRequest request) async {
    final EmbeddingSource? embeddingSource = _embeddingSource;
    if (embeddingSource == null) {
      return _errorResponse(
        statusCode: 501,
        message: 'The embeddings passthrough has no embedding service wired '
            '(the source is supplied at boot).',
        type: 'not_implemented',
        code: 'not_implemented',
      );
    }
    final EmbeddingBatch batch = await embeddingSource(request.inputs);
    final String body = const EmbeddingsResponseRenderer().bodyJson(
      inputs: request.inputs,
      batch: batch,
    );
    return jsonResponse(body);
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
/// non-streaming request the frames are captured here and reconstructed into
/// one `chat.completion` body after `admitOpenAi` returns (Q-E.45.3). A
/// streaming request uses the live [StreamControllerSseSink] instead (P1.3 #9).
/// Never disconnected (there is no live client to drop), so delivery runs to
/// its natural `[DONE]`.
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
