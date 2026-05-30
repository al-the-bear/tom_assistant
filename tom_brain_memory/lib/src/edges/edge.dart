// Edge — read-side record of a typed connection between two nodes.
//
// Storage shape lives in `memory.db.edges` (one row per edge); see
// `memory_specification.md` § 2.1 and § 4.2. The `Edge` value here is
// the materialised form returned by `TomBrainMemory.edgesOf` and by
// graph-walk recall.

import 'package:tom_brain_shared/tom_brain_shared.dart' show EdgeId, NodeId;

import 'edge_type.dart';

/// Immutable read-side record of a graph edge.
///
/// Equality is structural. Two `Edge` values are equal iff every field
/// matches — the [id] alone would suffice in practice, but defining
/// equality structurally keeps tests honest when an edge is rebuilt
/// from JSON without an id.
final class Edge {
  /// Stable identifier minted at insert time.
  final EdgeId id;

  /// Source endpoint.
  final NodeId from;

  /// Edge label from the closed 12-edge alphabet.
  final EdgeType type;

  /// Destination endpoint.
  final NodeId to;

  /// Optional weight. Defaults to 1.0 on insert. Used by graph-walk
  /// scoring (§ 6.1) and by the connector's "stronger evidence wins"
  /// fold during consolidation.
  final double weight;

  /// Optional attribute bag (per-edge metadata). Most edges have
  /// none; `part_of` may carry `{'kind': 'depends_on'}` when used
  /// for plan-step dependency shapes (§ 4.1 `PlanStep`).
  ///
  /// The map is held by reference. Consumers MUST treat it as
  /// read-only; mutating it would silently change a value that other
  /// readers hold.
  final Map<String, Object?> attrs;

  const Edge({
    required this.id,
    required this.from,
    required this.type,
    required this.to,
    this.weight = 1.0,
    this.attrs = const <String, Object?>{},
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Edge) return false;
    return other.id == id &&
        other.from == from &&
        other.type == type &&
        other.to == to &&
        other.weight == weight &&
        _mapEquals(other.attrs, attrs);
  }

  @override
  int get hashCode => Object.hash(id, from, type, to, weight, attrs.length);

  @override
  String toString() => 'Edge(id: $id, ${from.toString()} '
      '--${type.wireName}--> ${to.toString()}, '
      'weight: $weight${attrs.isEmpty ? '' : ', attrs: $attrs'})';
}

bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
