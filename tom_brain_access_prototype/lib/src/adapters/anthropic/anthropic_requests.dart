// Anthropic Messages inbound request parsing (plan item #28).
//
// What this file owns:
//
//   * `AnthropicParseError` — the typed parse failure. Anthropic's wire error
//     is `{"type":"error","error":{"type":"invalid_request_error","message":
//     <message>}}`, so only [message] reaches the client; the [code] /
//     [param] are internal diagnostics that (a) satisfy the shared
//     `OpenAiParseErrorFactory` so this parser reuses the OpenAI field
//     readers, and (b) let tests assert the precise failure.
//   * `AnthropicRequest` — the wire-level DTO the single `POST /v1/messages`
//     endpoint decodes to, reduced to the three fields the prototype consumes
//     (prompt text, `model` persona id, `stream` flag). Unlike Ollama there
//     is no shape discriminator: one endpoint, one content carrier.
//   * `AnthropicRequest.parse` — the pure decode-and-validate entry point. It
//     never throws on bad input and never touches the network.
//
// Three Anthropic wire facts this parser encodes:
//
//   1. `stream` defaults to **false** when absent (like OpenAI, unlike
//      Ollama's true) — an Anthropic SDK opts into streaming explicitly.
//   2. Message content is a bare string OR the OpenAI-shaped content-part
//      array (`[{type:"text",text:"…"}]`); the reduction is therefore
//      `lastUserText`, shared with the OpenAI parser (the two dialects carry
//      the identical content shape).
//   3. `max_tokens` and `system` are tolerated and ignored — the prototype
//      cognition owns answer length and the system prompt, so these wire
//      knobs never reach the DTO and are not validation targets.
//
// Scope discipline (mirrors the OpenAI / Ollama parsers): this is *parsing
// only*. It derives the prompt, the model id, and the stream flag, and stops.
// It does NOT resolve a persona (the adapter does, via `OpenAiPersonaMapping`),
// assemble an `Access`, render a response, or reach the dispatcher. The
// `model` id stays on the DTO — deliberately not folded into the
// channel-agnostic `InboundRequest`, which has no persona concept.

import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../openai_http_sse/openai_request_fields.dart';

/// A decoded JSON object — the shape `jsonDecode` produces for an object body.
typedef _Json = Map<String, Object?>;

/// A typed Anthropic Messages request-parsing failure.
///
/// Only [message] reaches the wire — Anthropic renders it inside the nested
/// `{"type":"error","error":{"type":"invalid_request_error","message":...}}`
/// envelope; the [code] and [param] are internal diagnostics. The default
/// constructor matches [OpenAiParseErrorFactory] so the shared field readers
/// ([requireJsonObject] / [optionalStringField] / [optionalBoolField]) build
/// it directly.
final class AnthropicParseError {
  /// Human-readable explanation, rendered as Anthropic's `error.message`.
  final String message;

  /// Stable machine-readable slug (`invalid_body`, `missing_messages`,
  /// `invalid_messages`, `no_user_message`, `invalid_model`,
  /// `invalid_stream`). Internal — not on the wire.
  final String code;

  /// The offending request parameter (`messages`, `model`, `stream`), or
  /// `null` for a body-level failure. Internal — not on the wire.
  final String? param;

  /// Builds a parse error.
  const AnthropicParseError({
    required this.message,
    required this.code,
    this.param,
  });

  @override
  bool operator ==(Object other) =>
      other is AnthropicParseError &&
      other.message == message &&
      other.code == code &&
      other.param == param;

  @override
  int get hashCode => Object.hash(message, code, param);

  @override
  String toString() =>
      'AnthropicParseError(code: $code, param: $param, message: $message)';
}

/// The decoded `POST /v1/messages` request, reduced to the three fields the
/// prototype consumes.
///
/// Immutable value object produced by [parse]. The adapter routes [model] to
/// `OpenAiPersonaMapping` (the shared persona vocabulary) and uses
/// [toInboundRequest] to produce the dispatcher-facing [InboundRequest].
final class AnthropicRequest {
  /// The prompt text — the last `user` message's content. Always non-empty: a
  /// request with no usable prompt is a parse failure, not an empty prompt.
  final String prompt;

  /// The raw `model` string, used as a persona id. `null` when the request
  /// omitted `model`; the persona mapping then falls back to the default
  /// assistant persona (AC-5). Kept on the DTO — not folded into
  /// [InboundRequest] — because the persona is a separate `Access` field.
  final String? model;

  /// Whether the client asked for a streamed (SSE) response. Defaults to
  /// **false** for Anthropic (like OpenAI, unlike Ollama). Drives the
  /// SSE-vs-JSON render path and feeds [InboundRequest.streaming].
  final bool stream;

  /// Builds the DTO directly. Callers normally use [parse]; this is exposed
  /// for tests and for any adapter that constructs the shape itself.
  const AnthropicRequest({
    required this.prompt,
    required this.model,
    required this.stream,
  });

  /// Projects this wire request onto the channel-agnostic [InboundRequest]
  /// the dispatcher consumes: [prompt] → `text`, [stream] → `streaming`. The
  /// [model] is intentionally not carried here — it becomes a `Persona` at
  /// the adapter and rides the `Access` as a sibling of the envelope.
  ///
  /// [conversationId] and [messageId] are optional channel-identity values
  /// the adapter fills when it has them; the Anthropic HTTP wire carries
  /// neither natively, so they default to `null`.
  InboundRequest toInboundRequest({
    String? conversationId,
    String? messageId,
  }) =>
      InboundRequest(
        text: prompt,
        conversationId: conversationId,
        messageId: messageId,
        streaming: stream,
      );

  /// Decodes and validates a `POST /v1/messages` body.
  ///
  /// The prompt is the last `user` message's content (string or content-part
  /// array). Returns `Ok(AnthropicRequest)` on success, or
  /// `Err(AnthropicParseError)` for a non-object body, a missing / non-array /
  /// empty `messages`, no usable user message, or a non-string `model` /
  /// non-bool `stream`. `max_tokens` and `system` are ignored.
  static Result<AnthropicRequest, AnthropicParseError> parse(Object? body) {
    final _Json json;
    switch (requireJsonObject(body, AnthropicParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        json = value;
    }

    final Object? rawMessages = json['messages'];
    if (rawMessages == null) {
      return const Err(AnthropicParseError(
        message: "Missing required parameter: 'messages'.",
        code: 'missing_messages',
        param: 'messages',
      ));
    }
    if (rawMessages is! List || rawMessages.isEmpty) {
      return const Err(AnthropicParseError(
        message: "'messages' must be a non-empty array.",
        code: 'invalid_messages',
        param: 'messages',
      ));
    }

    final String? prompt = lastUserText(rawMessages);
    if (prompt == null) {
      return const Err(AnthropicParseError(
        message: "'messages' must contain a user message with text content.",
        code: 'no_user_message',
        param: 'messages',
      ));
    }

    final String? model;
    switch (optionalStringField(json, 'model', AnthropicParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        model = value;
    }

    final bool? stream;
    switch (optionalBoolField(json, 'stream', AnthropicParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        stream = value;
    }

    return Ok(AnthropicRequest(
      prompt: prompt,
      model: model,
      stream: stream ?? false,
    ));
  }
}
