// VectorTableException — sealed failure family for `VectorTable`
// (Plan step A.51).
//
// `VectorTable` is the `vectors.db` side of the storage stack — the
// home of every embedding row produced by the substrate. The refusal
// paths fall into three categorically-distinct buckets:
//
//   1. `EmbeddingModelMismatch`        — the caller named a model that
//                                        has no installed index. Per
//                                        spec § 10.4 ("Memory records
//                                        the embedding-model-identity
//                                        per vector and refuses to mix
//                                        incompatible vectors in a
//                                        single index") the writer
//                                        refuses to silently invent an
//                                        index — installation is a
//                                        deliberate operator decision
//                                        (or a `restructure_tree_v1`
//                                        migration step).
//   2. `EmbeddingDimsMismatch`         — the caller's vector dimension
//                                        does not match the
//                                        dimensionality the model was
//                                        installed with. The vec0
//                                        virtual table fixes its
//                                        dimension at CREATE time;
//                                        mixing widths within one
//                                        index would corrupt the
//                                        nearest-neighbour math, so
//                                        the layer rejects at the
//                                        boundary.
//   3. `IndexInstallationConflict`     — the same `modelId` was
//                                        previously installed with a
//                                        different dimensionality.
//                                        Triggered exclusively by
//                                        `installIndex`; a no-op for
//                                        the read paths. Indicates an
//                                        operator config mistake (two
//                                        deployments with conflicting
//                                        beliefs about the same model
//                                        name) or a model that
//                                        upstream changed its dim
//                                        without changing its id —
//                                        either way, requires manual
//                                        intervention.
//
// All three are unrecoverable inside memory. Callers in higher layers
// translate to a `MemoryEvent` (when the operator wants to see the
// refusal in the event stream) or to a procedure-engine failure (when
// the refusal aborts a run). The exceptions never wrap each other —
// each path is the leaf cause.
//
// Sealed: adding a fourth category is a deliberate breaking change
// in this layer. Most plausible future categories (a write that
// exceeded a per-model row cap; a backend-specific I/O failure) would
// be handled inside the backend impl rather than as a new sealed leaf.

/// Sealed base for every refusal raised by `VectorTable`.
sealed class VectorTableException implements Exception {
  /// Embedding-model identity the caller named (or, for
  /// [IndexInstallationConflict], the id of the index whose
  /// installation conflicted).
  final String modelId;

  /// Human-readable explanation. Always names the model and the
  /// dimensionality involved when relevant.
  final String message;

  const VectorTableException({
    required this.modelId,
    required this.message,
  });

  @override
  String toString() => '$runtimeType(model: $modelId): $message';
}

/// The caller named a model that has no installed index.
///
/// Common cause: a new substrate model went online and the operator
/// has not yet run the installation step (or the equivalent
/// `restructure_tree_v1` migration). The right next action is *not*
/// to silently create the index — that would let two deployments
/// running different versions of the same model build divergent
/// indexes that look mergeable by name.
final class EmbeddingModelMismatch extends VectorTableException {
  const EmbeddingModelMismatch({
    required super.modelId,
    required super.message,
  });
}

/// The caller's vector dimensionality does not match the
/// dimensionality the model was installed with.
///
/// The vec0 virtual table fixes its dimension at CREATE time. A
/// dimension change for an installed model is a re-installation —
/// the layer does not attempt to interpret a 768-d vector as a
/// 1024-d one (or vice versa) and refuses at the call boundary.
final class EmbeddingDimsMismatch extends VectorTableException {
  /// Dimensionality the layer expected (taken from the installed
  /// `vector_indexes` meta row).
  final int expectedDims;

  /// Dimensionality the caller actually supplied.
  final int actualDims;

  const EmbeddingDimsMismatch({
    required super.modelId,
    required super.message,
    required this.expectedDims,
    required this.actualDims,
  });
}

/// `installIndex` was called for a model that is already installed at
/// a different dimensionality.
///
/// Strict — no auto-resize, no auto-replace. The operator must either
/// (a) drop the existing index and re-install at the new dim, or
/// (b) pick a new model id. This protects against the
/// "model `nomic-embed-text` is 768-d in dev and 1024-d in prod"
/// configuration drift that would otherwise corrupt a shared
/// `vectors.db`.
final class IndexInstallationConflict extends VectorTableException {
  /// Dimensionality the existing meta row records.
  final int existingDims;

  /// Dimensionality the caller proposed.
  final int proposedDims;

  const IndexInstallationConflict({
    required super.modelId,
    required super.message,
    required this.existingDims,
    required this.proposedDims,
  });
}
