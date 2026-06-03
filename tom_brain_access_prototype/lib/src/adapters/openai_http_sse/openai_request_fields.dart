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
