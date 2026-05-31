// NodeTypeRegistered — the `MemoryEvent` leaf emitted by
// `NodeTypeRegistry.registerNodeType` on a successful commit
// (Plan step A.33).
//
// Plan step A.38 will land the rest of the `MemoryEvent` leaves
// (`NodePersisted`, `NodeDemoted`, `NodeForgotten`, `EdgeCreated`,
// `EdgeRejected`). A.33 emits the one event it produces and stops —
// other leaves will appear next to the operations that emit them, in
// the steps that own those operations.
//
// The discriminator (`memory.node-type-registered`) follows the
// per-component convention documented on `MemoryEvent`.

import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../api/memory_event.dart';

/// Emitted when `NodeTypeRegistry.registerNodeType` successfully
/// commits a `NodeTypeDecl`.
///
/// Carries enough context to reconstruct the registry transition
/// without reading SQLite: the new decl-node id, the type name,
/// whether the registration superseded a prior decl (and which one),
/// the resulting version, and the approval note that came back from
/// the critique hook (if any).
final class NodeTypeRegistered extends MemoryEvent {
  /// Canonical name of the registered type.
  final String typeName;

  /// Decl-node id assigned to this `NodeTypeDecl`. The same id is
  /// stamped into `node_types.decl_node_id` and into the canonical
  /// `NodeType` node in `nodes` (A.34+ wires that materialisation).
  final NodeId declNodeId;

  /// Resulting version (a positive int; the registry guarantees
  /// monotonicity vs the predecessor, when one exists).
  final int version;

  /// Predecessor decl-node id, when this registration superseded a
  /// prior version of the same type. `null` for a fresh type.
  final NodeId? supersedes;

  /// Note returned by the critique hook on approval. `null` when the
  /// hook approved without comment.
  final String? critiqueNote;

  const NodeTypeRegistered({
    required this.typeName,
    required this.declNodeId,
    required this.version,
    this.supersedes,
    this.critiqueNote,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.node-type-registered';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'typeName': typeName,
        'declNodeId': declNodeId.toString(),
        'version': version,
        if (supersedes != null) 'supersedes': supersedes.toString(),
        if (critiqueNote != null) 'critiqueNote': critiqueNote,
      };
}
