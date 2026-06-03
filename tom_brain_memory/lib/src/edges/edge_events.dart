// Edge `MemoryEvent` leaves — `EdgeCreated` (successful insert) and
// `EdgeRejected` (validation refusal). Both are emitted by
// `EdgeWriter.edge` per `memory_specification.md` § 16.
//
// Plan step A.36 owns these. The persister's success-only convention
// (`NodePersisted` emitted on commit; no `NodeRejected`) is
// deliberately **not** mirrored on the edge path: spec § 16 names
// `EdgeRejected` as a distinct event leaf, and the brain's
// autonomous edge-proposers (dreaming agents, plan re-planners)
// need an observable record when their proposals are refused so
// operators and downstream `Pruner` agents can react. The asymmetry
// is intentional and is tracked as **Q-A.36.1** for revisit during
// the operator-UI step.
//
// The discriminators (`memory.edge-created`, `memory.edge-rejected`)
// follow the per-component convention documented on `MemoryEvent`.

import 'package:tom_brain_shared/tom_brain_shared.dart' show EdgeId, EdgeType, MemoryEvent, NodeId;

import 'edge_write_exception.dart';

/// Emitted when `EdgeWriter.edge` successfully commits a fresh edge.
///
/// Carries enough context to reconstruct the insert without reading
/// `edges`: the new edge id, its endpoints, the edge label, the
/// resolved endpoint type names (so an operator can see, at a glance,
/// "Claim --evidenceFor--> Conclusion" without two extra lookups),
/// the weight, and the attribute bag.
///
/// The attribute bag is held by reference; consumers MUST treat it
/// as read-only.
final class EdgeCreated extends MemoryEvent {
  /// Stable id assigned to the new edge.
  final EdgeId edgeId;

  /// Source endpoint.
  final NodeId from;

  /// Edge label from the closed 12-edge alphabet.
  final EdgeType type;

  /// Destination endpoint.
  final NodeId to;

  /// Type name of the source endpoint at the moment of insert. Cached
  /// here so observability never has to re-fetch the row.
  final String fromTypeName;

  /// Type name of the destination endpoint at the moment of insert.
  final String toTypeName;

  /// Edge weight (defaults to 1.0 on the writer side).
  final double weight;

  /// Per-edge attribute bag. Empty when the caller supplied no
  /// `attrs`.
  final Map<String, Object?> attrs;

  EdgeCreated({
    required this.edgeId,
    required this.from,
    required this.type,
    required this.to,
    required this.fromTypeName,
    required this.toTypeName,
    required this.weight,
    required Map<String, Object?> attrs,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  }) : attrs = Map<String, Object?>.unmodifiable(attrs);

  @override
  String get kind => 'memory.edge-created';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'edgeId': edgeId.toString(),
        'from': from.toString(),
        'to': to.toString(),
        'type': type.wireName,
        'fromTypeName': fromTypeName,
        'toTypeName': toTypeName,
        'weight': weight,
        if (attrs.isNotEmpty) 'attrs': attrs,
      };
}

/// Emitted when `EdgeWriter.edge` refuses to insert.
///
/// The same call also throws an `EdgeWriteException` subclass; the
/// event is for observability (operator UI, agent-side proposal
/// telemetry). The thrown exception is the caller-side contract;
/// the event is the brain-wide audit trail.
///
/// Carries the proposed shape plus the categorical reason. The
/// resolved endpoint type names are included **when known** —
/// `null` when the rejection was triggered by a missing endpoint
/// (the writer cannot name a type for a node that does not exist).
final class EdgeRejected extends MemoryEvent {
  /// Source endpoint of the proposed edge.
  final NodeId from;

  /// Proposed edge label.
  final EdgeType type;

  /// Destination endpoint of the proposed edge.
  final NodeId to;

  /// Categorical refusal reason — matches the `EdgeWriteException`
  /// subclass that was thrown.
  final EdgeRejectionReason reason;

  /// Source endpoint's type name when known. `null` when the
  /// rejection was [EdgeRejectionReason.fromEndpointMissing].
  final String? fromTypeName;

  /// Destination endpoint's type name when known. `null` when the
  /// rejection was [EdgeRejectionReason.toEndpointMissing] (and
  /// also when the from-endpoint check already failed and the
  /// writer short-circuited).
  final String? toTypeName;

  /// Human-readable reason, mirroring the thrown exception's
  /// `message`.
  final String message;

  const EdgeRejected({
    required this.from,
    required this.type,
    required this.to,
    required this.reason,
    required this.message,
    required super.occurredAt,
    this.fromTypeName,
    this.toTypeName,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.edge-rejected';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'from': from.toString(),
        'to': to.toString(),
        'type': type.wireName,
        'reason': reason.name,
        'message': message,
        if (fromTypeName != null) 'fromTypeName': fromTypeName,
        if (toTypeName != null) 'toTypeName': toTypeName,
      };
}
