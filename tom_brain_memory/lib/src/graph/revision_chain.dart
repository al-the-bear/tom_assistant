// The `superseded_by` revision-chain walk — one graph primitive shared by the
// procedure and planning subsystems (`procedure_specification.md` § 7.2,
// `planning_specification.md` § 7.4, hard principle 6).
//
// A `superseded_by` edge points from a superseded node to the revision that
// replaced it (`old → new`). Both subsystems revise structurally and never
// delete (hard principle 6), so reading "the whole history of this thing" is a
// chain walk: backward along incoming edges to the root, forward along outgoing
// edges to the live tip. `ProcedureRevisionChain` and `SupersededHistoryOf`
// both need exactly this walk over `Procedure` / `Plan` nodes respectively —
// the only difference is the typed view each projects at the end. So the walk
// lives here, domain-free (it returns raw `Node`s), and each typed query maps
// the result into its own view.

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Walks the `superseded_by` chain [anchor] belongs to and returns every node
/// in it, ordered oldest → newest (the live tip last).
///
/// The walk follows incoming `superseded_by` edges backward to the chain root
/// and outgoing edges forward to the tip; a `seen` set guards against a
/// malformed cycle so the walk always terminates. Returns an empty list when
/// [anchor] does not resolve to a live node. A node has at most one predecessor
/// and one successor in a linear chain; if storage somehow holds more, the
/// first edge is taken — a fork is an upstream bug, not something this read
/// masks.
Future<List<Node>> walkSupersededByChain(
  TomBrainMemoryClient client,
  NodeId anchor,
) async {
  final anchorNode = await client.get(anchor);
  if (anchorNode == null) return const <Node>[];

  final seen = <NodeId>{anchor};

  // Backward to the root: incoming `superseded_by` edges (predecessor → this).
  final older = <NodeId>[];
  var cursor = anchor;
  while (true) {
    final predecessor = await _step(
      client,
      cursor,
      EdgeDirection.incoming,
      pick: (edge) => edge.from,
    );
    if (predecessor == null || !seen.add(predecessor)) break;
    older.add(predecessor);
    cursor = predecessor;
  }

  // Forward to the tip: outgoing `superseded_by` edges (this → successor).
  final newer = <NodeId>[];
  cursor = anchor;
  while (true) {
    final successor = await _step(
      client,
      cursor,
      EdgeDirection.outgoing,
      pick: (edge) => edge.to,
    );
    if (successor == null || !seen.add(successor)) break;
    newer.add(successor);
    cursor = successor;
  }

  final ordered = <NodeId>[...older.reversed, anchor, ...newer];
  final nodes = await client.getMany(ordered);
  // `getMany` elides missing ids and is not order-guaranteed against an
  // arbitrary id list across implementations; re-project in chain order.
  final byId = <NodeId, Node>{for (final n in nodes) n.id: n};
  return <Node>[
    for (final id in ordered)
      if (byId[id] != null) byId[id]!,
  ];
}

/// Returns the single chain neighbour of [from] in [direction], or `null` when
/// there is none.
Future<NodeId?> _step(
  TomBrainMemoryClient client,
  NodeId from,
  EdgeDirection direction, {
  required NodeId Function(Edge edge) pick,
}) async {
  final edges = await client.edgesOf(
    from,
    direction: direction,
    types: const <EdgeType>{EdgeType.supersededBy},
  );
  if (edges.isEmpty) return null;
  return pick(edges.first);
}
