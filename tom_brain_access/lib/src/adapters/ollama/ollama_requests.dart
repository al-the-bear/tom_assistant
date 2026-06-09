// Ollama inbound request parsing (plan item #27).
//
// What this file owns:
//
//   * `OllamaApiShape` — the two Ollama endpoints (`/api/chat`,
//     `/api/generate`) as a discriminator. It carries the route path and the
//     per-shape *content carrier*: chat puts answer text under
//     `message.content`, generate puts it under `response`. Both the request
//     parser (to tag the DTO) and the NDJSON / JSON renderers (to place the
//     answer text) read it, so the chat-vs-generate difference lives in one
//     enum rather than being branched in three files.
//   * `OllamaParseError` — the typed parse failure. Ollama's wire error is
//     only `{"error": <message>}`, so only [message] reaches the client; the
//     [code] / [param] are internal diagnostics that (a) satisfy the shared
//     `OpenAiParseErrorFactory` so this parser can reuse the OpenAI field
//     readers, and (b) let tests assert the precise failure.
//   * `OllamaRequest` — the wire-level DTO both endpoints decode to, reduced
//     to the three fields the prototype consumes (prompt text, `model`
//     persona id, `stream` flag) plus its [shape].
//   * `OllamaRequest.parseChat` / `parseGenerate` — the two pure
//     decode-and-validate entry points. They never throw on bad input and
//     never touch the network.
//
// Two Ollama wire facts this parser encodes, distinct from the OpenAI parser:
//
//   1. `stream` defaults to **true** when absent — Ollama streams by default
//      (`ollama run` expects NDJSON), where OpenAI defaults to non-streaming.
//   2. Message content is a plain string — Ollama has no OpenAI content-part
//      array — so a non-string `content` contributes no prompt text.
//
// Scope discipline (mirrors the OpenAI parser, E.12): this is *parsing only*.
// It derives the prompt, the model id, the stream flag, and the shape, and
// stops. It does NOT resolve a persona (the adapter does, via
// `OpenAiPersonaMapping`), assemble an `Access`, render a response, or reach
// the dispatcher. The `model` id stays on the DTO — it is deliberately not
// folded into the channel-agnostic `InboundRequest`, which has no persona
// concept.

import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../openai_http_sse/openai_request_fields.dart';

/// A decoded JSON object — the shape `jsonDecode` produces for an object body
/// and for each message entry.
typedef _Json = Map<String, Object?>;

/// The two Ollama request endpoints, and the content carrier each uses for
/// the answer text on the wire.
///
/// `/api/chat` carries answer text as a chat message
/// (`message: {role: assistant, content: <text>}`); `/api/generate` carries
/// it as a bare `response: <text>` field. [contentFields] is the single place
/// that distinction is expressed; the NDJSON ([OllamaNdjsonRenderer]) and JSON
/// ([OllamaJsonRenderer]) renderers spread it into every chunk / body.
enum OllamaApiShape {
  /// `POST /api/chat`.
  chat('/api/chat'),

  /// `POST /api/generate`.
  generate('/api/generate');

  const OllamaApiShape(this.path);

  /// The Ollama route path this shape is served on.
  final String path;

  /// The content-carrier fields for a chunk / body conveying [text].
  ///
  /// Chat wraps it in an assistant `message`; generate emits a bare
  /// `response`. An empty [text] still yields the carrier (an empty-content
  /// message / an empty `response`), which is exactly the shape of the
  /// terminal `done: true` line.
  Map<String, Object?> contentFields(String text) => switch (this) {
        OllamaApiShape.chat => <String, Object?>{
            'message': <String, Object?>{
              'role': 'assistant',
              'content': text,
            },
          },
        OllamaApiShape.generate => <String, Object?>{'response': text},
      };
}

/// A typed Ollama request-parsing failure.
///
/// Only [message] reaches the wire (Ollama renders `{"error": message}`); the
/// [code] and [param] are internal diagnostics. The default constructor
/// matches [OpenAiParseErrorFactory] so the shared field readers
/// ([requireJsonObject] / [optionalStringField] / [optionalBoolField]) build
/// it directly.
final class OllamaParseError {
  /// Human-readable explanation, rendered as Ollama's `error` string.
  final String message;

  /// Stable machine-readable slug (`invalid_body`, `missing_messages`,
  /// `invalid_messages`, `no_user_message`, `missing_prompt`,
  /// `invalid_prompt`, `invalid_model`, `invalid_stream`). Internal — not on
  /// the wire.
  final String code;

  /// The offending request parameter (`messages`, `prompt`, `model`,
  /// `stream`), or `null` for a body-level failure. Internal — not on the
  /// wire.
  final String? param;

  /// Builds a parse error.
  const OllamaParseError({
    required this.message,
    required this.code,
    this.param,
  });

