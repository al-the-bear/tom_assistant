// NodePersisted — the `MemoryEvent` leaf emitted by
// `NodePersister.persist` on a successful, non-idempotent commit
// (Plan step A.34).
//
// Plan step A.38 will land the rest of the node-lifecycle event
// leaves (`NodeDemoted`, `NodeForgotten`, `EdgeCreated`,
// `EdgeRejected`). A.34 emits the one event it produces and stops —
// other leaves will appear next to the operations that emit them, in
// the steps that own those operations.
//
// Idempotency interaction: a `persist` call that hits an existing
// `idempotency_key` returns the prior `NodeId` and emits NOTHING.
// The event stream is the audit log of *new* nodes — surfacing
// idempotent re-calls as events would make the stream's "count of
// persisted nodes" meaningless. Callers that want to observe
// deduplicated retries should look at the `Scope.idempotencyKey`
// they supplied (the persister cannot tell them anything new about a
// key they themselves generated).
//
// The discriminator (`memory.node-persisted`) follows the
// per-component convention documented on `MemoryEvent`.

import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../api/memory_event.dart';

/// Emitted when `NodePersister.persist` successfully commits a fresh
/// node (idempotency miss).
///
/// Carries enough context to reconstruct the persist transition
/// without reading SQLite: the new node id, its type, the producer
/// scope identifier, whether an embedding was committed (and under
/// which model), and the idempotency key (when one was supplied —
/// useful for the dispatcher's "did this run already produce this
/// node" cross-check).
final class NodePersisted extends MemoryEvent {
  /// Stable id assigned to the persisted node.
  final NodeId nodeId;

  /// Canonical type name. Always names a type that was registered at
  /// the moment of the persist call.
  final String typeName;

  /// Producer identifier from `Scope.producer`. Typically
  /// `<agent>:<procedure>:<run>` (spec § 9.1).
  final String producer;

  /// Idempotency key supplied by the caller, when one was supplied.
  /// `null` for non-idempotent writes (a freshly-minted Event with
  /// upstream-unique payload, for example).
  final String? idempotencyKey;

  /// Embedding model identity that produced the committed embedding.
  /// `null` when the type's `EmbeddingPolicy` is `none` and no vector
  /// was committed.
  final String? embeddingModelId;

  /// Vector dimensionality that was committed alongside the node.
  /// `null` when no vector was committed (see [embeddingModelId]).
  final int? embeddingDimensions;

  const NodePersisted({
    required this.nodeId,
    required this.typeName,
    required this.producer,
    required super.occurredAt,
    this.idempotencyKey,
    this.embeddingModelId,
    this.embeddingDimensions,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.node-persisted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'nodeId': nodeId.toString(),
        'typeName': typeName,
        'producer': producer,
        if (idempotencyKey != null) 'idempotencyKey': idempotencyKey,
        if (embeddingModelId != null) 'embeddingModelId': embeddingModelId,
        if (embeddingDimensions != null)
          'embeddingDimensions': embeddingDimensions,
      };
}
