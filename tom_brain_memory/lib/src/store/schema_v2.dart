// SchemaV2 — SQLite schema v2 for `memory.db`.
//
// Memory-optimization plan step 1 (`memory_optimization_plan.md`):
//   "Add `last_access_ms` (int, indexed) and `access_count` (int,
//    default 0) plus the mirrored `last_access_iso` to the `nodes`
//    table via a forward-only `schema_v2` registry migration,
//    backfilling `last_access_ms = created_at_ms` and
//    `access_count = 0` for existing rows, then creating the index on
//    `last_access_ms`."
//
// These are the usage columns specified in `memory_specification.md`
// § 12.2.1. They power the recency/frequency ranking (§ 6.2.1), the
// `oldest` / `coldest` strategies (§ 6.1.1), the `last_access_ms`
// symbolic window (§ 6.6), and the `dream_decay_v1` recalibration pass
// (§ 9.7). `recordAccess` (§ 3.1, § 6.6) is their sole writer.
//
// Why a backfill from creation time:
//
//   A never-accessed node's "last access" is its creation — that is the
//   neutral baseline that makes the recency ranking well-defined for
//   every node from day one, and it matches the read-time fallback the
//   ranking re-score uses (`last_access_ms` falling back to
//   `created_at_ms`). `access_count` backfills to `0` via the column
//   default: a node that has never been recorded as used has been used
//   zero times.
//
// Forward-only (quest hard-principle 1): v2 is an immutable artifact.
// Once merged it never changes; a defect in v2 is corrected by adding
// `schema_v3.dart`. There is no downgrade path.
//
// Idempotency / crash-resumability:
//
//   `ALTER TABLE … ADD COLUMN` has no `IF NOT EXISTS` form in SQLite,
//   so we guard each add behind a `PRAGMA table_info(nodes)` probe — a
//   re-run against a DB that already carries the column is a no-op
//   rather than a "duplicate column name" error. SQLite DDL is
//   transactional, so the whole apply is wrapped in one
//   `BEGIN … COMMIT`; a crash before `COMMIT` leaves the DB untouched
//   at v1 and the migrator re-runs cleanly. The backfill `UPDATE`s only
//   touch rows whose `last_access_*` is still `NULL`, so a re-run can
//   never clobber real access data written between a partial apply and
//   the retry. The index uses `CREATE INDEX IF NOT EXISTS`. The
//   `migrations` row is upserted via `INSERT OR IGNORE`.

import 'package:sqlite3/sqlite3.dart';

import 'transaction_support.dart';

/// Schema version produced by [applySchemaV2].
///
/// The migrator (A.28) compares this against the highest row in the
/// `migrations` table to decide whether to apply this version. Each
/// schema-version file owns its own version literal.
const int schemaV2Version = 2;

/// Human-readable summary persisted into `migrations.summary` for every
/// v2 application. Operators reading the migrations table see this
/// string; it never appears in production data paths.
const String schemaV2Summary =
    'Tom Brain memory schema v2 — node usage columns '
    '(last_access_ms / last_access_iso / access_count) + index, '
    'backfilled from created_at.';

/// Applies schema v2 to [db].
///
/// Contract (identical discipline to [applySchemaV1]):
///
///   * Wraps every statement in a single `BEGIN … COMMIT`. A failure
///     mid-application rolls back, leaving the DB at v1.
///   * Records the application in `migrations` via `INSERT OR IGNORE`
///     so a second call against a v2-applied DB is a no-op.
///   * Guards each `ADD COLUMN` behind a column-existence probe so a
///     re-run after a clean abort (or against an externally-patched DB)
///     converges instead of throwing.
///
/// Called by the migrator (A.28). Hosts must not call this directly
/// outside of the migration path.
void applySchemaV2(Database db) {
  db.execute('BEGIN');
  try {
    final existing = _nodeColumns(db);

    if (!existing.contains('last_access_ms')) {
      db.execute('ALTER TABLE nodes ADD COLUMN last_access_ms INTEGER');
    }
    if (!existing.contains('last_access_iso')) {
      db.execute('ALTER TABLE nodes ADD COLUMN last_access_iso TEXT');
    }
    if (!existing.contains('access_count')) {
      // NOT NULL with a constant DEFAULT: every existing row is set to
      // 0 by the ALTER, satisfying the "backfill access_count = 0"
      // requirement without a separate UPDATE.
      db.execute(
        'ALTER TABLE nodes ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0',
      );
    }

    // Backfill: a never-accessed node's "last access" is its creation.
    // Only touch not-yet-backfilled rows (NULL) so a re-run never
    // clobbers real access data recorded between a partial apply and a
    // retry.
    db.execute(
      'UPDATE nodes SET last_access_ms = created_at_ms '
      'WHERE last_access_ms IS NULL',
    );
    db.execute(
      'UPDATE nodes SET last_access_iso = created_at_iso '
      'WHERE last_access_iso IS NULL',
    );

    // Index the recency column so `oldest` / `coldest` sorts and the
    // `last_access_ms` symbolic window are O(log n) (spec § 12.2.1).
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_nodes_last_access_ms '
      'ON nodes(last_access_ms)',
    );

    final now = DateTime.now().toUtc();
    db.execute(
      'INSERT OR IGNORE INTO migrations '
      '(version, applied_at_ms, applied_at_iso, summary) '
      'VALUES (?, ?, ?, ?)',
      <Object?>[
        schemaV2Version,
        now.millisecondsSinceEpoch,
        now.toIso8601String(),
        schemaV2Summary,
      ],
    );
    db.execute('COMMIT');
  } catch (error, stack) {
    rollbackQuietly(db);
    Error.throwWithStackTrace(error, stack);
  }
}

/// The set of column names currently declared on the `nodes` table.
///
/// Used to make each `ADD COLUMN` idempotent: SQLite offers no
/// `ADD COLUMN IF NOT EXISTS`, so we probe `PRAGMA table_info` and skip
/// any column that is already present.
Set<String> _nodeColumns(Database db) {
  final rows = db.select('PRAGMA table_info(nodes)');
  return <String>{for (final row in rows) row['name'] as String};
}
