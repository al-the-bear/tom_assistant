// NodeReader — the in-process owner of the node-read path (`get`,
// `getMany`) for `SqliteTomBrainMemory`.
//
// Plan step A.35:
//   "Implement `get`, `getMany`, `demote`, `forget` (Tombstone
//    path)."
//
// What this file owns:
//
//   - `get(NodeId)` — single-row SELECT against `memory.db.nodes`,
//     decoded into a `Node` with the lifecycle `status` preserved.
//   - `getMany(List<NodeId>)` — bulk SELECT with `WHERE id IN (…)`
//     that returns the nodes in *input order* with missing ids
//     elided (no `null` placeholders).
//
// What this file does NOT own:
//
//   - Vector readback. Embeddings live in `vectors.db` (A.50+) and
//     are not yet wired in at A.35. Every `Node` returned here has
//     `embedding == null` regardless of whether the underlying type
//     carries one. The gap is tracked as **Q-A.35.1** so the read
//     side acquires the vector once the vectors-store reader lands.
//
//   - Per-type Vec rehydration. `NodePersister._valuesToJson`
//     converts `Vec` fields to JSON `List<double>` on write. At
//     A.35 no bootstrap type declares a `vec` *field* (the
//     `bootstrap_node_types.yaml` matrix uses `vector_fields` in
//     `IndexPolicy` only, never `FieldType.vec`), so the symmetric
//     decode path is a no-op for every currently-registered type.
//     The placeholder is documented as **Q-A.35.2** to wire the
//     registry-driven decoder when the first `vec`-bearing type
//     ships.
//
//   - Tombstoned ids. A `forget` writes a `Tombstone` node and
//     removes the live row. After that, `get(forgottenId)` returns
//     `null` here — the row is genuinely absent. The reachable
//     `Tombstone` node has its own (different) `NodeId`, retrieved
//     via the `tombstones_index` lookup the future operator UI
//     surfaces.
//
// Layering:
//
//   - The reader takes a raw `sqlite3` `Database` handle and reads
//     `memory.db` only. It does NOT own the handle; the higher-level
//     store opener constructs the reader with the same handle the
//     persister/lifecycle-manager share.
//
//   - The reader is stateless across calls; the per-instance fields
//     (the handle) are immutable. Multiple readers over the same
//     handle is supported but pointless — share one.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show decodeJsonObject, sqlPlaceholders;
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import 'node.dart';

/// Reads `id → type_name` for [idStrs] in a single SELECT against
/// `nodes`. Ids that no longer exist (forgotten, never persisted,
/// dangling edge endpoints) are absent from the result; empty input
/// short-circuits without touching SQLite.
///
/// Shared by the vector and graph-walk recall executors, which both
/// resolve a batch of discovered node-id strings to their type names.
/// Homed next to [NodeReader] so the `nodes` read path stays in one
/// module (review D.2.6).
Map<String, String> readNodeTypeNames(Database db, Iterable<String> idStrs) {
  final list =
      idStrs is List<String> ? idStrs : idStrs.toList(growable: false);
  if (list.isEmpty) return const <String, String>{};
  final placeholders = sqlPlaceholders(list.length);
  final rows = db.select(
    'SELECT id, type_name FROM nodes WHERE id IN ($placeholders)',
    list,
  );
  final result = <String, String>{};
  for (final row in rows) {
    result[row['id'] as String] = row['type_name'] as String;
  }
  return result;
}

/// In-process owner of the node-read path.
///
/// One `NodeReader` per open memory store; constructed by the store
/// opener and handed to the higher-level `SqliteTomBrainMemory`
/// once that class lands later in Phase A.
final class NodeReader {
  /// Live SQLite handle on `memory.db`. Owned by the store.
  final Database _db;

  /// Constructs the reader around an already-opened, already-
  /// migrated `memory.db` handle.
  NodeReader({required Database memoryDb}) : _db = memoryDb;

  // ─── Public surface ────────────────────────────────────────────

