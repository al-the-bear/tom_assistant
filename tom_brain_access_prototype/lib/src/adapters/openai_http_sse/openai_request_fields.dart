// Shared optional-field readers for the OpenAI request parsers (G.2.5).
//
// `chat_completion_request.dart` (E.12) and `embeddings_request.dart` (E.16)
// both decode a `jsonDecode`-produced `Object?` body the same way: reject a
// non-object body as `invalid_body`, then read optional typed fields whose
// failure is the OpenAI `400` envelope `{ message, code, param }` with a
// `code` of `invalid_<field>` and `param` of `<field>`. That guard pair was
// written twice, verbatim. This collapses it into three readers both parsers
// call.
//
// Why this is *access-local* and not a `tom_core_agentic` primitive: the
// shape it produces is the OpenAI error envelope — the `invalid_<field>`
// code slug and the `param` field are OpenAI-protocol vocabulary, not a
// domain-neutral concern. The generic "is this value a String / Map?" check
// already lives in `tom_core_agentic` (`MapFieldReader`), but that helper is
// throw-based and frames its own message; these parsers are pure
// (`Result`-returning) and must reproduce OpenAI's exact `code` / `param` /
// message, so they carry their own envelope-shaped reader here — the same
// access-local / not-core call `json_response.dart` (G.2.4) makes.
//
// Each parser keeps its own bespoke error *type*
// (`ChatCompletionParseError` / `EmbeddingsParseError`); the reader is
// generic over it and builds instances through the
// [OpenAiParseErrorFactory] the two types satisfy with their default
// constructor.

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// A decoded JSON object — the shape `jsonDecode` produces for an object body
/// and the only body shape the OpenAI request parsers accept.
typedef JsonObject = Map<String, Object?>;

/// Builds an OpenAI `400` parse-error of type [E] from the three fields every
/// such error carries: a human-readable [message], a stable machine [code]
/// slug, and the offending [param] (or `null` for a body-level failure).
///
/// `ChatCompletionParseError` and `EmbeddingsParseError` both satisfy this
/// with their default constructor (`const E({required message, required
/// code, param})`), so each parser passes `E.new` and keeps its own error
/// type.
typedef OpenAiParseErrorFactory<E> = E Function({
  required String message,
  required String code,
  String? param,
});

/// Returns [body] as a [JsonObject], or an `invalid_body` failure (built via
/// [error]) when it is anything else — a JSON array, number, string, or
/// `null`. The body-level failure carries no `param`.
Result<JsonObject, E> requireJsonObject<E>(
  Object? body,
  OpenAiParseErrorFactory<E> error,
) {
  if (body is! JsonObject) {
    return Err(error(
      message: 'Request body must be a JSON object.',
      code: 'invalid_body',
    ));
  }
  return Ok(body);
}

/// Reads the optional string at [key] in [body]: `Ok(null)` when absent,
/// `Ok(value)` when present and a string, or an `invalid_<key>` failure
/// (built via [error], with `param: key`) when present but non-string.
Result<String?, E> optionalStringField<E>(
  JsonObject body,
  String key,
  OpenAiParseErrorFactory<E> error,
) {
  final Object? raw = body[key];
  if (raw == null) return Ok<String?, E>(null);
  if (raw is! String) {
    return Err(error(
      message: "'$key' must be a string.",
      code: 'invalid_$key',
      param: key,
    ));
  }
  return Ok(raw);
}

/// Reads the optional bool at [key] in [body]: `Ok(null)` when absent,
/// `Ok(value)` when present and a bool, or an `invalid_<key>` failure (built
/// via [error], with `param: key`) when present but non-bool.
Result<bool?, E> optionalBoolField<E>(
  JsonObject body,
  String key,
  OpenAiParseErrorFactory<E> error,
) {
  final Object? raw = body[key];
  if (raw == null) return Ok<bool?, E>(null);
  if (raw is! bool) {
    return Err(error(
      message: "'$key' must be a boolean.",
      code: 'invalid_$key',
      param: key,
    ));
  }
  return Ok(raw);
}

/// The diagnostic reason a wrong-shape history / tool sub-entry is dropped
/// (proto spec § 11). The gateway parsers report it through their
/// `onMalformed` callback; the live prompt still parses (a wholly
/// unparseable body stays the existing `access.wire.malformed` `400`).
const String accessWireHistoryMalformed = 'access.wire.history.malformed';

/// The full request fidelity reduced from a `messages[]` array: the live
/// [prompt] (the last user message *after* the last tool result, or empty
/// when the conversation ends on a tool result — the client tool-loop
/// follow-up), the preceding [priorTurns], and the client-executed
/// [toolResults]. The top-level `tools[]` are reduced separately by
/// [openAiShapeRemoteTools]; together they populate `InboundRequest`'s four
/// Extension-G fields (proto spec § 5.2, hub § 22.1).
typedef RequestFidelity = ({
  String prompt,
  List<PriorTurn> priorTurns,
  List<RemoteToolResult> toolResults,
});

