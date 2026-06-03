// EdgeWriteException — sealed failure family for
// `EdgeWriter.edge` (Plan step A.36).
//
// Every refusal path the writer can take throws a typed subclass so
// callers (procedure scripts, dreaming agents) can branch on the
// cause without parsing prose. The base class is sealed: adding a
// new failure category is a deliberate breaking change in this
// layer.
//
// Categories, in the order the writer checks them:
//
//   1. `EdgeEndpointMissing`   — `from` or `to` node id has no live
//                                row in `nodes`. Either it was never
//                                persisted, was `forget`ten, or the
//                                caller mistyped the id. The
//                                exception carries which side failed
//                                so the caller can target the
//                                lookup.
//   2. `EdgeNotPermitted`      — the edge label is not in the
//                                `allowedOutgoing` set of the
//                                from-type, or not in the
//                                `allowedIncoming` set of the
//                                to-type. The exception names which
//                                side rejected and the type-decl
//                                involved so the caller can either
//                                pick a different edge label or
//                                propose a `NodeTypeDecl` evolution
//                                via `propose_node_type_v1`.
//   3. `UnknownNodeTypeForEdge`— the from or to endpoint references a
//                                node whose `type_name` is no longer
//                                registered. This is a memory-DB
//                                integrity tripwire (a registered
//                                type was unregistered while a node
//                                of that type still lived). Never
//                                expected in normal operation; if it
//                                fires, the brain has a real bug.
//
// Per the quest's hard principles, none of these errors are
// recoverable inside memory — the caller decides whether to retry
// with different endpoints, surface to the user, or abandon the
// write.

import 'package:tom_core_agentic/tom_core_agentic.dart' show formatException;
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import 'edge_type.dart';

/// Sealed base for every refusal of `EdgeWriter.edge`.
sealed class EdgeWriteException implements Exception {
  /// Source endpoint the caller proposed.
  final NodeId from;

  /// Edge label the caller proposed.
  final EdgeType type;

  /// Destination endpoint the caller proposed.
  final NodeId to;

  /// Human-readable explanation. Always names the proposed shape.
  final String message;

  const EdgeWriteException({
    required this.from,
    required this.type,
    required this.to,
    required this.message,
  });

  /// Categorical reason — mirrored on `EdgeRejected` so callers and
  /// observers see the same taxonomy.
  EdgeRejectionReason get reason;

  @override
  String toString() => formatException(
        this,
        message,
        context: '$from --${type.wireName}--> $to',
      );
}

/// `from` or `to` node id does not name a live node.
final class EdgeEndpointMissing extends EdgeWriteException {
  /// Which endpoint failed lookup.
  final EdgeEndpointSide side;

  const EdgeEndpointMissing({
    required super.from,
    required super.type,
    required super.to,
    required super.message,
    required this.side,
  });

  @override
  EdgeRejectionReason get reason => switch (side) {
        EdgeEndpointSide.from => EdgeRejectionReason.fromEndpointMissing,
        EdgeEndpointSide.to => EdgeRejectionReason.toEndpointMissing,
      };
}

/// The proposed edge label is forbidden by the type-permission
/// table.
final class EdgeNotPermitted extends EdgeWriteException {
  /// Which side rejected — `from`'s `allowedOutgoing` or `to`'s
  /// `allowedIncoming`.
  final EdgeEndpointSide side;

  /// Type name of the rejecting endpoint at the moment of refusal.
  final String rejectingTypeName;

  const EdgeNotPermitted({
    required super.from,
    required super.type,
    required super.to,
    required super.message,
    required this.side,
    required this.rejectingTypeName,
  });

  @override
  EdgeRejectionReason get reason => switch (side) {
        EdgeEndpointSide.from => EdgeRejectionReason.notInAllowedOutgoing,
        EdgeEndpointSide.to => EdgeRejectionReason.notInAllowedIncoming,
      };
}

/// An endpoint references a node whose `type_name` is not in the
/// `NodeTypeRegistry`. A memory-DB integrity tripwire — never
/// expected in normal operation.
final class UnknownNodeTypeForEdge extends EdgeWriteException {
  /// Which endpoint had the unknown type.
  final EdgeEndpointSide side;

  /// The unregistered type name found on the endpoint row.
  final String unknownTypeName;

  const UnknownNodeTypeForEdge({
    required super.from,
    required super.type,
    required super.to,
    required super.message,
    required this.side,
    required this.unknownTypeName,
  });

  @override
  EdgeRejectionReason get reason => switch (side) {
        EdgeEndpointSide.from =>
          EdgeRejectionReason.fromEndpointTypeUnregistered,
        EdgeEndpointSide.to =>
          EdgeRejectionReason.toEndpointTypeUnregistered,
      };
}

/// Which endpoint of a proposed edge triggered a refusal.
enum EdgeEndpointSide {
  /// The `from` (source) endpoint.
  from,

  /// The `to` (destination) endpoint.
  to,
}

/// Categorical refusal reason — surfaced on both `EdgeRejected`
/// events and `EdgeWriteException.reason`.
///
/// Granularity is "side + cause" so observers can index rejections
/// without re-decoding the prose message.
enum EdgeRejectionReason {
  /// `from` endpoint has no live row.
  fromEndpointMissing,

  /// `to` endpoint has no live row.
  toEndpointMissing,

  /// Edge label is not in the from-type's `allowedOutgoing`.
  notInAllowedOutgoing,

  /// Edge label is not in the to-type's `allowedIncoming`.
  notInAllowedIncoming,

  /// `from` endpoint's `type_name` is not registered.
  fromEndpointTypeUnregistered,

  /// `to` endpoint's `type_name` is not registered.
  toEndpointTypeUnregistered,
}
