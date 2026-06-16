// SchemaMigrator — forward-only chained schema migrator for `memory.db`.
//
// Plan step A.28:
//   "Write the schema migrator (no backwards compat; forward-only).
//    One file per version."
//
// Scope at A.28:
//
//   - A `SchemaMigration` value type that pairs a version number with
//     the function that applies it (the per-version `applySchemaVN`
//     defined in its own file).
//   - A `kSchemaMigrations` registry — the ordered list of every
//     known version. Today the list has one entry (v1, from A.27).
//     Each future schema version appends one entry here; new entries
//     never modify or reorder existing ones.
//   - A `SchemaMigrator` class that walks the registry, reads the
//     current schema version via `readSchemaVersion(db)`, and applies
//     every registered version whose number is strictly greater than
//     the current one, in ascending order.
//   - A `SchemaMigrationReport` record of what was applied — used by
//     the boot-time integrity check (A.29) and by tests.
//
// Why "one file per version":
//
//   The plan's `One file per version` instruction is the
//   forward-only discipline expressed in file layout: every schema
//   version is an immutable artifact. Once `schema_vN.dart` is
//   merged it does not change. Bugs in vN are fixed by adding
//   `schema_v(N+1).dart` that performs the correction. There is no
//   downgrade path; there is no shared mutable migration script.
//
// Why each version owns its own transaction:
//
//   `applySchemaV1` (and every future `applySchemaVN`) already wraps
//   its DDL in `BEGIN…COMMIT` and writes its own `migrations` row.
//   That is the right granularity: each version is independently
//   committed. If v4 succeeds and v5 fails partway, the database is
//   left at v4 — recoverable. A monolithic transaction across all
//   pending versions would either succeed entirely or fail entirely;
//   on long upgrades that is the worse failure mode, because a tiny
//   issue in vN would discard the work of v1…v(N-1).
//
// Why a separate registry constant instead of inlining the list in
// the migrator class:
//
//   Tests construct `SchemaMigrator` with a fake registry to drive
//   chaining behaviour (multiple versions in sequence, failures
//   midway, version-ahead refusal) without depending on the real
//   `applySchemaV1`. Keeping `kSchemaMigrations` as a separate
//   const list and letting the constructor accept an override is
//   the minimum surface that makes those tests possible.
//
// Forward-only enforcement:
//
//   If the database reports a version *higher* than the registry's
//   latest, the migrator throws `SchemaVersionAhead`. We refuse to
//   open a database that was written by a newer binary — silently
//   "downgrading" by ignoring unknown migrations risks data loss.
//   The brain prefers a hard refusal to a soft corruption.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show defaultNowUtc;

import '../observability/memory_log.dart';
import 'schema_v1.dart';
import 'schema_v2.dart';

/// A single registered schema-version migration.
///
/// Pairs the version number with the function that applies it. The
/// `apply` function is responsible for its own transaction, its own
/// `IF NOT EXISTS` guards (for crash-resumability), and its own
/// `INSERT OR IGNORE INTO migrations` bookkeeping. The migrator
/// treats it as a black box: it calls `apply(db)` and trusts the
/// caller to leave the DB at version [version] on success.
final class SchemaMigration {
  /// Schema version produced by [apply]. Must be ≥ 1 and must be
  /// strictly greater than the version of the predecessor in the
  /// registry. Gaps are illegal (see [SchemaMigrator._assertValid]).
  final int version;

  /// Human-readable summary persisted into the `migrations` table by
  /// the per-version applier. Mirrored here so the migrator can
  /// include it in [SchemaMigrationReport.applied] without having to
  /// re-read the DB.
  final String summary;

  /// Applies this schema version to [db].
  ///
  /// Contract on the applier:
  ///
  ///   * Wraps its work in a `BEGIN…COMMIT`. On any failure, must
  ///     roll back (so the DB stays at the previous version) and
  ///     rethrow.
  ///   * Uses `IF NOT EXISTS` (or equivalent) so a re-run after a
  ///     crash mid-application converges on the second attempt.
  ///   * Records `(version, applied_at_ms, applied_at_iso, summary)`
  ///     into the `migrations` table via `INSERT OR IGNORE` so a
  ///     re-run is a no-op at the bookkeeping layer.
  final void Function(Database db) apply;

  const SchemaMigration({
    required this.version,
    required this.summary,
    required this.apply,
  });

  @override
  String toString() => 'SchemaMigration(v$version: $summary)';
}

