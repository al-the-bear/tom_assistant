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

  /// The preceding `messages[]` turns (everything before the live user
  /// message, excluding the `tool_result` carriers), in wire order. Empty for
  /// a single-message request. Extension G (hub § 22.1).
  final List<PriorTurn> priorTurns;

  /// The client-executed `tool_result` blocks echoed back on a follow-up
  /// turn, keyed by `tool_use_id`. Empty unless the client is continuing a
  /// remote-tool round. Extension G (hub § 22.8).
  final List<RemoteToolResult> toolResults;

  /// The client-declared top-level `tools[]` the brain may *propose* but never
  /// executes (Anthropic `{name, description?, input_schema?}` shape). Empty
  /// unless the client declared tools. Extension G (hub § 22.8).
  final List<RemoteToolDef> remoteTools;

  /// Builds the DTO directly. Callers normally use [parse]; this is exposed
  /// for tests and for any adapter that constructs the shape itself. The three
  /// Extension-G lists default empty so a pre-Extension-G caller is unchanged.
  const AnthropicRequest({
    required this.prompt,
    required this.model,
    required this.stream,
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
  /// the adapter fills when it has them; the Anthropic HTTP wire carries
  /// neither natively, so they default to `null`. [sessionId] is the value the
  /// edge lifts from the `X-Tom-Session` request header (proto spec § 5.2);
  /// `null` when the client sent none.
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

  /// Decodes and validates a `POST /v1/messages` body.
  ///
  /// The live prompt is the last `user` message's text content (string or
  /// content-part array) that sits after the last `tool_result` carrier;
  /// the preceding turns become [priorTurns], every `tool_result` block
  /// becomes a [RemoteToolResult], and the top-level `tools[]` become
  /// [remoteTools]. Returns:
  ///
  ///   * `Ok(AnthropicRequest)` when `messages` yields a usable live prompt
  ///     **or** a client tool-loop follow-up (a trailing `tool_result` with no
  ///     new user text), and `model` / `stream` (if present) have the right
  ///     types;
  ///   * `Err(AnthropicParseError)` for a non-object body, a missing /
  ///     non-array / empty `messages`, a conversation with no user turn at all,
  ///     or a non-string `model` / non-bool `stream`.
  ///
  /// A wrong-shape `messages[]` / `tools[]` sub-entry is dropped and reported
  /// through [onMalformed] with [accessWireHistoryMalformed] (proto spec
  /// § 11); the live prompt still parses. `max_tokens` and `system` are
  /// ignored. This method is pure: no I/O, no throwing on malformed input.
  static Result<AnthropicRequest, AnthropicParseError> parse(
    Object? body, {
    void Function(String reason)? onMalformed,
  }) {
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

    final RequestFidelity fidelity =
        _reduceAnthropicMessages(rawMessages, onMalformed: onMalformed);
    final List<RemoteToolDef> remoteTools =
        _anthropicRemoteTools(json['tools'], onMalformed: onMalformed);

    // No live prompt AND no tool result → the conversation carries no user
    // turn at all (a system-/assistant-only body). A trailing tool result with
    // an empty prompt is the valid client tool-loop follow-up.
    if (fidelity.prompt.isEmpty && fidelity.toolResults.isEmpty) {
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
      prompt: fidelity.prompt,
      model: model,
      stream: stream ?? false,
      priorTurns: fidelity.priorTurns,
      toolResults: fidelity.toolResults,
      remoteTools: remoteTools,
    ));
  }
}

/// True when [message] is an Anthropic-shaped tool-result carrier — a message
/// whose `content` array holds at least one `{type: 'tool_result',
/// tool_use_id: non-empty}` block. A `tool_result` block with no id is *not*
/// a valid carrier (it is malformed), so it does not count toward the
/// live-prompt cutoff in [liveUserIndex].
bool _anthropicMessageHasToolResult(Object? message) {
  if (message is! _Json) return false;
  final Object? content = message['content'];
  if (content is! List) return false;
  return content.any((Object? part) =>
      part is _Json &&
      part['type'] == 'tool_result' &&
      part['tool_use_id'] is String &&
      (part['tool_use_id'] as String).trim().isNotEmpty);
}

