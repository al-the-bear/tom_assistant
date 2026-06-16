// NodeAccessRecorder — the in-process owner of the `recordAccess`
// usage-tracking write for `SqliteTomBrainMemory`.
//
// Memory optimization plan § 3 (`memory_specification.md` § 3.1, § 6.6):
//
//   "Implement it on `SqliteTomBrainMemory` as one transaction that sets
//    `last_access_ms = clock.now()` and increments `access_count` for
//    each id."
//
// What this file owns:
//
//   - `recordAccess(List<NodeId>, {producer})` — the **sole writer** of
//     the v2 usage columns (`last_access_ms` / `last_access_iso` /
//     `access_count`, see `schema_v2.dart`). One `BEGIN…COMMIT`
//     transaction stamps every supplied id with "now" and bumps its
//     `access_count` by one.
//
// What this file does NOT do:
//
//   - It is not a read path. `get` / `getMany` / a default `recall`
//     never call this — usage reflects *use*, not inspection. Only an
//     explicit consumer act (an answer citing a node, a recall with
//     `countsAsAccess: true`) records access.
//
//   - It does not touch `updated_at_*`. Usage is a separate axis from
//     the content/lifecycle `updated_at` stamp: recording that a node
//     was read is not a content edit, so `updated_at` stays put and the
//     "node changed" consumers are not woken by mere reads.
//
//   - It emits no `MemoryEvent`. Access recording is a high-frequency
//     hot-path write; the event bus is reserved for state transitions
//     (persist / demote / forget / promote), not usage counters.
//
// Contract:
//
//   - Missing ids are silently skipped (the WHERE clause matches zero
//     rows) — a concurrent forget is not a failure, mirroring
//     `NodeLifecycleManager.demote`.
//   - An empty id list is a no-op (no transaction opened).
//   - Duplicate ids in the list bump `access_count` once per *distinct*
//     id, not once per occurrence — the ids are de-duplicated before the
//     UPDATE so a caller that passes the same node twice does not
//     double-count it.
//
// Layering:
//
//   - Takes a raw `sqlite3` `Database` handle on `memory.db`. Does NOT
//     own the handle; the store opener constructs the recorder with the
//     same handle the persister, reader, and lifecycle manager share.
//   - `now` is overridden only in tests, exactly the persister's
//     pattern.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../store/transaction_support.dart';

/// In-process owner of the `recordAccess` usage-tracking write.
///
/// One `NodeAccessRecorder` per open memory store; constructed by the
/// store opener alongside the `NodePersister`, `NodeReader`, and
/// `NodeLifecycleManager`.
final class NodeAccessRecorder {
  /// Live SQLite handle on `memory.db`. Owned by the store; the
  /// recorder does NOT close it.
  final Database _db;

  /// Wall-clock source for the `last_access_*` stamps. Defaults to
  /// `DateTime.now`; tests override for determinism.
  final DateTime Function() _now;

  /// Constructs the recorder around an already-opened, already-migrated
  /// `memory.db` handle.
  NodeAccessRecorder({
    required Database memoryDb,
    DateTime Function()? now,
  })  : _db = memoryDb,
        _now = now ?? DateTime.now;

  /// Stamps every node in [ids] as accessed "now" and increments its
  /// `access_count`.
  ///
  /// See the file header for the full contract. [producer] is accepted
  /// for call-site attribution symmetry with the rest of the write
  /// surface but is not persisted on the row — there is no usage-audit
  /// column on `nodes`, and the producing run's trail JSONL owns that
  /// history.
  Future<void> recordAccess(List<NodeId> ids, {String? producer}) async {
    if (ids.isEmpty) return;

    // De-duplicate so a node passed twice is bumped once. Preserves the
    // "increments by one per distinct id" contract regardless of caller
    // hygiene.
    final distinct = <String>{for (final id in ids) id.toString()};
    if (distinct.isEmpty) return;

    final now = _now().toUtc();
    final nowMs = now.millisecondsSinceEpoch;
    final nowIso = now.toIso8601String();

    final placeholders = List<String>.filled(distinct.length, '?').join(', ');

    _db.execute('BEGIN');
    try {
      _db.execute(
        'UPDATE nodes SET last_access_ms = ?, last_access_iso = ?, '
        'access_count = access_count + 1 '
        'WHERE id IN ($placeholders)',
        <Object?>[nowMs, nowIso, ...distinct],
      );
      _db.execute('COMMIT');
    } catch (error, stack) {
      rollbackQuietly(_db);
      Error.throwWithStackTrace(error, stack);
    }
  }
}