  /// Returns the live node for [id], or `null` when no row exists.
  ///
  /// "No row exists" covers three cases that callers do not need to
  /// distinguish at this layer:
  ///
  ///   * The id was never persisted.
  ///   * The id was persisted and later `forget`ten — the live row
  ///     was deleted and a separate `Tombstone` node carries the
  ///     audit record.
  ///   * The id is malformed in the storage layer (extremely rare;
  ///     would indicate a `memory.db` integrity failure).
  ///
  /// Demoted and archived nodes return normally with `status`
  /// reflecting the lifecycle (`NodeStatus.demoted` /
  /// `NodeStatus.archived`).
  ///
  /// Per the file header: `embedding` is always `null` at A.35; the
  /// vectors-store read lands at A.50+.
  Future<Node?> get(NodeId id) async {
    final rows = _db.select(
      'SELECT id, type_name, attrs_json, status, '
      'created_at_ms FROM nodes WHERE id = ? LIMIT 1',
      <Object?>[id.toString()],
    );
    if (rows.isEmpty) return null;
    return _rowToNode(rows.first);
  }

  /// Returns the live nodes for [ids] in input order.
  ///
  /// Missing ids — never persisted, already forgotten, malformed —
  /// are elided. The returned list length is `<=` the input length;
  /// callers that need a "found vs missing" breakdown should diff
  /// the input set against the returned ids.
  ///
  /// Empty input → empty output without touching SQLite. Duplicate
  /// ids in the input are returned once each (the SELECT
  /// deduplicates by primary key); the *order* of the first
  /// occurrence is preserved.
  ///
  /// Implementation note: a single `WHERE id IN (?, …)` query plus
  /// an in-memory re-order is N+1-free and avoids serialising a
  /// huge VALUES list. The reader does not paginate — callers that
  /// hand in millions of ids should use `stream()` (A.38+) instead.
  Future<List<Node>> getMany(List<NodeId> ids) async {
    if (ids.isEmpty) return const <Node>[];

    // De-duplicate while preserving first-occurrence order, since
    // we want the output to follow the input order but a duplicate
    // id reads only once from SQLite.
    final seen = <String>{};
    final orderedKeys = <String>[];
    for (final id in ids) {
      final key = id.toString();
      if (seen.add(key)) {
        orderedKeys.add(key);
      }
    }

    final placeholders = sqlPlaceholders(orderedKeys.length);
    final rows = _db.select(
      'SELECT id, type_name, attrs_json, status, '
      'created_at_ms FROM nodes WHERE id IN ($placeholders)',
      <Object?>[...orderedKeys],
    );

    // Map id → Node so we can re-order without an O(n*m) scan.
    final byId = <String, Node>{
      for (final row in rows) row['id'] as String: _rowToNode(row),
    };

    final out = <Node>[];
    for (final key in orderedKeys) {
      final node = byId[key];
      if (node != null) out.add(node);
    }
    return out;
  }

  // ─── Internal: row → Node decoder ──────────────────────────────

  Node _rowToNode(Row row) {
    final id = NodeId.fromString(row['id'] as String);
    final typeName = row['type_name'] as String;
    final attrsJson = row['attrs_json'] as String;
    final statusName = row['status'] as String;
    final createdAtMs = row['created_at_ms'] as int;

    // At A.35 this is a thin defensive decode. No type-driven
    // rehydration happens — see file header **Q-A.35.2**. A future
    // step will pass the `NodeTypeDecl.schema` here so `vec` fields
    // (stored as `List<double>` on the wire) become `Vec` again.
    final values = decodeJsonObject(attrsJson, context: 'attrs_json');
    final status = _decodeStatus(statusName);
    final createdAt =
        DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true);

    return Node(
      id: id,
      typeName: typeName,
      values: values,
      createdAt: createdAt,
      // A.35 has no read path to vectors.db; see file header
      // (Q-A.35.1). The Node API permits null here and callers that
      // need the embedding must wait for the vectors-store readback.
      embedding: null,
      status: status,
    );
  }

  /// Decodes the `status` column.
  ///
  /// Throws on an unknown status name — that would indicate a
  /// future writer wrote a status name the current reader does not
  /// understand, which is a forward-compatibility violation the
  /// quest's hard-principle 1 forbids.
  NodeStatus _decodeStatus(String name) {
    for (final status in NodeStatus.values) {
      if (status.name == name) return status;
    }
    throw StateError(
      'unknown NodeStatus name "$name" in nodes.status column',
    );
  }
}
