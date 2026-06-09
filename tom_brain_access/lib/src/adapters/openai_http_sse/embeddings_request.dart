// OpenAI `embeddings` request parsing (E.16).
//
// What this file owns (Plan § Phase E, substep E.16; proto spec § 5.6):
//
//   * `EmbeddingsRequest` — the wire-level DTO produced by decoding the
//     `POST /v1/embeddings` JSON body into the two fields the prototype
//     reads: the `input` (one or more strings, reduced to a `List<String>`)
//     and the `model` string (informational metadata; the prototype's
//     substrate has a single embedding model — § 5.6).
//   * `EmbeddingsParseError` — the typed parse failure, carrying the pieces
//     the OpenAI `400` error envelope needs (`message`, `param`, `code`).
//   * `EmbeddingsRequest.parse(...)` — the pure decode-and-validate step.
//     Returns a `Result`; it never throws on bad input and never touches the
//     network.
//
// Scope discipline (mirrors E.12): E.16 parsing is *parsing only*. This file
// derives the input list and the model id and stops. It does NOT call the
// embedding service (that is the adapter's injected `EmbeddingSource` seam,
// rendered in `embeddings_response.dart`) or reach the substrate directly.
//
// OpenAI's `input` accepts a string, an array of strings, an array of token
// ids, or an array of token-id arrays. The prototype supports **text only**:
// a bare string or an array of (non-empty) strings. Token-id inputs are a
// reported `400` rather than a silent best-effort — the prototype embeds
// text, not pre-tokenised ids. Likewise `encoding_format`, when present, must
// be the default `float`; `base64` is rejected at the boundary because the
// prototype renders raw float arrays (proto spec § 5.6).

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'openai_request_fields.dart';

/// A decoded JSON object — the shape `jsonDecode` produces for an object
/// body. Aliased so the type checks below read as intent. Identical to
/// [JsonObject]; kept as a file-local name for the `input` reads that stay
/// in this file.
typedef _Json = Map<String, Object?>;

/// A typed `embeddings` request-parsing failure.
///
/// Maps one-to-one onto the OpenAI `400` error envelope:
/// `{ "error": { "message", "type": "invalid_request_error",
/// "param", "code" } }`. The adapter renders it; this type carries the
/// content.
final class EmbeddingsParseError {
  /// Human-readable explanation, suitable for the `error.message` field.
  final String message;

  /// The OpenAI `error.code` — a stable, machine-readable slug
  /// (`invalid_body`, `missing_input`, `invalid_input`, `invalid_model`,
  /// `invalid_encoding_format`).
  final String code;

  /// The offending request parameter (`input`, `model`, `encoding_format`),
  /// or `null` for a body-level failure that no single parameter owns.
  final String? param;

  /// Builds a parse error.
  const EmbeddingsParseError({
    required this.message,
    required this.code,
    this.param,
  });

  @override
  bool operator ==(Object other) =>
      other is EmbeddingsParseError &&
      other.message == message &&
      other.code == code &&
      other.param == param;

  @override
  int get hashCode => Object.hash(message, code, param);

  @override
  String toString() =>
      'EmbeddingsParseError(code: $code, param: $param, message: $message)';
}

/// The decoded `POST /v1/embeddings` request, reduced to the fields the
/// prototype consumes.
///
/// Immutable value object produced by [EmbeddingsRequest.parse]. The adapter
/// hands [inputs] to its injected `EmbeddingSource` seam and renders the
/// resulting vectors in the OpenAI embeddings shape.
final class EmbeddingsRequest {
  /// The one-or-more text inputs to embed, in request order. Always
  /// non-empty, and every element is a non-empty (trimmed-non-empty) string:
  /// a request whose `input` yields no usable text is a parse failure, not an
  /// empty input list.
  final List<String> inputs;

  /// The raw `model` string. `null` when the request omitted `model`. The
  /// prototype's substrate exposes a single embedding model, so this is
  /// informational only (the rendered response echoes the substrate's actual
  /// model identity, not this field — proto spec § 5.6).
  final String? model;

  /// Builds the DTO directly. Callers normally use [parse]; this is exposed
  /// for tests and for any future adapter that constructs the shape itself.
  const EmbeddingsRequest({required this.inputs, required this.model});

  /// Decodes and validates an already-JSON-decoded request [body].
  ///
  /// [body] is the result of `jsonDecode` on the request payload, typed as
  /// `Object?` so a non-object body is a reported failure rather than a thrown
  /// cast. Returns:
  ///
  ///   * `Ok(EmbeddingsRequest)` when `input` yields one or more usable text
  ///     strings and `model` / `encoding_format` (if present) have the right
  ///     types / values;
  ///   * `Err(EmbeddingsParseError)` otherwise.
  ///
  /// This method is pure: no I/O, no throwing on malformed input.
  static Result<EmbeddingsRequest, EmbeddingsParseError> parse(Object? body) {
    final _Json json;
    switch (requireJsonObject(body, EmbeddingsParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        json = value;
    }

    if (!json.containsKey('input')) {
      return const Err(EmbeddingsParseError(
        message: "Missing required parameter: 'input'.",
        code: 'missing_input',
        param: 'input',
      ));
    }

    final List<String> inputs;
    switch (_parseInput(json['input'])) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        inputs = value;
    }

    final String? model;
    switch (optionalStringField(json, 'model', EmbeddingsParseError.new)) {
      case Err(:final error):
        return Err(error);
      case Ok(:final value):
        model = value;
    }

    final Object? rawFormat = json['encoding_format'];
    if (rawFormat != null && rawFormat != 'float') {
      return const Err(EmbeddingsParseError(
        message: "'encoding_format' must be 'float'; the prototype does not "
            'emit base64 embeddings.',
        code: 'invalid_encoding_format',
        param: 'encoding_format',
      ));
    }

    return Ok(EmbeddingsRequest(inputs: inputs, model: model));
  }

  /// Reduces the OpenAI `input` value to a non-empty `List<String>`.
  ///
  /// Accepts a bare string or an array of strings; every string must be
  /// non-empty after trimming. Rejects an empty string, an empty array, an
  /// array containing a non-string (token-id input — unsupported), and any
  /// other shape.
  static Result<List<String>, EmbeddingsParseError> _parseInput(Object? input) {
    if (input is String) {
      if (input.trim().isEmpty) {
        return const Err(EmbeddingsParseError(
          message: "'input' string must not be empty.",
          code: 'invalid_input',
          param: 'input',
        ));
      }
      return Ok(<String>[input]);
    }

    if (input is List) {
      if (input.isEmpty) {
        return const Err(EmbeddingsParseError(
          message: "'input' array must not be empty.",
          code: 'invalid_input',
          param: 'input',
        ));
      }
      final List<String> texts = <String>[];
      for (final Object? element in input) {
        if (element is! String) {
          return const Err(EmbeddingsParseError(
            message: "'input' must be a string or an array of strings; "
                'token-id inputs are not supported by the prototype.',
            code: 'invalid_input',
            param: 'input',
          ));
        }
        if (element.trim().isEmpty) {
          return const Err(EmbeddingsParseError(
            message: "'input' array must not contain an empty string.",
            code: 'invalid_input',
            param: 'input',
          ));
        }
        texts.add(element);
      }
      return Ok(texts);
    }

    return const Err(EmbeddingsParseError(
      message: "'input' must be a string or an array of strings.",
      code: 'invalid_input',
      param: 'input',
    ));
  }
}
