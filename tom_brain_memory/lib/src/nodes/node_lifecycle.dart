// NodeLifecycleManager — the in-process owner of the `demote` and
// `forget` paths for `SqliteTomBrainMemory`.
//
// Plan step A.35:
//   "Implement `get`, `getMany`, `demote`, `forget` (Tombstone
//    path)."
//
// What this file owns:
//
//   - `demote(NodeId, DemotionReason)` — flips the `nodes.status`
//     column to `demoted`. The row stays addressable by id; only
//     retrieval (FTS + vector + graph walk) is expected to skip
//     non-`active` rows once those subsystems land. The reason is
//     captured for the eventual `NodeDemoted` event (A.38) but is
//     not persisted on the row — there is no column for it on
//     `nodes`, and the audit trail belongs in the trail JSONL the
//     producing run writes, not in the live table.
//
//   - `forget(NodeId, ForgetReason)` — the **only** path that
//     removes a row from the live `nodes` table (spec § 4.1 "the
//     Tombstone is the only record that survives"). Forget runs the
//     four writes below as a single `BEGIN…COMMIT`:
//
//       1. INSERT a fresh `Tombstone` node into `nodes`. The
//          Tombstone carries `reason` and `forgotten_at` as
//          per-row attrs and an idempotency key derived from the
//          forgotten id so re-running `forget` converges at the
//          SQL layer (partial unique index on
//          `nodes.idempotency_key`).
//
//       2. INSERT a `tombstones_index` row pointing the forgotten
//          id at the new Tombstone — the fast "did we already
//          forget this?" lookup spec § 4.1 calls out.
//
//       3. DELETE the original row from `nodes`.
//
//       4. DELETE any leftover `pending_vector_writes` row for the
//          forgotten id (the partial unique index on `node_id` in
//          that table guarantees zero or one).
//
//     The Tombstone is *not* routed through `NodePersister`. The
//     persister opens its own coordinator transaction; we need this
//     work atomic with the DELETE of the live row, which means a
//     single locally-managed transaction here. The Tombstone's
//     schema is small and entirely controlled by this file, so the
//     persister's validator branches add no value on this path.
//
// What this file does NOT own:
//
//   - **Vector deletion in `vectors.db`.** Forget removes the
//     `memory.db` row but does not yet delete the corresponding
//     vector — `VectorApplier` has only `apply`, not `delete`. The
//     stale vector is invisible to retrieval because the live node
//     row is gone (retrieval joins on `nodes`), but it occupies
//     bytes. Tracked as **Q-A.35.3**: extend `VectorApplier` with
//     `deleteFor(NodeId)` and have the lifecycle manager call it
//     after the SQL COMMIT, with the same crash-safety story the
//     pending-vector-writes table provides on the write side.
//
//   - **Edge cleanup.** `forget` does not delete edges that point
//     to or from the forgotten id. Edge cleanup is a richer
//     concern (some edges should be rewritten to point at the
//     Tombstone via `derived_from`; others should be hard-removed)
//     and lands with the edge implementation at A.36+. Tracked as
//     **Q-A.35.4**.
//
//   - **Event emission.** `NodeDemoted` and `NodeForgotten` are
//     scheduled for A.38; A.35 does not emit. The `eventSink`
//     parameter exists so A.38 wires the events in without
//     reshaping the constructor.
//
// Layering:
//
//   - Takes a raw `sqlite3` `Database` handle on `memory.db`. Does
//     NOT own the handle; the store opener constructs the manager
//     with the same handle the persister and reader share.
//
//   - `idMint` and `now` are only overridden in tests, exactly the
//     persister's pattern.

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../api/memory_event.dart';
import '../api/scope.dart';
import 'node.dart';

/// In-process owner of the `demote` and `forget` paths.
///
/// One `NodeLifecycleManager` per open memory store; constructed by
/// the store opener alongside the `NodePersister` and `NodeReader`.
final class NodeLifecycleManager {
  /// Live SQLite handle on `memory.db`. Owned by the store; the
  /// manager does NOT close it.
  final Database _db;

  /// Fresh-id factory for Tombstone nodes. Defaults to
  /// `NodeId.generate`; tests override for determinism.
  final NodeId Function() _idMint;

  /// Wall-clock source for `updated_at_*` and Tombstone
  /// `created_at_*` stamps. Defaults to `DateTime.now`; tests
  /// override for determinism.
  final DateTime Function() _now;

  /// Optional sink for `MemoryEvent`s — wired by the store opener
  /// once `NodeDemoted` / `NodeForgotten` land at A.38. At A.35
  /// the sink is reserved but never called (see file header).
  // ignore: unused_field
  final void Function(MemoryEvent)? _eventSink;