/// The canonical registry of every known schema version.
///
/// **Append-only.** A new schema version is added by:
///
///   1. Writing `lib/src/store/schema_v<N>.dart` with the new DDL
///      and an `applySchemaV<N>(Database)` entry point.
///   2. Appending a new `SchemaMigration(version: N, …)` to this
///      list. Never reorder or modify existing entries.
///   3. Exporting the new applier from `store.dart`.
///
/// Tests that need to exercise chaining behaviour (v2, v3, …) build
/// their own list and pass it to [SchemaMigrator]'s constructor —
/// they do not extend this constant.
const List<SchemaMigration> kSchemaMigrations = <SchemaMigration>[
  SchemaMigration(
    version: schemaV1Version,
    summary: schemaV1Summary,
    apply: applySchemaV1,
  ),
  SchemaMigration(
    version: schemaV2Version,
    summary: schemaV2Summary,
    apply: applySchemaV2,
  ),
];

/// Outcome of one call to [SchemaMigrator.migrate].
///
/// Returned even when no migrations ran (the DB was already at the
/// latest version). Callers — chiefly the boot-time integrity check
/// (A.29) — read [appliedVersions] to know whether a "schema
/// migrated" log line is worth emitting.
final class SchemaMigrationReport {
  /// The schema version the database had *before* this migration
  /// call. `0` for a fresh database with no `migrations` table.
  final int fromVersion;

  /// The schema version the database has *after* this migration
  /// call. Always `>= fromVersion`. Equal to [fromVersion] when no
  /// migrations were applied.
  final int toVersion;

  /// The versions that were applied during this call, in ascending
  /// order. Empty when [fromVersion] equals [toVersion]. Frozen
  /// (unmodifiable) so the caller cannot mutate the report after the
  /// fact.
  final List<SchemaMigration> applied;

  /// Wall-clock UTC at which the migrator started. Captured before
  /// the first applier runs; useful for log lines that want to show
  /// "migration took X ms".
  final DateTime startedAt;

  /// Wall-clock UTC at which the migrator finished. Captured after
  /// the last applier returns (or immediately, when no appliers
  /// ran).
  final DateTime finishedAt;

  SchemaMigrationReport({
    required this.fromVersion,
    required this.toVersion,
    required List<SchemaMigration> applied,
    required this.startedAt,
    required this.finishedAt,
  }) : applied = List.unmodifiable(applied);

  /// True iff at least one migration was applied.
  bool get didApplyAny => applied.isNotEmpty;

  /// The wall-clock duration of the migration. Always
  /// non-negative; equal to `Duration.zero` when no migrations ran
  /// against a fast in-memory clock.
  Duration get duration => finishedAt.difference(startedAt);

  @override
  String toString() => 'SchemaMigrationReport('
      'from: $fromVersion, to: $toVersion, '
      'applied: ${applied.map((m) => m.version).toList()})';
}

/// Thrown by [SchemaMigrator.migrate] when the database reports a
/// schema version higher than the latest version in the registry.
///
/// This is the forward-only invariant in action: a database written
/// by a newer binary must not be silently opened by an older one.
/// The caller (typically the boot-time integrity check) translates
/// this into an operator-visible failure.
final class SchemaVersionAhead implements Exception {
  /// Version reported by the database.
  final int databaseVersion;

  /// Latest version in this binary's registry.
  final int latestKnownVersion;

  const SchemaVersionAhead({
    required this.databaseVersion,
    required this.latestKnownVersion,
  });

  @override
  String toString() =>
      'SchemaVersionAhead: database is at v$databaseVersion but this '
      'binary only knows up to v$latestKnownVersion. Refusing to open '
      'a database written by a newer binary (forward-only invariant).';
}

/// Forward-only chained schema migrator.
///
/// Construct once per process, call [migrate] before any other
/// SQLite I/O. The migrator holds no state across calls — it can be
/// reused freely.
final class SchemaMigrator {
  /// The migrations this migrator knows about, sorted ascending by
  /// version and validated to be contiguous from 1.
  final List<SchemaMigration> _migrations;

  /// Clock used for the start/finish timestamps in
  /// [SchemaMigrationReport]. Injectable so tests can pin time
  /// without a wall-clock dependency.
  final DateTime Function() _now;

  /// Constructs a migrator over [migrations] (or the canonical
  /// [kSchemaMigrations] when omitted).
  ///
  /// Validates eagerly that the migration list is monotonically
  /// increasing, contiguous from 1 (no gaps), and contains no
  /// duplicates. These checks live in the constructor (not in
  /// [migrate]) so a misconfigured registry fails before the host
  /// opens any database.
  ///
  /// Throws [ArgumentError] if [migrations] is empty, contains a
  /// duplicate version, or has a gap (e.g. v1, v3 with no v2).
  ///
  /// `clock` is exposed for testability only; production code uses
  /// the default `DateTime.now().toUtc`.
  SchemaMigrator({
    List<SchemaMigration>? migrations,
    DateTime Function()? clock,
  })  : _migrations = _sortedAndValidated(migrations ?? kSchemaMigrations),
        _now = clock ?? defaultNowUtc;

