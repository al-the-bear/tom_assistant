// OpenAI `chat/completions` request parsing (E.12).
//
// What this file owns (Plan § Phase E, substep E.12; proto spec § 5.2):
//
//   * `ChatCompletionRequest` — the wire-level DTO produced by decoding the
//     `POST /v1/chat/completions` JSON body into the three fields the
//     prototype reads: the `messages` array (reduced to the prompt text),
//     the `model` string (a persona id), and the `stream` flag.
//   * `ChatCompletionParseError` — the typed parse failure, carrying the
//     pieces the OpenAI `400` error envelope needs (`message`, `param`,
//     `code`).
//   * `ChatCompletionRequest.parse(...)` — the pure decode-and-validate
//     step. Returns a `Result`; it never throws on bad input and never
//     touches the network.
//
// Scope discipline (Q-E.11.2 carried forward): E.12 is *parsing only*. This
// file derives the prompt text, the model id, and the stream flag and stops.
// It does NOT resolve a persona (E.15), assemble an `Access` (needs
// identity / session — E.24–E.27), generate a response (E.13 – E.14), or
// reach the dispatcher (boot, E.41+). The mapping the spec names —
// "prompt becomes `InboundRequest.text`; `stream` feeds
// `InboundRequest.streaming`" — is realised by [toInboundRequest]; the
// `model` id stays on the DTO for the adapter to hand to `PersonaResolver`
// at E.15 (it is deliberately NOT stuffed into the `InboundRequest`, which
// has no persona concept).

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'openai_request_fields.dart';

/// A decoded JSON object — the shape `jsonDecode` produces for an object
/// body and for each message / content-part entry. Aliased so the type
/// checks below read as intent (`body is! _Json`) rather than the verbose
/// `Map<String, Object?>`. Identical to [JsonObject]; kept as a file-local
/// name for the message/content-part reads that stay in this file.
typedef _Json = Map<String, Object?>;

/// A typed `chat/completions` request-parsing failure.
///
/// Maps one-to-one onto the OpenAI `400` error envelope:
/// `{ "error": { "message", "type": "invalid_request_error",
/// "param", "code" } }`. The adapter renders it; this type carries the
/// content.
final class ChatCompletionParseError {
  /// Human-readable explanation, suitable for the `error.message` field.
  final String message;

  /// The OpenAI `error.code` — a stable, machine-readable slug
  /// (`invalid_body`, `missing_messages`, `invalid_messages`,
  /// `no_user_message`, `invalid_model`, `invalid_stream`).
  final String code;

  /// The offending request parameter (`messages`, `model`, `stream`), or
  /// `null` for a body-level failure that no single parameter owns.
  final String? param;

  /// Builds a parse error.
  const ChatCompletionParseError({
    required this.message,
    required this.code,
    this.param,
  });

  @override
  bool operator ==(Object other) =>
      other is ChatCompletionParseError &&
      other.message == message &&
      other.code == code &&
      other.param == param;

  @override
  int get hashCode => Object.hash(message, code, param);

  @override
  String toString() =>
      'ChatCompletionParseError(code: $code, param: $param, '
      'message: $message)';
}

/// The decoded `POST /v1/chat/completions` request, reduced to the three
/// fields the prototype consumes.
///
/// Immutable value object produced by [ChatCompletionRequest.parse]. The
/// adapter routes [model] to `PersonaResolver` (E.15) and uses
/// [toInboundRequest] to produce the dispatcher-facing [InboundRequest].
final class ChatCompletionRequest {
  /// The prompt text — the content of the *last* `user` message in the
  /// `messages` array (proto spec § 5.2). Always non-empty: a request whose
  /// last user message has no usable text is a parse failure, not an empty
  /// prompt.
  final String prompt;

  /// The raw `model` string, used as a persona id by `PersonaResolver`
  /// (E.15). `null` when the request omitted `model`; the persona resolver
  /// then falls back to `Persona.assistant()` (AC-5). Kept on the DTO — not
  /// folded into [InboundRequest] — because the persona is a separate
  /// `Access` field with no place in the inbound envelope.
  final String? model;