/// Reduces an Anthropic-shaped `messages[]` array to its [RequestFidelity].
///
/// The live prompt is [messageContentText] of the message at [liveUserIndex]
/// (trimmed), or empty for a client tool-loop follow-up. Every `tool_result`
/// block with a valid `tool_use_id` becomes a [RemoteToolResult]; every other
/// non-live message that carries text becomes a [PriorTurn] (an assistant turn
/// that is only a `tool_use` reduces to empty text via [messageContentText]
/// and is dropped). A wrong-shape sub-entry (a non-object message) is dropped
/// and reported through [onMalformed] with [accessWireHistoryMalformed].
RequestFidelity _reduceAnthropicMessages(
  List<Object?> messages, {
  void Function(String reason)? onMalformed,
}) {
  final int liveIndex =
      liveUserIndex(messages, isToolResult: _anthropicMessageHasToolResult);
  String prompt = '';
  final List<PriorTurn> priorTurns = <PriorTurn>[];
  final List<RemoteToolResult> toolResults = <RemoteToolResult>[];

  for (int i = 0; i < messages.length; i++) {
    final Object? message = messages[i];
    if (message is! _Json) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    if (i == liveIndex) {
      prompt = messageContentText(message['content']).trim();
      continue;
    }
    if (_anthropicMessageHasToolResult(message)) {
      _collectAnthropicToolResults(message['content'], toolResults, onMalformed);
      continue;
    }
    final Object? role = message['role'];
    if (role is! String || role.trim().isEmpty) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    final String text = messageContentText(message['content']);
    if (text.trim().isEmpty) continue;
    priorTurns.add(PriorTurn(role: role, text: text));
  }
  return (prompt: prompt, priorTurns: priorTurns, toolResults: toolResults);
}

/// Appends every `{type: 'tool_result', tool_use_id: non-empty}` block in
/// [content] to [into] as a [RemoteToolResult]. A `tool_result` block with a
/// blank / missing `tool_use_id` is dropped and reported through [onMalformed].
void _collectAnthropicToolResults(
  Object? content,
  List<RemoteToolResult> into,
  void Function(String reason)? onMalformed,
) {
  if (content is! List) return;
  for (final Object? part in content) {
    if (part is! _Json || part['type'] != 'tool_result') continue;
    final Object? id = part['tool_use_id'];
    if (id is! String || id.trim().isEmpty) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    final Object? blockContent = part['content'];
    into.add(RemoteToolResult(
      toolCallId: id,
      content: blockContent is String
          ? blockContent
          : messageContentText(blockContent),
    ));
  }
}

/// Reduces an Anthropic-shaped top-level `tools[]` array to its [RemoteToolDef]
/// list. Each entry is `{name, description?, input_schema?}` (note: no
/// `function` wrapper, unlike OpenAI); a wrong-shape entry (non-object or a
/// blank `name`) is dropped and reported through [onMalformed]. `null` /
/// a non-list `tools` yields the empty list (a non-list is reported malformed).
List<RemoteToolDef> _anthropicRemoteTools(
  Object? rawTools, {
  void Function(String reason)? onMalformed,
}) {
  if (rawTools == null) return const <RemoteToolDef>[];
  if (rawTools is! List) {
    onMalformed?.call(accessWireHistoryMalformed);
    return const <RemoteToolDef>[];
  }
  final List<RemoteToolDef> tools = <RemoteToolDef>[];
  for (final Object? entry in rawTools) {
    if (entry is! _Json) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    final Object? name = entry['name'];
    if (name is! String || name.trim().isEmpty) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    final Object? description = entry['description'];
    final Object? schema = entry['input_schema'];
    tools.add(RemoteToolDef(
      name: name,
      description: description is String ? description : null,
      inputSchema: schema is _Json ? schema : const <String, Object?>{},
    ));
  }
  return tools;
}
