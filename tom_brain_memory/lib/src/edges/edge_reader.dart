// EdgeReader — the in-process owner of the edge-read path
// (`edgesOf`) for `SqliteTomBrainMemory` (Plan step A.37).
//
// What this file owns:
//
//   - `edgesOf(NodeId, {direction, types})` — single SELECT against
//     `memory.db.edges`, decoded into `List<Edge>` in a deterministic
//     order.
//
// What this file does NOT own:
//
//   - Endpoint validation. `edgesOf` of an id that names no live node
//     returns `[]`; it does not throw. Graph walks naturally tolerate
//     dangling refs (a forgotten node leaves its in-going edges
//     reachable only by id; the agents that traverse those edges are
//     responsible for resolving the dangling case). The deliberate
//     non-symmetry with `EdgeWriter` (which does require live
//     endpoints on write) is documented in **Q-A.37.1**.
//
//   - Pagination / streaming. The caller currently always wants every
//     edge touching a single node. The largest realistic fan-out at
//     v1 is a Plan node with O(100) PlanStep children plus their
//     `depends_on` edges, which is comfortably small enough to
//     materialise. A future graph-walk mode (A.61) will need
//     cursor-backed iteration; tracked as **Q-A.37.4**.
//
//   - `produced_by` rehydration. The column exists on `edges` (set
//     by `EdgeWriter` once Scope flows through; tracked as
//     Q-A.36.2), but `Edge` does not currently carry the field. When
//     that lands, the SELECT here gains the column and the row →
//     Edge decoder is extended in a single change. Tracked as
//     **Q-A.37.5**.
//
// Layering:
//
//   - The reader takes a raw `sqlite3` `Database` handle and reads
//     `memory.db` only. It does NOT own the handle.
//
//   - The reader is stateless across calls; multiple readers over
//     the same handle is supported but pointless — share one.
//
// Filter semantics (the contract A.37 promises):
//
//   * `direction = both` (default) — every edge where the node is
//     `from` OR `to`. A self-loop (`from == to == id`) returns the
//     edge once: SQLite's `WHERE from = ? OR to = ?` matches the
//     single row once.
//
//   * `direction = outgoing` — only `from_node = id`.
//
//   * `direction = incoming` — only `to_node = id`.
//
//   * `types = null` (default) — every edge label.
//
//   * `types = <Set>{}` (empty set) — match nothing, return `[]`
//     without touching SQLite. This treats the empty set as the
//     literal "no labels accepted" filter; passing `null` is the
//     way to mean "no filter". The asymmetry is intentional —
//     callers who computed a set of allowed labels and ended up with
//     none want the empty list, not every edge. Tracked as
//     **Q-A.37.2**.
//
//   * `types = <Set>{a, b}` — `AND type IN ('a_wire', 'b_wire')`.
//     Wire-name expansion happens here; callers do not need to know
//     the column format.
//
// Ordering (the contract A.37 promises):
//
//   * Results are ordered by `created_at_ms ASC, id ASC`. That makes
//     output deterministic across calls without depending on
//     SQLite's row-id ordering, which is an implementation detail
//     of the table layout. Tracked as **Q-A.37.3**.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show decodeJsonObject, sqlPlaceholders;
import 'package:tom_brain_shared/tom_brain_shared.dart' show EdgeId, NodeId;

import 'edge.dart';
import 'edge_type.dart';

/// In-process owner of the edge-read path.
///
/// One `EdgeReader` per open memory store; constructed by the store
/// opener and handed to the higher-level `SqliteTomBrainMemory` once
/// that class lands.
final class EdgeReader {
  /// Live SQLite handle on `memory.db`. Owned by the store; the
  /// reader does NOT close it.
  final Database _db;

  /// Constructs the reader around an already-opened, already-
  /// migrated `memory.db` handle.
  EdgeReader({required Database memoryDb}) : _db = memoryDb;

  // ─── Public surface ──────────────────────────────────────────────

  /// Returns every edge touching [id], filtered by [direction] and
  /// (optionally) [types].
  ///
  /// Contract — see file header for the full semantics. Summary:
  ///
  ///   * Default `direction = both` returns edges where [id] is the
  ///     `from` OR `to` endpoint; self-loops appear once.
  ///   * `types = null` matches every label; `types = <Set>{}`
  ///     returns `[]` without touching SQLite; a non-empty set
  ///     filters to the listed labels (wire-name expansion happens
  ///     internally).
  ///   * Ordering is `created_at_ms ASC, id ASC` — deterministic
  ///     across calls.
  ///   * Querying an id that names no live node returns `[]`
  ///     (no throw); the writer enforces live endpoints, the reader
  ///     tolerates dangling refs. See Q-A.37.1.
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    // Explicit-empty-set filter short-circuits without touching the
    // database. Treating `<Set>{}` as "no labels match" (vs.
    // `null` = "no filter") matches the principle that callers
    // who computed a permitted-labels set and ended up empty want
    // an empty result, not the full graph.
    if (types != null && types.isEmpty) {
      return const <Edge>[];
    }

    final idStr = id.toString();

    // Build the WHERE clause for direction. Composite indexes
    // `idx_edges_from_type` / `idx_edges_to_type` from schema-v1
    // make both legs cheap.
    final String whereDir;
    final List<Object?> params;
    switch (direction) {
      case EdgeDirection.outgoing:
        whereDir = 'from_node = ?';
        params = <Object?>[idStr];
        break;
      case EdgeDirection.incoming:
        whereDir = 'to_node = ?';
        params = <Object?>[idStr];
        break;
      case EdgeDirection.both:
        whereDir = '(from_node = ? OR to_node = ?)';
        params = <Object?>[idStr, idStr];
        break;
    }

    // Optional types filter. Non-null and non-empty by the
    // short-circuit above.
    String whereTypes = '';
    if (types != null) {
      final placeholders = sqlPlaceholders(types.length);
      whereTypes = ' AND type IN ($placeholders)';
      params.addAll(types.map((t) => t.wireName));
    }

    final rows = _db.select(
      'SELECT id, from_node, to_node, type, weight, attrs_json '
      'FROM edges '
      'WHERE $whereDir$whereTypes '
      'ORDER BY created_at_ms ASC, id ASC',
      params,
    );

    return rows.map(_rowToEdge).toList(growable: false);
  }

  // ─── Internal: row → Edge decoder ────────────────────────────────

  Edge _rowToEdge(Row row) {
    final id = EdgeId.fromString(row['id'] as String);
    final from = NodeId.fromString(row['from_node'] as String);
    final to = NodeId.fromString(row['to_node'] as String);
    final type = EdgeType.fromWireName(row['type'] as String);
    final weight = (row['weight'] as num).toDouble();
    final attrsJson = row['attrs_json'] as String?;

    return Edge(
      id: id,
      from: from,
      type: type,
      to: to,
      weight: weight,
      // A NULL column → empty map (mirrors the writer's convention of
      // writing NULL for an empty attrs payload). A non-object payload
      // throws a context-tagged StateError — that would indicate a
      // `memory.db` integrity failure, not a normal read path.
      attrs: decodeJsonObject(attrsJson, context: 'edges.attrs_json'),
    );
  }
}
