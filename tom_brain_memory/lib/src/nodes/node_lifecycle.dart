// NodeLifecycleManager — the in-process owner of the `demote`,
// `promote`, and `forget` paths for `SqliteTomBrainMemory`.
//
// Plan step A.35:
//   "Implement `get`, `getMany`, `demote`, `forget` (Tombstone
//    path)."
// memory_optimization_plan § 4 adds the reversible `promote` inverse.
//
// What this file owns:
//
//   - `demote(NodeId, DemotionReason)` — flips the `nodes.status`
//     column to `demoted`. The row stays addressable by id; only
//     retrieval (FTS + vector + graph walk) is expected to skip
//     non-`active` rows once those subsystems land. The reason is
//     captured on the emitted `NodeDemoted` event (A.38) but is
//     not persisted on the row — there is no column for it on
//     `nodes`, and the audit trail belongs in the trail JSONL the
//     producing run writes, not in the live table.
//
//   - `promote(NodeId, PromotionReason)` — the reversible inverse of
//     `demote` (memory_optimization_plan § 4). Flips a `demoted` row
//     back to `active` and emits `NodePromoted`. Only ever lifts
//     `demoted → active`; it never touches `forgotten`/tombstoned
//     rows (those are gone from the live table) and a node that is
//     already `active` or unknown is a no-op that emits nothing,
//     mirroring the demote convergence convention. Like `demote`, the
//     reason is carried on the event, not persisted on the row.
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
//   - **Event emission (A.38).** `demote` emits `NodeDemoted` on the
//     active → demoted transition only; idempotent re-demotes,
//     demotes against non-existent rows, and demotes against rows in
//     any non-active status emit nothing. `forget` emits
//     `NodeForgotten` after the COMMIT of the Tombstone-write +
//     index-write + live-row-delete transaction; forgets against
//     unknown / already-forgotten ids emit nothing. The success-only
//     convention mirrors `NodePersister` (see `node_events.dart`
//     header for the reasoning).
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
import 'package:tom_brain_shared/tom_brain_shared.dart' show DemotionReason, ForgetReason, MemoryEvent, NodeId, NodeStatus, PromotionReason;

import '../store/transaction_support.dart';

import 'node_events.dart';

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

  /// Optional sink for `MemoryEvent`s. The concrete store opener
  /// wires this to the same `StreamController` that backs
  /// `TomBrainMemory.events()`; tests pass a list-backed sink to
  /// inspect emissions. `null` disables emission entirely (no leak,
  /// no allocation on the hot path).
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
    final idStr = id.toString();

    // Resolve the type name first. Used both as the no-op guard
    // (the row may be missing) and to enrich the eventual
    // `NodeDemoted` event so subscribers don't have to round-trip
    // back into SQLite for it. Selecting `status` here too lets us
    // gate event emission on the actual transition rather than on
    // `db.updatedRows`, which the `sqlite3` package exposes but
    // tests would have to introspect to verify.
    final pre = _db.select(
      'SELECT type_name, status FROM nodes WHERE id = ? LIMIT 1',
      <Object?>[idStr],
    );
    if (pre.isEmpty) return;
    final preStatus = pre.first['status'] as String;
    if (preStatus != NodeStatus.active.name) return;
    final typeName = pre.first['type_name'] as String;

    final now = _now().toUtc();
    final nowMs = now.millisecondsSinceEpoch;
    final nowIso = now.toIso8601String();

    // The WHERE clause keeps the status filter so a concurrent
    // demote landing between our SELECT and our UPDATE collapses to
    // a no-op at the SQL layer (we are single-writer per
    // connection in v1 so this is belt-and-braces).
    _db.execute(
      'UPDATE nodes SET status = ?, updated_at_ms = ?, '
      'updated_at_iso = ? '
      'WHERE id = ? AND status = ?',
      <Object?>[
        NodeStatus.demoted.name,
        nowMs,
        nowIso,
        idStr,
        NodeStatus.active.name,
      ],
    );

    _eventSink?.call(
      NodeDemoted(
        nodeId: id,
        typeName: typeName,
        reason: reason,
        occurredAt: now,
      ),
    );
  }

  /// Flips the lifecycle status of [id] from `demoted` back to
  /// `active` — the reversible inverse of [demote]
  /// (`memory_optimization_plan.md` § 4).
  ///
  /// Contract:
  ///
  ///   * Only the `demoted → active` transition fires. A promote
  ///     against an already-`active` row, an `archived` row, an unknown
  ///     id, or a forgotten / tombstoned id is a no-op — the live row is
  ///     gone or already where it should be. The status filter in the
  ///     WHERE clause makes this safe even against a concurrent writer.
  ///   * Reversible: a promoted node can be demoted again.
  ///
  /// [reason] is captured for the emitted `NodePromoted` event but is
  /// not persisted on the row — symmetric with [demote].
  Future<void> promote(NodeId id, PromotionReason reason) async {
    final idStr = id.toString();

    // Resolve the type name (for the event) and gate emission on the
    // actual `demoted → active` transition. Mirrors `demote` exactly,
    // with the status guard inverted.
    final pre = _db.select(
      'SELECT type_name, status FROM nodes WHERE id = ? LIMIT 1',
      <Object?>[idStr],
    );
    if (pre.isEmpty) return;
    final preStatus = pre.first['status'] as String;
    if (preStatus != NodeStatus.demoted.name) return;
    final typeName = pre.first['type_name'] as String;

    final now = _now().toUtc();
    final nowMs = now.millisecondsSinceEpoch;
    final nowIso = now.toIso8601String();

    _db.execute(
      'UPDATE nodes SET status = ?, updated_at_ms = ?, '
      'updated_at_iso = ? '
      'WHERE id = ? AND status = ?',
      <Object?>[
        NodeStatus.active.name,
        nowMs,
        nowIso,
        idStr,
        NodeStatus.demoted.name,
      ],
    );

    _eventSink?.call(
      NodePromoted(
        nodeId: id,
        typeName: typeName,
        reason: reason,
        occurredAt: now,
      ),
    );
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

    // Emission state — populated inside the transaction, consumed
    // *after* COMMIT. We never want to emit a `NodeForgotten` for a
    // transaction that rolled back, and we never want a sink
    // callback to throw while we hold an open transaction.
    NodeId? emittedTombstoneId;
    String? emittedForgottenType;
    DateTime? emittedAt;

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
      emittedTombstoneId = tombstoneId;
      emittedForgottenType = forgottenType;
      emittedAt = now;

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
    } catch (error, stack) {
      rollbackQuietly(_db);
      Error.throwWithStackTrace(error, stack);
    }

    // Emit AFTER the COMMIT — a rolled-back transaction must not
    // surface a `NodeForgotten` event (the catch arm rethrows and we
    // never reach this point), and the sink callback runs outside
    // the open transaction so a sink failure cannot poison the
    // SQLite handle. Flow analysis sees that the only way past the
    // try-catch is the success path that assigned all three
    // emission vars, so the bang-operators below are accurate.
    final sink = _eventSink;
    if (sink != null) {
      sink(
        NodeForgotten(
          forgottenNodeId: id,
          tombstoneNodeId: emittedTombstoneId,
          forgottenType: emittedForgottenType,
          reason: reason,
          occurredAt: emittedAt,
        ),
      );
    }
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