  /// Canonical type name for Tombstone rows.
  ///
  /// Hoisted to a `static const` rather than the literal string so
  /// the registry-driven validator (when it ships, see file
  /// header) and this code path share a single source of truth.
  static const String _tombstoneTypeName = 'Tombstone';

  /// Producer attribution used on Tombstone rows. Mirrors the
  /// `<agent>:<procedure>:<run>` pattern the persister documents on
  /// `Scope.producer`; the brain-internal producer for a
  /// user-initiated `forget` is the lifecycle path itself.
  static const String _forgetProducer = 'memory:forget:user';

  /// Constructs the manager around an already-opened, already-
  /// migrated `memory.db` handle.
  NodeLifecycleManager({
    required Database memoryDb,
    NodeId Function()? idMint,
    DateTime Function()? now,
    void Function(MemoryEvent)? eventSink,
  })  : _db = memoryDb,
        _idMint = idMint ?? NodeId.generate,
        _now = now ?? DateTime.now,
        _eventSink = eventSink;

  // ─── Public surface ────────────────────────────────────────────

  /// Flips the lifecycle status of [id] to `demoted`.
  ///
  /// Contract (spec § 3.1):
  ///
  ///   * The row stays addressable by id — `NodeReader.get(id)`
  ///     keeps returning the node, with `status = NodeStatus.demoted`.
  ///   * Reversible by `dream_reconsolidate_v1` (a future write
  ///     that flips the status back to `active`).
  ///   * A demote against a non-existent or already-forgotten id is
  ///     a no-op. There is nothing to demote and nothing to surface
  ///     as a failure — the audit happens at the call site, which
  ///     knows whether the prior `get` returned a node.
  ///   * A demote against an already-`demoted` or `archived` row is
  ///     a no-op (the status flip is idempotent).
  ///
  /// [reason] is captured for the eventual `NodeDemoted` event
  /// (A.38) but is not persisted on the row.
  Future<void> demote(NodeId id, DemotionReason reason) async {
    final now = _now().toUtc();
    final nowMs = now.millisecondsSinceEpoch;
    final nowIso = now.toIso8601String();

    // The WHERE clause filters by both id and status so a row that
    // is already demoted, archived, or forgotten incurs zero
    // writes. `forgotten` rows are already absent (forget DELETEs
    // them) so the filter is belt-and-braces.
    _db.execute(
      'UPDATE nodes SET status = ?, updated_at_ms = ?, '
      'updated_at_iso = ? '
      'WHERE id = ? AND status = ?',
      <Object?>[
        NodeStatus.demoted.name,
        nowMs,
        nowIso,
        id.toString(),
        NodeStatus.active.name,
      ],
    );

    // No event emission at A.35 — `NodeDemoted` lands at A.38. The
    // `reason` parameter is consumed by the future event
    // constructor; until then the call site captures it in its
    // trail JSONL.
    // ignore: unused_local_variable
    final _ = reason;
  }

