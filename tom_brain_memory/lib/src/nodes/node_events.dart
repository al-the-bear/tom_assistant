// Node-lifecycle `MemoryEvent` leaves —
//   * `NodePersisted` (Plan step A.34) — successful, non-idempotent
//     persist commit.
//   * `NodeDemoted` (Plan step A.38) — successful `active → demoted`
//     status flip.
//   * `NodeForgotten` (Plan step A.38) — successful Tombstone-and-
//     delete commit.
//
// All three follow the success-only emission convention documented on
// `MemoryEvent`: idempotent / no-op calls (re-persist hitting an
// existing `idempotency_key`, demote of an already-demoted or unknown
// node, forget of an unknown or already-forgotten id) emit **nothing**.
// The event stream is the audit log of *state transitions*; surfacing
// no-ops would make every per-leaf count meaningless. Callers that
// want to observe deduplicated retries should look at the
// `Scope.idempotencyKey` they supplied (the persister cannot tell
// them anything new about a key they themselves generated), or at the
// pre-call `NodeReader.get(id)` they did anyway.
//
// The asymmetry with the edge path (where `EdgeRejected` IS emitted
// on every refusal) is intentional: edge rejections are caller
// errors that the autonomous edge-proposers need to see in
// telemetry; node demote/forget no-ops are convergence behaviour,
// not failures. Tracked alongside Q-A.36.1.
//
// The discriminators (`memory.node-persisted`, `memory.node-demoted`,
// `memory.node-forgotten`) follow the per-component convention
// documented on `MemoryEvent`.

import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../api/memory_event.dart';
import '../api/scope.dart';

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

/// Emitted when `NodeLifecycleManager.demote` flips a row from
/// `active → demoted`. Idempotent re-demotes and demotes against
/// unknown / already-non-active ids emit nothing (see file header).
///
/// Carries enough context to reconstruct the lifecycle transition
/// without re-reading SQLite: the affected node id, its registered
/// type name (resolved at the moment of demotion so a later type
/// unregistration cannot poison the audit), and the categorical
/// reason supplied by the caller.
///
/// `runId` / `causedBy` are absent on this leaf — the abstract
/// `TomBrainMemory.demote` signature does not carry a `Scope`, so
/// there is no producer-supplied trace correlation to thread
/// through. The future `Reconsolidator` agent (memory_specification
/// § 9.4) that will re-promote demoted rows will pick the affected
/// node up via the node id alone.
final class NodeDemoted extends MemoryEvent {
  /// Stable id of the demoted node.
  final NodeId nodeId;

  /// Canonical type name resolved from the live row at the moment of
  /// the transition. Always names a type that was registered when
  /// `demote` was called.
  final String typeName;

  /// Categorical reason supplied to `demote`.
  final DemotionReason reason;

  const NodeDemoted({
    required this.nodeId,
    required this.typeName,
    required this.reason,
    required super.occurredAt,
  });

  @override
  String get kind => 'memory.node-demoted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'nodeId': nodeId.toString(),
        'typeName': typeName,
        'reason': reason.name,
      };
}

/// Emitted when `NodeLifecycleManager.forget` commits a Tombstone
/// and removes the live row. Forgets against unknown / already-
/// forgotten ids emit nothing (see file header).
///
/// Mirrors the columns of the new `tombstones_index` row that the
/// same transaction wrote: subscribers can reconstruct the deletion
/// audit (who was forgotten, what type were they, which Tombstone
/// records it, and why) without re-querying `tombstones_index`.
///
/// `runId` / `causedBy` are absent for the same reason as
/// [NodeDemoted].
final class NodeForgotten extends MemoryEvent {
  /// Id of the node whose live row was deleted. The id is the same
  /// one the caller passed to `forget`; downstream subscribers cannot
  /// fetch the original row any more (it is gone) — they must work
  /// from this event plus the Tombstone.
  final NodeId forgottenNodeId;

  /// Id of the freshly-written Tombstone node. The Tombstone is
  /// reachable by `NodeReader.get(tombstoneNodeId)` and carries the
  /// `reason` and `forgotten_at` attributes.
  final NodeId tombstoneNodeId;

  /// The type name of the forgotten node at the moment of deletion.
  /// Preserved here (and in `tombstones_index.forgotten_type`) so
  /// audit consumers can filter by original type without joining
  /// across a now-absent row.
  final String forgottenType;

  /// Categorical reason supplied to `forget`.
  final ForgetReason reason;

  const NodeForgotten({
    required this.forgottenNodeId,
    required this.tombstoneNodeId,
    required this.forgottenType,
    required this.reason,
    required super.occurredAt,
  });

  @override
  String get kind => 'memory.node-forgotten';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'forgottenNodeId': forgottenNodeId.toString(),
        'tombstoneNodeId': tombstoneNodeId.toString(),
        'forgottenType': forgottenType,
        'reason': reason.name,
      };
}
