// OpenAI `embeddings` response rendering + the substrate seam (E.16).
//
// What this file owns (Plan § Phase E, substep E.16; proto spec § 5.6):
//
//   * `EmbeddingBatch` — the substrate-agnostic result the adapter's
//     `EmbeddingSource` seam returns: one float vector per input plus the
//     model identity that produced them. This is the boundary that keeps the
//     adapter free of any `tom_brain_substrate` import — boot (E.41+) adapts
//     the real `EmbeddingService.embedBatch` into this shape; tests supply a
//     synthetic one.
//   * `EmbeddingsResponseRenderer` — renders an `EmbeddingsRequest`'s inputs
//     and a resolved `EmbeddingBatch` into one OpenAI embeddings JSON body
//     (`object: "list"`, `data[].embedding`, `model`, `usage`).
//
// Why a seam rather than a direct substrate call (proto spec § 5.6,
// Q-E.2.2): the embeddings route is a *passthrough* — it is not a cognition,
// so the dispatcher need not mediate it. The default is to go straight to
// substrate's `EmbeddingService`. But the access prototype does not depend on
// `tom_brain_substrate` (Plan E.7 dependency set), so the adapter takes an
// injected function rather than the service type. The same injection point is
// where a future quota / observability wrapper would slot in if mediation is
// later required.
//
// `usage` (proto spec § 5.6, mirrors E.14's Q-E.2.1): the embedding call does
// not return a tokeniser-accurate count, so `prompt_tokens` / `total_tokens`
// are a deliberately approximate, tokeniser-free char/4 estimate over the
// inputs. Embeddings have no completion half, so there is no
// `completion_tokens` field and `total_tokens == prompt_tokens`.

import 'dart:convert';

/// One batch of embeddings plus the model that produced them — the
/// substrate-agnostic result the adapter's `EmbeddingSource` seam returns.
///
/// [vectors] holds one float vector per input, in input order
/// (`vectors.length == request.inputs.length`). [modelId] is the substrate
/// embedding model's identity (e.g. `nomic-embed-text`); it becomes the
/// response's `model` field — the prototype echoes the *actual* embedding
/// model, not the request's (informational) `model` string (proto spec
/// § 5.6).
final class EmbeddingBatch {
  /// One embedding per input, in input order. Each inner list is the raw
  /// float vector.
  final List<List<double>> vectors;

  /// The substrate embedding model's identity, stamped into the response
  /// `model` field.
  final String modelId;

  /// Builds the batch. [vectors] must align with the request's inputs by
  /// index; the renderer asserts the count matches.
  const EmbeddingBatch({required this.vectors, required this.modelId});
}

/// Renders an OpenAI `embeddings` JSON body (proto spec § 5.6).
///
/// Pure and stateless: [render] takes the request inputs and the resolved
/// [EmbeddingBatch] and returns the encoded body. The body is the OpenAI
/// list shape:
///
/// ```json
/// {
///   "object": "list",
///   "data": [ { "object": "embedding", "index": 0, "embedding": [ … ] } ],
///   "model": "nomic-embed-text",
///   "usage": { "prompt_tokens": N, "total_tokens": N }
/// }
/// ```
final class EmbeddingsResponseRenderer {
  /// The OpenAI top-level list object type.
  static const String listObjectType = 'list';

  /// The OpenAI per-item embedding object type.
  static const String embeddingObjectType = 'embedding';

  /// Builds the renderer. Stateless — a single shared instance is fine.
  const EmbeddingsResponseRenderer();

  /// Builds the OpenAI embeddings body map for [inputs] embedded into
  /// [batch]. Pure — no I/O.
  ///
  /// Requires `batch.vectors.length == inputs.length`; the embedding source
  /// guarantees one vector per input (substrate's `embedBatch` preserves
  /// order and count). A mismatch is a programming error in the seam wiring,
  /// surfaced as an [ArgumentError] rather than a silently truncated body.
  Map<String, Object?> bodyMap({
    required List<String> inputs,
    required EmbeddingBatch batch,
  }) {
    if (batch.vectors.length != inputs.length) {
      throw ArgumentError.value(
        batch.vectors.length,
        'batch.vectors.length',
        'must equal inputs.length (${inputs.length})',
      );
    }
    final List<Object?> data = <Object?>[
      for (int i = 0; i < batch.vectors.length; i++)
        <String, Object?>{
          'object': embeddingObjectType,
          'index': i,
          'embedding': batch.vectors[i],
        },
    ];
    final int promptTokens = _estimateTokens(inputs);
    return <String, Object?>{
      'object': listObjectType,
      'data': data,
      'model': batch.modelId,
      'usage': <String, Object?>{
        'prompt_tokens': promptTokens,
        'total_tokens': promptTokens,
      },
    };
  }

  /// Encodes [bodyMap] to the JSON string the wire layer sends.
  String bodyJson({
    required List<String> inputs,
    required EmbeddingBatch batch,
  }) =>
      jsonEncode(bodyMap(inputs: inputs, batch: batch));

  /// Approximate, tokeniser-free token count over all [inputs] (mirrors
  /// E.14's `ceil(length / 4)`; empty text counts as zero). The single place
  /// to replace once the embedding call surfaces a real token count.
  static int _estimateTokens(List<String> inputs) {
    int total = 0;
    for (final String text in inputs) {
      if (text.isNotEmpty) total += (text.length / 4).ceil();
    }
    return total;
  }
}