/// Extracts the text from a message `content` value: a bare string is
/// returned as-is; a content-part array concatenates the `text` of each
/// `{type: 'text', text: …}` part; anything else yields the empty string.
///
/// Shared by the OpenAI and Anthropic reductions — both dialects carry the
/// identical content shape (a bare string OR the `[{type:'text',text:…}]`
/// array). Anthropic's `tool_use` / `tool_result` blocks contribute no text
/// here (they are not `type: 'text'`), so an assistant turn that is only a
/// `tool_use` reduces to the empty string.
String messageContentText(Object? content) {
  if (content is String) return content;
  if (content is List) {
    final StringBuffer buffer = StringBuffer();
    for (final Object? part in content) {
      if (part is JsonObject &&
          part['type'] == 'text' &&
          part['text'] is String) {
        buffer.write(part['text'] as String);
      }
    }
    return buffer.toString();
  }
  return '';
}

/// Returns the index of the *live* user message in [messages], or `-1` when
/// there is none (the conversation ends on a tool result — a client tool-loop
/// follow-up with no new user text).
///
/// The live message is the last `user` message that carries text **and** sits
/// after the last tool result, as judged by [isToolResult] (the dialect-
/// specific predicate: an OpenAI `role: 'tool'` message, or an Anthropic
/// user message carrying a `tool_result` block). "Last user with text"
/// alone would mis-pick an earlier question as the live prompt on a
/// follow-up turn; gating it behind the last tool-result position is what
/// makes the trailing-`tool_result` case parse as empty-prompt.
int liveUserIndex(
  List<Object?> messages, {
  required bool Function(Object?) isToolResult,
}) {
  int lastUserWithText = -1;
  int lastToolResult = -1;
  for (int i = 0; i < messages.length; i++) {
    final Object? message = messages[i];
    if (message is JsonObject &&
        message['role'] == 'user' &&
        messageContentText(message['content']).trim().isNotEmpty) {
      lastUserWithText = i;
    }
    if (isToolResult(message)) lastToolResult = i;
  }
  return lastUserWithText > lastToolResult ? lastUserWithText : -1;
}

/// True when [message] is an OpenAI-shaped tool result — a `role: 'tool'`
/// message carrying a non-empty `tool_call_id`. A `role: 'tool'` entry with
/// no id is *not* a valid tool result (it is malformed), so it does not count
/// toward the live-prompt cutoff in [liveUserIndex].
bool _openAiIsToolResult(Object? message) =>
    message is JsonObject &&
    message['role'] == 'tool' &&
    message['tool_call_id'] is String &&
    (message['tool_call_id'] as String).trim().isNotEmpty;

/// Reduces an OpenAI-shaped `messages[]` array to its [RequestFidelity].
///
/// The live prompt is [messageContentText] of the message at [liveUserIndex]
/// (trimmed), or empty for a client tool-loop follow-up. Every `role: 'tool'`
/// message with a valid `tool_call_id` becomes a [RemoteToolResult]; every
/// other non-live message that carries text becomes a [PriorTurn] (an
/// empty-text turn — e.g. an assistant message with `content: null` — is
/// dropped silently, carrying no replayable text). A wrong-shape sub-entry (a
/// non-object message, or a `role: 'tool'` entry with no id) is dropped and
/// reported through [onMalformed] with [accessWireHistoryMalformed]; the live
/// prompt still parses.
///
/// Shared by the OpenAI `chat/completions` parser and the Ollama `/api/chat`
/// parser — Ollama chat is OpenAI-shaped (its plain-string content is handled
/// by [messageContentText]).
RequestFidelity reduceOpenAiMessages(
  List<Object?> messages, {
  void Function(String reason)? onMalformed,
}) {
  final int liveIndex =
      liveUserIndex(messages, isToolResult: _openAiIsToolResult);
  String prompt = '';
  final List<PriorTurn> priorTurns = <PriorTurn>[];
  final List<RemoteToolResult> toolResults = <RemoteToolResult>[];

  for (int i = 0; i < messages.length; i++) {
    final Object? message = messages[i];
    if (message is! JsonObject) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    if (i == liveIndex) {
      prompt = messageContentText(message['content']).trim();
      continue;
    }
    final Object? role = message['role'];
    if (role == 'tool') {
      final Object? id = message['tool_call_id'];
      if (id is! String || id.trim().isEmpty) {
        onMalformed?.call(accessWireHistoryMalformed);
        continue;
      }
      final Object? content = message['content'];
      toolResults.add(RemoteToolResult(
        toolCallId: id,
        content: content is String ? content : messageContentText(content),
      ));
      continue;
    }
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

/// Reduces an OpenAI-shaped top-level `tools[]` array to its [RemoteToolDef]
/// list. Each entry is `{type: 'function', function: {name, description?,
/// parameters?}}`; a wrong-shape entry (non-object, missing `function`, or a
/// blank `name`) is dropped and reported through [onMalformed] with
/// [accessWireHistoryMalformed]. `null` / a non-list `tools` yields the empty
/// list (a non-list is reported as malformed).
///
/// Shared by the OpenAI `chat/completions` parser and the Ollama `/api/chat`
/// parser (Ollama mirrors the OpenAI tools shape).
List<RemoteToolDef> openAiShapeRemoteTools(
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
    if (entry is! JsonObject || entry['function'] is! JsonObject) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    final JsonObject function = entry['function'] as JsonObject;
    final Object? name = function['name'];
    if (name is! String || name.trim().isEmpty) {
      onMalformed?.call(accessWireHistoryMalformed);
      continue;
    }
    final Object? description = function['description'];
    final Object? parameters = function['parameters'];
    tools.add(RemoteToolDef(
      name: name,
      description: description is String ? description : null,
      inputSchema:
          parameters is JsonObject ? parameters : const <String, Object?>{},
    ));
  }
  return tools;
}
