// B.9 — `EmbeddingResult` + `EmbeddingModelIdentity`.
//
// substrate_specification.md § 3.1 + § 7.4: every embedding result
// carries the identity of the model that produced it. The identity
// lands on memory's per-vector model marker row
// (`memory_specification.md` § 7.4) so cross-model vectors are never
// silently mixed.
//
// Why a separate `EmbeddingModelIdentity` rather than just a
// `String modelId`:
//
//   - Memory's similarity math is correct only when both sides of a
//     cosine were produced by the *same* (provider, model, dims,
//     normalized) tuple. Collapsing those four fields into a single
//     string would force every comparison site to re-parse the
//     string; the explicit class makes equality fast and obvious.
//   - `EmbeddingIdentityChanged` (spec § 10.2) carries
//     `{fromIdentity, toIdentity}`; a typed pair-of-records makes
//     the event payload unambiguous.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;

/// One embedding plus the identity of the model that produced it.
final class EmbeddingResult {
  /// The embedding vector. `Vec` is the substrate-and-memory shared
  /// Float32List wrapper (`tom_brain_shared`).
  final Vec vec;

  /// Which model produced this vector. Lands on memory's per-vector
  /// marker row so cross-model vectors are not mixed in similarity
  /// math (`memory_specification.md` § 7.4).
  final EmbeddingModelIdentity modelIdentity;

  const EmbeddingResult({required this.vec, required this.modelIdentity});
}

/// Identifies an embedding model.
///
/// Equality is structural: two identities compare equal iff all four
/// fields match. The substrate guarantees that two
/// [EmbeddingResult]s with `==` identities are comparable under
/// cosine (same dims, same provider, same model, same normalisation
/// rule).
final class EmbeddingModelIdentity {
  /// Provider identifier (e.g. `ollama:local`,
  /// `openai:passthrough`).
  final String providerId;

  /// Provider-side model identifier (e.g. `nomic-embed-text`,
  /// `text-embedding-3-small`).
  final String modelId;

  /// Dimensionality of every vector produced by this model. Memory
  /// rejects rows whose vector dimension does not match the
  /// declared per-model dimension.
  final int dims;

  /// `true` when the model emits unit-norm vectors and the substrate
  /// does not re-normalise. `false` when the substrate re-normalises
  /// to unit norm before returning (the spec § 7.2 default for
  /// `nomic-embed-text` is `normalize: true`).
  final bool normalized;

  const EmbeddingModelIdentity({
    required this.providerId,
    required this.modelId,
    required this.dims,
    required this.normalized,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EmbeddingModelIdentity &&
          other.providerId == providerId &&
          other.modelId == modelId &&
          other.dims == dims &&
          other.normalized == normalized);

  @override
  int get hashCode => Object.hash(providerId, modelId, dims, normalized);

  @override
  String toString() =>
      'EmbeddingModelIdentity($providerId/$modelId, '
      'dims=$dims, normalized=$normalized)';
}