  /// The highest known schema version in this migrator's registry.
  ///
  /// Used by the boot integrity check (A.29) to detect "the binary
  /// thinks the latest version is N but the DB is at M".
  int get latestKnownVersion =>
      _migrations.isEmpty ? 0 : _migrations.last.version;

  /// The number of registered migrations. Useful for test
  /// introspection; not a load-bearing API.
  int get migrationCount => _migrations.length;

  /// Migrates [db] forward to [latestKnownVersion].
  ///
  /// Steps:
  ///
  ///   1. Reads the current version via [readSchemaVersion].
  ///   2. If the current version is greater than [latestKnownVersion],
  ///      throws [SchemaVersionAhead].
  ///   3. Otherwise, for each registered migration with version
  ///      strictly greater than the current version, calls
  ///      `migration.apply(db)` in ascending order.
  ///   4. Returns a [SchemaMigrationReport] describing what
  ///      happened.
  ///
  /// On a fresh database (current version `0`), this is the bootstrap
  /// path: every registered migration runs.
  ///
  /// On a database already at the latest version, this is a no-op:
  /// the report carries an empty `applied` list and the start/finish
  /// timestamps are essentially equal.
  ///
  /// If a per-version applier throws, the exception propagates after
  /// the applier has rolled itself back. Previously-applied versions
  /// in this same `migrate` call remain committed — by design.
  SchemaMigrationReport migrate(Database db) {
    final startedAt = _now();
    final currentVersion = readSchemaVersion(db);

    if (currentVersion > latestKnownVersion) {
      throw SchemaVersionAhead(
        databaseVersion: currentVersion,
        latestKnownVersion: latestKnownVersion,
      );
    }

    final toApply = _migrations
        .where((m) => m.version > currentVersion)
        .toList(growable: false);

    for (final migration in toApply) {
      migration.apply(db);
    }

    final finalVersion =
        toApply.isEmpty ? currentVersion : toApply.last.version;
    final finishedAt = _now();

    // A.84 — emit a single status line per migrate() call. We log
    // every call (even no-ops) at `debug`, and promote to `status`
    // only when at least one version was actually applied. This keeps
    // routine reopens quiet while making schema progress visible at
    // the silent level.
    if (toApply.isEmpty) {
      MemoryLog.store.debug(
        'schema migrate: no-op (already at v$currentVersion)',
      );
    } else {
      final versions = toApply.map((m) => 'v${m.version}').join(', ');
      MemoryLog.store.status(
        'schema migrated from v$currentVersion to v$finalVersion '
        '(applied: $versions)',
      );
    }

    return SchemaMigrationReport(
      fromVersion: currentVersion,
      toVersion: finalVersion,
      applied: toApply,
      startedAt: startedAt,
      finishedAt: finishedAt,
    );
  }

  /// Returns [migrations] sorted ascending by version and validated.
  ///
  /// Validation rules:
  ///
  ///   * The list must be non-empty. An empty registry would mean
  ///     "no schema known"; that is a programmer error, not a
  ///     runtime configuration.
  ///   * The first version must be `1`. The migrator starts from
  ///     a fresh DB (version `0`) and expects to chain upward
  ///     contiguously.
  ///   * Each subsequent version must equal `previous + 1`. Gaps
  ///     would allow a database to wedge at an intermediate state
  ///     no applier knows how to leave.
  ///   * Duplicates are detected by the gap check (`previous + 1`
  ///     fails when two entries share a version).
  static List<SchemaMigration> _sortedAndValidated(
    List<SchemaMigration> migrations,
  ) {
    if (migrations.isEmpty) {
      throw ArgumentError.value(
        migrations,
        'migrations',
        'schema migrator requires at least one migration; '
            'the registry must never be empty',
      );
    }
    final sorted = [...migrations]
      ..sort((a, b) => a.version.compareTo(b.version));

    if (sorted.first.version != 1) {
      throw ArgumentError.value(
        sorted.first.version,
        'migrations.first.version',
        'schema migrations must start at version 1; got '
            'v${sorted.first.version}',
      );
    }
    for (var i = 1; i < sorted.length; i++) {
      final prev = sorted[i - 1].version;
      final cur = sorted[i].version;
      if (cur != prev + 1) {
        throw ArgumentError.value(
          cur,
          'migrations[$i].version',
          'schema migrations must be contiguous (no gaps, no '
              'duplicates); expected v${prev + 1} after v$prev, got v$cur',
        );
      }
    }
    return List.unmodifiable(sorted);
  }
}
