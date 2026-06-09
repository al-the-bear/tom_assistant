// OpenAI `models` list response rendering (E.17).
//
// What this file owns (Plan § Phase E, substep E.17; proto spec § 5.7):
//
//   * `ModelsResponseRenderer` — the pure, network-free renderer that turns a
//     list of persona-as-model ids into one OpenAI models-list JSON body
//     (`object: "list"`, `data[].id`, `data[].object == "model"`,
//     `data[].created`, `data[].owned_by`).
//
// Scope discipline (per the strict per-substep log): E.17 is the *models
// listing* only. The set of ids it lists is the adapter's persona vocabulary
// (`OpenAiPersonaMapping.knownModels`, E.15) — this renderer does not own the
// vocabulary, it only renders whatever ids it is handed, defaulting to the
// known persona ids. It does NOT:
//
//   * reach any cognition, substrate, or dispatcher — the persona list is a
//     static, adapter-owned vocabulary, so (unlike the chat and embeddings
//     routes) the models route needs no injected source and never answers
//     `501`.
//   * read the wall clock — `created` is a fixed deterministic constant. The
//     personas are static, so their "creation time" is a constant, not a
//     per-request timestamp. This keeps the response byte-for-byte
//     reproducible (important for the E.18 / E.53 wire-format fixtures).

import 'dart:convert';

import 'persona_mapping.dart';

/// Renders an OpenAI `models` list JSON body (proto spec § 5.7).
///
/// Pure and stateless: [bodyMap] / [bodyJson] take the model ids to list and
/// return the encoded body. The body is the OpenAI list shape:
///
/// ```json
/// {
///   "object": "list",
///   "data": [
///     {
///       "id": "tom-assistant",
///       "object": "model",
///       "created": 1735689600,
///       "owned_by": "tom-brain"
///     }
///   ]
/// }
/// ```
final class ModelsResponseRenderer {
  /// The OpenAI top-level list object type.
  static const String listObjectType = 'list';

  /// The OpenAI per-item model object type.
  static const String modelObjectType = 'model';

  /// The owner stamped into every listed model. The prototype's personas are
  /// all served by Tom Brain, so they share one owner id.
  static const String ownedBy = 'tom-brain';

  /// The fixed creation timestamp (Unix epoch seconds: 2025-01-01T00:00:00Z)
  /// stamped into every listed model. The personas are static, so this is a
  /// deterministic constant rather than a wall-clock read — the models
  /// response is the same bytes on every request. Named distinctly from the
  /// chat renderers' per-response `created` field, which *is* a wall-clock
  /// timestamp.
  static const int modelsListCreatedEpoch = 1735689600;

  /// Builds the renderer. Stateless — a single shared instance is fine.
  const ModelsResponseRenderer();

  /// Builds the OpenAI models-list body map for [models]. Pure — no I/O.
  ///
  /// [models] defaults to the recognised persona-as-model vocabulary
  /// ([OpenAiPersonaMapping.knownModels], E.15). Each id becomes one
  /// `{ id, object: "model", created, owned_by }` item, in the order given.
  Map<String, Object?> bodyMap({
    List<String> models = OpenAiPersonaMapping.knownModels,
  }) {
    final List<Object?> data = <Object?>[
      for (final String id in models)
        <String, Object?>{
          'id': id,
          'object': modelObjectType,
          'created': modelsListCreatedEpoch,
          'owned_by': ownedBy,
        },
    ];
    return <String, Object?>{
      'object': listObjectType,
      'data': data,
    };
  }

  /// Encodes [bodyMap] to the JSON string the wire layer sends.
  String bodyJson({
    List<String> models = OpenAiPersonaMapping.knownModels,
  }) =>
      jsonEncode(bodyMap(models: models));
}
