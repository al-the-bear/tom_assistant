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

/// Returns the trimmed text of the last `user` message in [messages], or
/// `null` when none carries usable text.
///
/// The Anthropic Messages parser
/// (`adapters/anthropic/anthropic_requests.dart`) reduces its `messages`
/// array exactly as the OpenAI `chat/completions` parser does — content is a
/// bare string OR the `[{type: 'text', text: '…'}, …]` content-part array,
/// both wire dialects sharing the same shape. This is that shared reduction,
/// extracted on its second consumer so the two parsers cannot drift. (The
/// Ollama parser keeps its own string-only reader: Ollama has no content-part
/// array, so its reduction is a *different* contract, not a third copy of
/// this one.)
///
/// [content] handling: a bare string is taken as-is; a content-part array
/// concatenates the `text` of each `{type: 'text', text: …}` part; any other
/// shape contributes nothing. A message whose reduced text is blank is
/// skipped, scanning newest-first.
String? lastUserText(List<Object?> messages) {
  for (final Object? message in messages.reversed) {
    if (message is! JsonObject) continue;
    if (message['role'] != 'user') continue;
    final String text = _contentText(message['content']);
    if (text.trim().isNotEmpty) return text.trim();
  }
  return null;
}

/// Extracts the text from a message `content` value for [lastUserText]: a
/// bare string is returned as-is; a content-part array contributes the `text`
/// of each `{type: 'text', text: …}` part; anything else yields the empty
/// string.
String _contentText(Object? content) {
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