  @override
  bool operator ==(Object other) =>
      other is OllamaParseError &&
      other.message == message &&
      other.code == code &&
      other.param == param;

  @override
  int get hashCode => Object.hash(message, code, param);

  @override
  String toString() =>
      'OllamaParseError(code: $code, param: $param, message: $message)';
}

/// The decoded Ollama request, reduced to the three fields the prototype
/// consumes plus its [shape].
///
/// Immutable value object produced by [parseChat] / [parseGenerate]. The
/// adapter routes [model] to `OpenAiPersonaMapping` (the shared persona
/// vocabulary) and uses [toInboundRequest] to produce the dispatcher-facing
/// [InboundRequest].
final class OllamaRequest {
  /// The prompt text — the last `user` message's content (`/api/chat`) or the
  /// `prompt` field (`/api/generate`). Usually non-empty, but **empty** for a
  /// `/api/chat` client tool-loop follow-up: a request whose conversation ends
  /// on a `tool` result with no new user text carries an empty [prompt] and a
  /// populated [toolResults]. A request with neither a user message nor a tool
  /// result is a parse failure, not an empty prompt.
  final String prompt;

  /// The raw `model` string, used as a persona id. `null` when the request
  /// omitted `model`; the persona mapping then falls back to the default
  /// assistant persona (AC-5). Kept on the DTO — not folded into
  /// [InboundRequest] — because the persona is a separate `Access` field.
  final String? model;

  /// Whether the client asked for a streamed (NDJSON) response. Defaults to
  /// **true** for Ollama (unlike OpenAI's `false`). Drives the
  /// NDJSON-vs-JSON render path and feeds [InboundRequest.streaming].
  final bool stream;

  /// Which endpoint produced this request — selects the content carrier the
  /// renderers use.
  final OllamaApiShape shape;

  /// The preceding `messages[]` turns (everything before the live user
  /// message, excluding the `tool` results), in wire order. Empty for a
  /// single-message request and for every `/api/generate` request. Extension G
  /// (hub § 22.1).
  final List<PriorTurn> priorTurns;

  /// The client-executed `role: 'tool'` results echoed back on a follow-up
  /// turn, keyed by `tool_call_id`. Empty unless the client is continuing a
  /// remote-tool round (`/api/chat` only). Extension G (hub § 22.8).
  final List<RemoteToolResult> toolResults;

  /// The client-declared top-level `tools[]` the brain may *propose* but never
  /// executes. Empty unless the client declared tools. Extension G
  /// (hub § 22.8).
  final List<RemoteToolDef> remoteTools;

  /// Builds the DTO directly. Callers normally use [parseChat] /
  /// [parseGenerate]; this is exposed for tests and for any adapter that
  /// constructs the shape itself. The three Extension-G lists default empty so
  /// a pre-Extension-G caller is unchanged.
  const OllamaRequest({
    required this.prompt,
    required this.model,
    required this.stream,
    required this.shape,
    this.priorTurns = const <PriorTurn>[],
    this.toolResults = const <RemoteToolResult>[],
    this.remoteTools = const <RemoteToolDef>[],
  });

  /// Projects this wire request onto the channel-agnostic [InboundRequest]
  /// the dispatcher consumes: [prompt] → `text`, [stream] → `streaming`. The
  /// [model] is intentionally not carried here — it becomes a `Persona` at
  /// the adapter and rides the `Access` as a sibling of the envelope.
  ///
  /// [conversationId] and [messageId] are optional channel-identity values
  /// the adapter fills when it has them; the Ollama HTTP wire carries neither
  /// natively, so they default to `null`. [sessionId] is the value the edge
  /// lifts from the `X-Tom-Session` request header (proto spec § 5.2); `null`
  /// when the client sent none.
  InboundRequest toInboundRequest({
    String? conversationId,
    String? messageId,
    String? sessionId,
  }) =>
      InboundRequest(
        text: prompt,
        conversationId: conversationId,
        messageId: messageId,
        streaming: stream,
        priorTurns: priorTurns,
        toolResults: toolResults,
        remoteTools: remoteTools,
        sessionId: sessionId,
      );

