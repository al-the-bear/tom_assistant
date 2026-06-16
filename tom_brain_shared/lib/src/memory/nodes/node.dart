// Node + NodeDraft — write-side input and read-side output for the
// memory graph (memory_specification.md § 3.1, § 4.1).
//
// `NodeDraft` is what callers hand to `TomBrainMemory.persist`. It
// carries the type name, the field values, an optional embedding,
// and the `Scope` (idempotency + provenance) is supplied as a
// separate named arg.
//
// `Node` is what `get` / `getMany` / `stream` return. It carries the
// concrete id, the type name, the value map (frozen), the optional
// embedding, the creation / mutation / last-access timestamps, the
// access count (§ 6.6), and the lifecycle status.

import 'package:tom_core_agentic/tom_core_agentic.dart' show mapEquals;

import '../../embedding/embedding.dart' show Vec;
import '../../ids/ids.dart' show NodeId;

/// Lifecycle status of a stored node.
///
/// `active` is the steady state. `demoted` and `archived` are still
/// readable by id; they just no longer surface in retrieval. `forgotten`
/// indicates an explicit user-driven deletion that left a `Tombstone`
/// behind (the row is then gone from the live table; the Tombstone is
/// the only record).
enum NodeStatus {
  active,
  demoted,
  archived,
  forgotten,
}

/// Write-side payload for a candidate node.
///
/// Equality is structural (used heavily in tests and for the
/// idempotent persist contract: a re-persist with the same values
/// and the same `Scope.idempotencyKey` is a no-op).
final class NodeDraft {
  /// Canonical type name — must match a registered `NodeTypeDecl`.
  final String typeName;

  /// Field values keyed by field name. Allowed value shapes match
  /// the `FieldSpec.type` enum (string, int, bool, double for vecs
  /// pre-pack, nested map for json).
  final Map<String, Object?> values;

  /// Pre-computed embedding, when the caller already produced it
  /// (avoids a second substrate call from inside memory). Memory
  /// validates it against the type's `EmbeddingPolicy.dimensions`.
  final Vec? embedding;

  const NodeDraft({
    required this.typeName,
    required this.values,
    this.embedding,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! NodeDraft) return false;
    return other.typeName == typeName &&
        other.embedding == embedding &&
        mapEquals(other.values, values);
  }

  @override
  int get hashCode => Object.hash(typeName, embedding, values.length);

  @override
  String toString() =>
      'NodeDraft(type: $typeName, fields: ${values.keys.toList()})';
}

/// Read-side materialised node.
final class Node {
  /// Stable identifier. Minted at first `persist`; survives
  /// supersession (`supersededBy` edges point to a *different* id).
  final NodeId id;

  /// Type name — same key as `NodeTypeDecl.typeName`.
  final String typeName;

  /// Field values keyed by field name. Read-only — callers MUST NOT
  /// mutate.
  final Map<String, Object?> values;

  /// Stored embedding, if the type carries one.
  final Vec? embedding;

  /// Creation timestamp (UTC).
  final DateTime createdAt;

  /// Last-mutation timestamp (UTC). Bumped by lifecycle transitions
  /// (e.g. `demote`) and supersession; equals [createdAt] for a node
  /// that has never been mutated since it was first persisted.
  final DateTime updatedAt;

  /// Last-access timestamp (UTC) — when this node was most recently
  /// surfaced by a recall that counts as an access (§ 6.6). A node
  /// that has never been accessed reports its [createdAt]: an
  /// un-accessed node's "last access" is its creation, so recency
  /// scoring measures age-since-creation until the first real access.
  final DateTime lastAccess;

  /// Number of times this node has been surfaced by an
  /// access-counting recall (§ 6.6). Zero for a node that has never
  /// been accessed.
  final int accessCount;

  /// Lifecycle status.
  final NodeStatus status;

  Node({
    required this.id,
    required this.typeName,
    required Map<String, Object?> values,
    required this.createdAt,
    DateTime? updatedAt,
    DateTime? lastAccess,
    this.accessCount = 0,
    this.embedding,
    this.status = NodeStatus.active,
  })  : values = Map<String, Object?>.unmodifiable(values),
        updatedAt = updatedAt ?? createdAt,
        lastAccess = lastAccess ?? createdAt;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Node) return false;
    return other.id == id &&
        other.typeName == typeName &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt &&
        other.lastAccess == lastAccess &&
        other.accessCount == accessCount &&
        other.status == status &&
        other.embedding == embedding &&
        mapEquals(other.values, values);
  }

  @override
  int get hashCode => Object.hash(
        id,
        typeName,
        createdAt,
        updatedAt,
        lastAccess,
        accessCount,
        status,
        embedding,
        values.length,
      );

  @override
  String toString() =>
      'Node(id: $id, type: $typeName, status: ${status.name})';
}
