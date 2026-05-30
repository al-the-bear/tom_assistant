// NodePersistException — typed failure family for
// `NodePersister.persist` (Plan step A.34).
//
// Every refusal path the persister can take throws a typed subclass so
// callers can branch on the cause without parsing prose. The base
// class is sealed: adding a new failure category is a deliberate
// breaking change in this layer.
//
// Categories, in the order the persister checks them:
//
//   1. `UnknownNodeType`              — `NodeDraft.typeName` does not
//                                       match any registered type.
//                                       Caller must register the type
//                                       first (via `propose_node_type_v1`).
//   2. `InvalidNodeDraft`             — the draft is structurally
//                                       wrong against the registered
//                                       schema (unknown field, missing
//                                       required field, field-type
//                                       mismatch, enum-value not in
//                                       allowed set, nodeRef not a
//                                       valid NodeId, …).
//   3. `EmbeddingPolicyViolation`     — `draft.embedding` does not
//                                       match the type's
//                                       `EmbeddingPolicy` (missing
//                                       when policy requires one,
//                                       supplied when policy says
//                                       none, or dimension mismatch).
//
// Idempotency hits are NOT failures — they return the prior `NodeId`
// from `persist()` and emit nothing. The exception family covers
// refusals only.
//
// Per the quest's hard principles, none of these errors are
// recoverable inside memory — the caller (typically an agent or a
// procedure) decides whether to retry with a fixed draft, surface the
// error to the user, or abandon the write.

/// Sealed base for every failure category of `NodePersister.persist`.
sealed class NodePersistException implements Exception {
  /// Type name the draft carried (preserved so logs always identify
  /// the offending draft even when the exception is caught far from
  /// the call site).
  final String typeName;

  /// Human-readable explanation. Always names the type and, when
  /// relevant, the specific field / dimension / value.
  final String message;

  const NodePersistException({
    required this.typeName,
    required this.message,
  });

  @override
  String toString() => '$runtimeType($typeName): $message';
}

/// `NodeDraft.typeName` is not registered. The caller must register
/// the type via `propose_node_type_v1` (or wait for bootstrap) before
/// persisting nodes of this type.
final class UnknownNodeType extends NodePersistException {
  const UnknownNodeType({required super.typeName, required super.message});
}

/// The draft's `values` map is structurally inconsistent with the
/// registered `NodeTypeDecl.schema`.
///
/// Sub-cases live in [InvalidNodeDraftReason]; the reason is also
/// reflected in the human message.
final class InvalidNodeDraft extends NodePersistException {
  /// Field name responsible for the failure, when the failure is
  /// field-scoped. `null` for whole-draft failures (e.g. a draft with
  /// a duplicate-key map under some future encoding).
  final String? fieldName;

  /// Categorical reason — useful for branching without prose parsing.
  final InvalidNodeDraftReason reason;

  const InvalidNodeDraft({
    required super.typeName,
    required super.message,
    required this.reason,
    this.fieldName,
  });

  @override
  String toString() => fieldName == null
      ? 'InvalidNodeDraft($typeName) [${reason.name}]: $message'
      : 'InvalidNodeDraft($typeName).$fieldName [${reason.name}]: $message';
}

/// Sub-categorisation of [InvalidNodeDraft] failures.
enum InvalidNodeDraftReason {
  /// `values` contains a key that is not in the registered schema.
  unknownField,

  /// A non-nullable schema field is absent from `values`.
  missingRequiredField,

  /// A field value has the wrong Dart type for its `FieldSpec.type`.
  fieldTypeMismatch,

  /// An enumeration-typed field value is not in `FieldSpec.enumValues`.
  enumValueOutOfRange,

  /// A `nodeRef` field value does not parse as a valid `NodeId`.
  invalidNodeRef,

  /// A `nodeRef` field value is restricted to specific target types
  /// (`FieldSpec.nodeRefTypes`) and the referenced node-id was
  /// supplied as a plain string the persister cannot map back to a
  /// type. Reserved for a future tightening; not raised at A.34.
  nodeRefTypeRestricted,
}

/// `draft.embedding` is inconsistent with the type's `EmbeddingPolicy`.
final class EmbeddingPolicyViolation extends NodePersistException {
  /// Categorical reason — useful for branching without prose parsing.
  final EmbeddingPolicyViolationReason reason;

  /// Embedding dimension declared by the type, when the failure is a
  /// dimension mismatch. `null` for `missingEmbedding` /
  /// `unexpectedEmbedding`.
  final int? expectedDimensions;

  /// Embedding dimension actually supplied, when the failure is a
  /// dimension mismatch. `null` for `missingEmbedding` /
  /// `unexpectedEmbedding`.
  final int? actualDimensions;

  const EmbeddingPolicyViolation({
    required super.typeName,
    required super.message,
    required this.reason,
    this.expectedDimensions,
    this.actualDimensions,
  });
}

/// Sub-categorisation of [EmbeddingPolicyViolation] failures.
enum EmbeddingPolicyViolationReason {
  /// The type declares an embedding policy but the draft did not
  /// supply one. Tom Brain memory does not embed lazily — the caller
  /// (substrate-aware code) must produce the embedding before
  /// persisting. Memory persisting without an embedding would silently
  /// remove the node from vector recall.
  missingEmbedding,

  /// The type declares `EmbeddingPolicy.none` but the draft carried an
  /// embedding. Refused so callers cannot accidentally pollute
  /// `vectors.db` with embeddings the retrieval pipeline would never
  /// look up.
  unexpectedEmbedding,

  /// The draft's embedding dimension differs from the policy's
  /// declared dimensions. Refused to keep the vector index
  /// homogeneous per type (mixed dimensions break sqlite-vec).
  dimensionMismatch,
}