  /// Decodes and validates a `POST /api/chat` body.
  ///
  /// Ollama chat is OpenAI-shaped, so the live prompt is the last `user`
  /// message (after the last tool result), the preceding turns become
  /// [priorTurns], `role: 'tool'` entries become [toolResults], and the
  /// top-level `tools[]` become [remoteTools] — all via the shared OpenAI
  /// reducers. Returns `Ok(OllamaRequest)` (shape [OllamaApiShape.chat]) on
  /// success, or `Err(OllamaParseError)` for a non-object body, a missing /
  /// non-array / empty `messages`, a conversation with no user turn at all, or
  /// a non-string `model` / non-bool `stream`. A trailing tool result with no
  /// new user text is the valid client tool-loop follow-up (empty prompt,
  /// populated [toolResults]). A wrong-shape sub-entry is dropped and reported
  /// through [onMalformed] with [accessWireHistoryMalformed] (proto spec § 11).
  static Result<OllamaRequest, OllamaParseError> parseChat(
    Object? body, {
    void Function(String reason)? onMalformed,
  }) {
    final _Json json;
    switch (requireJsonObject(body, OllamaParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        json = value;
    }

    final Object? rawMessages = json['messages'];
    if (rawMessages == null) {
      return const Err(OllamaParseError(
        message: "Missing required parameter: 'messages'.",
        code: 'missing_messages',
        param: 'messages',
      ));
    }
    if (rawMessages is! List || rawMessages.isEmpty) {
      return const Err(OllamaParseError(
        message: "'messages' must be a non-empty array.",
        code: 'invalid_messages',
        param: 'messages',
      ));
    }

    final RequestFidelity fidelity =
        reduceOpenAiMessages(rawMessages, onMalformed: onMalformed);
    final List<RemoteToolDef> remoteTools =
        openAiShapeRemoteTools(json['tools'], onMalformed: onMalformed);

    // No live prompt AND no tool result → the conversation carries no user
    // turn at all. A trailing tool result with an empty prompt is the valid
    // client tool-loop follow-up.
    if (fidelity.prompt.isEmpty && fidelity.toolResults.isEmpty) {
      return const Err(OllamaParseError(
        message: "'messages' must contain a user message with text content.",
        code: 'no_user_message',
        param: 'messages',
      ));
    }

    return _withModelAndStream(
      json: json,
      prompt: fidelity.prompt,
      shape: OllamaApiShape.chat,
      priorTurns: fidelity.priorTurns,
      toolResults: fidelity.toolResults,
      remoteTools: remoteTools,
    );
  }

  /// Decodes and validates a `POST /api/generate` body.
  ///
  /// The prompt is the `prompt` string directly. Returns `Ok(OllamaRequest)`
  /// (shape [OllamaApiShape.generate]) on success, or `Err(OllamaParseError)`
  /// for a non-object body, a missing `prompt`, a non-string / blank
  /// `prompt`, or a non-string `model` / non-bool `stream`.
  ///
  /// `/api/generate` is single-shot: it carries no `messages[]` history and no
  /// `tools[]`, so the three Extension-G fidelity fields stay empty. The
  /// [onMalformed] parameter is accepted for signature parity with [parseChat]
  /// (so both satisfy the edge's parser function type) but is never invoked —
  /// there is no sub-entry to drop.
  static Result<OllamaRequest, OllamaParseError> parseGenerate(
    Object? body, {
    void Function(String reason)? onMalformed,
  }) {
    final _Json json;
    switch (requireJsonObject(body, OllamaParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        json = value;
    }

    final Object? rawPrompt = json['prompt'];
    if (rawPrompt == null) {
      return const Err(OllamaParseError(
        message: "Missing required parameter: 'prompt'.",
        code: 'missing_prompt',
        param: 'prompt',
      ));
    }
    if (rawPrompt is! String || rawPrompt.trim().isEmpty) {
      return const Err(OllamaParseError(
        message: "'prompt' must be a non-empty string.",
        code: 'invalid_prompt',
        param: 'prompt',
      ));
    }

    return _withModelAndStream(
      json: json,
      prompt: rawPrompt.trim(),
      shape: OllamaApiShape.generate,
    );
  }

  /// Reads the optional `model` / `stream` fields shared by both endpoints
  /// and assembles the [OllamaRequest]. `stream` defaults to **true** (the
  /// Ollama default) when absent. The three Extension-G fidelity lists default
  /// empty so [parseGenerate] (single-shot, no history) omits them.
  static Result<OllamaRequest, OllamaParseError> _withModelAndStream({
    required _Json json,
    required String prompt,
    required OllamaApiShape shape,
    List<PriorTurn> priorTurns = const <PriorTurn>[],
    List<RemoteToolResult> toolResults = const <RemoteToolResult>[],
    List<RemoteToolDef> remoteTools = const <RemoteToolDef>[],
  }) {
    final String? model;
    switch (optionalStringField(json, 'model', OllamaParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        model = value;
    }

    final bool? stream;
    switch (optionalBoolField(json, 'stream', OllamaParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        stream = value;
    }

    return Ok(OllamaRequest(
      prompt: prompt,
      model: model,
      stream: stream ?? true,
      shape: shape,
      priorTurns: priorTurns,
      toolResults: toolResults,
      remoteTools: remoteTools,
    ));
  }
}