  /// Whether the client asked for a streamed (SSE) response. Drives the
  /// SSE-vs-JSON render path (E.13 / E.14) and feeds
  /// [InboundRequest.streaming]. Defaults to `false`.
  final bool stream;

  /// Builds the DTO directly. Callers normally use [parse]; this is exposed
  /// for tests and for any future adapter that constructs the shape itself.
  const ChatCompletionRequest({
    required this.prompt,
    required this.model,
    required this.stream,
  });

  /// Projects this wire request onto the channel-agnostic [InboundRequest]
  /// the dispatcher consumes (proto spec § 5.2): [prompt] → `text`,
  /// [stream] → `streaming`. The [model] is intentionally not carried here —
  /// it becomes a `Persona` via `PersonaResolver` (E.15) and rides the
  /// `Access` as a sibling of the envelope.
  ///
  /// [conversationId] and [messageId] are optional channel-identity values
  /// the adapter fills when it has them; for OpenAI HTTP the wire carries
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

  /// Decodes and validates an already-JSON-decoded request [body].
  ///
  /// [body] is the result of `jsonDecode` on the request payload, typed as
  /// `Object?` so a non-object body (a JSON array, number, or `null`) is a
  /// reported failure rather than a thrown cast. Returns:
  ///
  ///   * `Ok(ChatCompletionRequest)` when `messages` yields a usable last
  ///     user message and `model` / `stream` (if present) have the right
  ///     types;
  ///   * `Err(ChatCompletionParseError)` otherwise.
  ///
  /// This method is pure: no I/O, no throwing on malformed input.
  static Result<ChatCompletionRequest, ChatCompletionParseError> parse(
    Object? body,
  ) {
    final _Json json;
    switch (requireJsonObject(body, ChatCompletionParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        json = value;
    }

    final Object? rawMessages = json['messages'];
    if (rawMessages == null) {
      return const Err(ChatCompletionParseError(
        message: "Missing required parameter: 'messages'.",
        code: 'missing_messages',
        param: 'messages',
      ));
    }
    if (rawMessages is! List || rawMessages.isEmpty) {
      return const Err(ChatCompletionParseError(
        message: "'messages' must be a non-empty array.",
        code: 'invalid_messages',
        param: 'messages',
      ));
    }

    final String? prompt = _lastUserPrompt(rawMessages);
    if (prompt == null) {
      return const Err(ChatCompletionParseError(
        message: "'messages' must contain a user message with text content.",
        code: 'no_user_message',
        param: 'messages',
      ));
    }

    final String? model;
    switch (optionalStringField(json, 'model', ChatCompletionParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        model = value;
    }

    final bool? stream;
    switch (optionalBoolField(json, 'stream', ChatCompletionParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        stream = value;
    }

    return Ok(ChatCompletionRequest(
      prompt: prompt,
      model: model,
      stream: stream ?? false,
    ));
  }

  /// Returns the trimmed text content of the last `user` message in
  /// [messages], or `null` if there is no user message with usable text.
  ///
  /// Content may be a plain string (the common case) or the OpenAI
  /// content-part array (`[{type: 'text', text: '…'}, …]`), in which case
  /// the `text` parts are concatenated. Any other content shape contributes
  /// no text.
  static String? _lastUserPrompt(List<Object?> messages) {
    for (final Object? message in messages.reversed) {
      if (message is! _Json) continue;
      if (message['role'] != 'user') continue;
      final String text = _contentText(message['content']);
      if (text.trim().isNotEmpty) return text.trim();
    }
    return null;
  }

  /// Extracts the text from a message `content` value: a bare string is
  /// returned as-is; a content-part array contributes the `text` of each
  /// `{type: 'text', text: …}` part; anything else yields the empty string.
  static String _contentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final StringBuffer buffer = StringBuffer();
      for (final Object? part in content) {
        if (part is _Json &&
            part['type'] == 'text' &&
            part['text'] is String) {
          buffer.write(part['text'] as String);
        }
      }
      return buffer.toString();
    }
    return '';
  }
}