  /// User-explicit deletion of [id]: writes a `Tombstone` node,
  /// indexes it, removes the live row.
  ///
  /// Contract (spec § 4.1, hard invariant 1 "Nothing is truly lost"):
  ///
  ///   * If [id] has no live row (never existed or already
  ///     forgotten), `forget` is a no-op. The prior Tombstone (if
  ///     any) is left intact — re-forgetting an already-forgotten
  ///     id does not chain Tombstones.
  ///
  ///   * Otherwise: write a fresh `Tombstone` node, write the
  ///     `tombstones_index` row, DELETE the original row, DELETE
  ///     any pending vector-write row for the forgotten id. All
  ///     four writes commit as one transaction.
  ///
  ///   * The Tombstone carries `reason` (the [reason] enum's name)
  ///     and `forgotten_at` (ISO-8601 UTC). Its idempotency key is
  ///     `tombstone:<forgotten_id>` so a concurrent retry collides
  ///     at the partial unique index rather than producing two
  ///     Tombstones for the same forgotten id. (The check at the
  ///     top of `forget` makes this collision unreachable in normal
  ///     operation; the idempotency key is defence-in-depth.)
  ///
  ///   * The vector in `vectors.db` is NOT deleted at A.35 — see
  ///     file header Q-A.35.3.
  ///
  ///   * Edges touching [id] are NOT cleaned up at A.35 — see file
  ///     header Q-A.35.4.
  Future<void> forget(NodeId id, ForgetReason reason) async {
    final idStr = id.toString();

    // Single transaction: read the existing row, then write the
    // tombstone + index + delete + cleanup. The read is inside the
    // transaction so a concurrent reader cannot see a half-state
    // (we are single-writer-per-connection on `sqlite3` so this is
    // about consistency-on-read rather than serialisation).
    _db.execute('BEGIN');
    try {
      final existing = _db.select(
        'SELECT type_name FROM nodes WHERE id = ? LIMIT 1',
        <Object?>[idStr],
      );
      if (existing.isEmpty) {
        // No live row → nothing to forget. Spec § 4.1 says the
        // Tombstone is the survivor of an *explicit deletion*; if
        // there's nothing to delete, there's nothing to record.
        _db.execute('COMMIT');
        return;
      }

      final forgottenType = existing.first['type_name'] as String;
      final now = _now().toUtc();
      final nowMs = now.millisecondsSinceEpoch;
      final nowIso = now.toIso8601String();
      final tombstoneId = _idMint();
      final tombstoneIdStr = tombstoneId.toString();

      // 1. INSERT the Tombstone node row directly. The Tombstone
      //    type carries EmbeddingPolicy.none so there is no vector
      //    to coordinate with; a plain SQLite INSERT in this
      //    transaction is sufficient.
      final tombstoneAttrs = <String, Object?>{
        'reason': reason.name,
        'forgotten_at': nowIso,
      };
      final scopeJson = <String, Object?>{
        'producer': _forgetProducer,
        'idempotency_key': 'tombstone:$idStr',
      };
      _db.execute(
        'INSERT INTO nodes ('
        'id, type_name, scope_json, produced_by, attrs_json, status, '
        'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso, '
        'idempotency_key, embedding_model_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          tombstoneIdStr,
          _tombstoneTypeName,
          jsonEncode(scopeJson),
          _forgetProducer,
          jsonEncode(tombstoneAttrs),
          NodeStatus.active.name,
          nowMs,
          nowIso,
          nowMs,
          nowIso,
          'tombstone:$idStr',
          null,
        ],
      );

      // 2. INSERT the tombstones_index row — the "did we already
      //    forget this?" lookup.
      _db.execute(
        'INSERT INTO tombstones_index ('
        'forgotten_node_id, tombstone_node_id, forgotten_type, '
        'reason, forgotten_at_ms, forgotten_at_iso) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        <Object?>[
          idStr,
          tombstoneIdStr,
          forgottenType,
          reason.name,
          nowMs,
          nowIso,
        ],
      );

      // 3. DELETE the original row. After this point `NodeReader.get`
      //    returns null for [id].
      _db.execute('DELETE FROM nodes WHERE id = ?', <Object?>[idStr]);

      // 4. DELETE any leftover pending vector write. There can be at
      //    most one (PRIMARY KEY (node_id) on the table).
      _db.execute(
        'DELETE FROM pending_vector_writes WHERE node_id = ?',
        <Object?>[idStr],
      );

      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    // No event emission at A.35 — `NodeForgotten` lands at A.38.
  }
}

/// Read-side accessor for the `tombstones_index` table.
///
/// Lives next to the lifecycle manager because both touch the same
/// table. Exposed so the future operator UI and the dispatcher
/// integrity checks can ask "what was forgotten and when?" without
/// reaching into raw SQL.
final class TombstoneIndexEntry {
  /// The forgotten node id (gone from `nodes`).
  final NodeId forgottenNodeId;

  /// The Tombstone node that records the deletion.
  final NodeId tombstoneNodeId;

  /// The type name of the forgotten node, preserved here so audit
  /// queries can filter by type without reading the (now-absent)
  /// row.
  final String forgottenType;

  /// The [ForgetReason] enum name supplied at `forget` time.
  final String reason;

  /// When the forget happened (UTC).
  final DateTime forgottenAt;

  const TombstoneIndexEntry({
    required this.forgottenNodeId,
    required this.tombstoneNodeId,
    required this.forgottenType,
    required this.reason,
    required this.forgottenAt,
  });
}

/// Returns the `TombstoneIndexEntry` for [forgottenId], or `null`
/// when the id was never forgotten.
///
/// Free function (not a method on `NodeLifecycleManager`) because
/// reads do not depend on the manager's clock/id-mint collaborators
/// — the table is the source of truth.
TombstoneIndexEntry? lookupTombstone(Database memoryDb, NodeId forgottenId) {
  final rows = memoryDb.select(
    'SELECT tombstone_node_id, forgotten_type, reason, forgotten_at_ms '
    'FROM tombstones_index WHERE forgotten_node_id = ? LIMIT 1',
    <Object?>[forgottenId.toString()],
  );
  if (rows.isEmpty) return null;
  final row = rows.first;
  return TombstoneIndexEntry(
    forgottenNodeId: forgottenId,
    tombstoneNodeId: NodeId.fromString(row['tombstone_node_id'] as String),
    forgottenType: row['forgotten_type'] as String,
    reason: row['reason'] as String,
    forgottenAt: DateTime.fromMillisecondsSinceEpoch(
      row['forgotten_at_ms'] as int,
      isUtc: true,
    ),
  );
}
