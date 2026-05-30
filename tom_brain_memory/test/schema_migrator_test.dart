// A.28 schema-migrator contract test.
//
// Locks the forward-only schema-migrator surface:
//
//   1. Construction validation
//      - Empty registry rejected.
//      - Non-contiguous registry (gaps) rejected.
//      - First-version-not-1 rejected.
//      - Duplicate version rejected (degenerate case of the gap
//        check).
//      - Unsorted-but-otherwise-valid registry accepted and
//        re-sorted by the constructor.
//
//   2. Default-registry behaviour (the real `kSchemaMigrations`)
//      - Latest version is 1 (today's registry only has v1).
//      - Fresh DB → migrate → version is 1, all v1 tables present,
//        report shows fromVersion=0/toVersion=1 with v1 in
//        `applied`.
//      - Already-at-v1 DB → migrate → no-op, report shows
//        fromVersion=1/toVersion=1 with empty `applied`.
//
//   3. Chained-registry behaviour (a synthetic fake with v1 + v2)
//      - Fresh DB → both versions applied in ascending order, both
//        recorded in `migrations`, `applied` list carries [v1, v2].
//      - Already-at-v1 DB → only v2 applied; report's `fromVersion`
//        is 1 and `applied` carries [v2] only.
//      - Already-at-v2 DB → no migrations applied.
//
//   4. Forward-only refusal
//      - A DB whose `migrations` row is higher than the registry's
//        latest causes `SchemaVersionAhead` to be thrown.
//      - The DB is not mutated by the refused migration call.
//
//   5. Mid-chain failure
//      - When v2 throws partway through a v1→v3 upgrade, the v1
//        application remains committed (independent transactions per
//        version), the v2 failure surfaces, and the report is never
//        returned.
//
//   6. Report shape
//      - `didApplyAny` matches `applied.isNotEmpty`.
//      - `duration` is non-negative.
//      - Clock injection works (timestamps come from the supplied
//        clock, not wall-clock).

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('A.28 SchemaMigrator construction validation', () {
    test('empty registry is rejected', () {
      expect(
        () => SchemaMigrator(migrations: const <SchemaMigration>[]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('registry not starting at 1 is rejected', () {
      expect(
        () => SchemaMigrator(
          migrations: <SchemaMigration>[
            SchemaMigration(version: 2, summary: 'v2', apply: (_) {}),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('registry with a gap is rejected', () {
      // v1, v3 — missing v2 means no applier can leave the DB at v2,
      // so the chain is broken.
      expect(
        () => SchemaMigrator(
          migrations: <SchemaMigration>[
            SchemaMigration(version: 1, summary: 'v1', apply: (_) {}),
            SchemaMigration(version: 3, summary: 'v3', apply: (_) {}),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('registry with a duplicate version is rejected', () {
      // Two SchemaMigrations both claiming v2 — degenerate gap.
      expect(
        () => SchemaMigrator(
          migrations: <SchemaMigration>[
            SchemaMigration(version: 1, summary: 'v1', apply: (_) {}),
            SchemaMigration(version: 2, summary: 'v2a', apply: (_) {}),
            SchemaMigration(version: 2, summary: 'v2b', apply: (_) {}),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('unsorted-but-contiguous registry is accepted and re-sorted', () {
      // The constructor sorts internally; the caller can pass
      // entries in any order.
      final mig = SchemaMigrator(
        migrations: <SchemaMigration>[
          SchemaMigration(version: 2, summary: 'v2', apply: (_) {}),
          SchemaMigration(version: 1, summary: 'v1', apply: (_) {}),
          SchemaMigration(version: 3, summary: 'v3', apply: (_) {}),
        ],
      );
      expect(mig.migrationCount, equals(3));
      expect(mig.latestKnownVersion, equals(3));
    });
  });

  group('A.28 SchemaMigrator default-registry behaviour', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() => db.dispose());

    test('default registry exposes v1 as the latest known version', () {
      final mig = SchemaMigrator();
      expect(mig.latestKnownVersion, equals(1));
      expect(mig.migrationCount, equals(1));
    });

    test('kSchemaMigrations carries exactly one entry today', () {
      // Sanity-check the registry constant directly — the migrator's
      // public surface is symmetrical with this fact.
      expect(kSchemaMigrations, hasLength(1));
      expect(kSchemaMigrations.first.version, equals(1));
    });

    test('migrate on a fresh DB applies v1 and reports it', () {
      final mig = SchemaMigrator();
      final report = mig.migrate(db);

      expect(readSchemaVersion(db), equals(1));
      expect(report.fromVersion, equals(0));
      expect(report.toVersion, equals(1));
      expect(report.applied.map((m) => m.version), equals(<int>[1]));
      expect(report.didApplyAny, isTrue);

      // v1 tables landed.
      expect(_tableNames(db), containsAll(<String>{
        'nodes',
        'edges',
        'node_types',
        'stacks',
        'stack_entries',
        'trails',
        'pending_vector_writes',
        'centroids',
        'migrations',
        'tombstones_index',
      }));
    });

    test('migrate on an already-at-v1 DB is a no-op', () {
      final mig = SchemaMigrator();
      mig.migrate(db); // first apply
      final report = mig.migrate(db); // second apply — must no-op

      expect(report.fromVersion, equals(1));
      expect(report.toVersion, equals(1));
      expect(report.applied, isEmpty);
      expect(report.didApplyAny, isFalse);

      // The migrations table still has exactly one row — the second
      // call did not duplicate.
      final count = db
          .select('SELECT COUNT(*) AS c FROM migrations')
          .first['c'] as int;
      expect(count, equals(1));
    });
  });

  group('A.28 SchemaMigrator chained-registry behaviour (fake v2)', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() => db.dispose());

    // A synthetic v2 applier that adds a trivial table and writes
    // the migrations row exactly the way applySchemaV1 does. Test-
    // local — not part of the production registry.
    void fakeApplyV2(Database db) {
      db.execute('BEGIN');
      try {
        db.execute(
          'CREATE TABLE IF NOT EXISTS _v2_marker_table (id INTEGER PRIMARY KEY)',
        );
        final now = DateTime.now().toUtc();
        db.execute(
          'INSERT OR IGNORE INTO migrations '
          '(version, applied_at_ms, applied_at_iso, summary) '
          'VALUES (?, ?, ?, ?)',
          <Object?>[
            2,
            now.millisecondsSinceEpoch,
            now.toIso8601String(),
            'fake v2 — adds _v2_marker_table',
          ],
        );
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }

    SchemaMigrator chainedMigrator() {
      return SchemaMigrator(
        migrations: <SchemaMigration>[
          SchemaMigration(
            version: schemaV1Version,
            summary: schemaV1Summary,
            apply: applySchemaV1,
          ),
          SchemaMigration(
            version: 2,
            summary: 'fake v2 — adds _v2_marker_table',
            apply: fakeApplyV2,
          ),
        ],
      );
    }

    test('fresh DB → both v1 and v2 applied in order', () {
      final report = chainedMigrator().migrate(db);

      expect(report.fromVersion, equals(0));
      expect(report.toVersion, equals(2));
      expect(report.applied.map((m) => m.version), equals(<int>[1, 2]));

      // Both v1 tables AND the v2 marker table are present.
      final tables = _tableNames(db);
      expect(tables, contains('nodes')); // v1
      expect(tables, contains('_v2_marker_table')); // v2

      // Both rows recorded in migrations table.
      final rows = db.select(
        'SELECT version FROM migrations ORDER BY version',
      );
      expect(
        rows.map((r) => r['version'] as int).toList(),
        equals(<int>[1, 2]),
      );
    });

    test('already-at-v1 DB → only v2 applied', () {
      // Bootstrap to v1 with the production migrator first.
      SchemaMigrator().migrate(db);
      expect(readSchemaVersion(db), equals(1));

      // Now run the chained migrator — only v2 should apply.
      final report = chainedMigrator().migrate(db);
      expect(report.fromVersion, equals(1));
      expect(report.toVersion, equals(2));
      expect(report.applied.map((m) => m.version), equals(<int>[2]));

      // v2 marker table is now present.
      expect(_tableNames(db), contains('_v2_marker_table'));
      expect(readSchemaVersion(db), equals(2));
    });

    test('already-at-v2 DB → no migrations applied', () {
      chainedMigrator().migrate(db);
      final report = chainedMigrator().migrate(db);

      expect(report.fromVersion, equals(2));
      expect(report.toVersion, equals(2));
      expect(report.applied, isEmpty);
      expect(report.didApplyAny, isFalse);
    });
  });

  group('A.28 SchemaMigrator forward-only refusal', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
      // Bring the DB up to v1 and then manually plant a v99 row to
      // simulate "written by a much newer binary".
      SchemaMigrator().migrate(db);
      final now = DateTime.now().toUtc();
      db.execute(
        'INSERT OR IGNORE INTO migrations '
        '(version, applied_at_ms, applied_at_iso, summary) '
        'VALUES (?, ?, ?, ?)',
        <Object?>[
          99,
          now.millisecondsSinceEpoch,
          now.toIso8601String(),
          'planted v99 row from a future binary',
        ],
      );
      expect(readSchemaVersion(db), equals(99));
    });

    tearDown(() => db.dispose());

    test('migrate throws SchemaVersionAhead when DB is ahead', () {
      expect(
        () => SchemaMigrator().migrate(db),
        throwsA(isA<SchemaVersionAhead>()
            .having((e) => e.databaseVersion, 'databaseVersion', 99)
            .having((e) => e.latestKnownVersion, 'latestKnownVersion', 1)),
      );
    });

    test('refused migrate does not mutate the DB', () {
      final tablesBefore = _tableNames(db);
      try {
        SchemaMigrator().migrate(db);
        fail('expected SchemaVersionAhead');
      } on SchemaVersionAhead {
        // expected
      }
      final tablesAfter = _tableNames(db);
      expect(tablesAfter, equals(tablesBefore));
    });

    test('SchemaVersionAhead.toString mentions both versions', () {
      // The exception is operator-facing; the message must explain
      // what was rejected.
      const exn =
          SchemaVersionAhead(databaseVersion: 99, latestKnownVersion: 1);
      final s = exn.toString();
      expect(s, contains('99'));
      expect(s, contains('1'));
      expect(s.toLowerCase(), contains('forward-only'));
    });
  });

  group('A.28 SchemaMigrator mid-chain failure', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() => db.dispose());

    test('v2 failure leaves v1 committed; v2 row absent', () {
      void failingV2(Database db) {
        db.execute('BEGIN');
        try {
          // Deliberately broken DDL — sqlite will throw.
          db.execute('CREATE TABLE _bad (this is not valid sql)');
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }

      final mig = SchemaMigrator(
        migrations: <SchemaMigration>[
          SchemaMigration(
            version: schemaV1Version,
            summary: schemaV1Summary,
            apply: applySchemaV1,
          ),
          SchemaMigration(
            version: 2,
            summary: 'v2 (failing)',
            apply: failingV2,
          ),
        ],
      );

      expect(() => mig.migrate(db), throwsA(isA<Object>()));

      // v1 remains committed — independent transactions per version.
      expect(readSchemaVersion(db), equals(1));
      expect(_tableNames(db), contains('nodes'));

      // Exactly one row in migrations (v1 only).
      final rows = db.select('SELECT version FROM migrations ORDER BY version');
      expect(
        rows.map((r) => r['version'] as int).toList(),
        equals(<int>[1]),
      );
    });
  });

  group('A.28 SchemaMigrationReport shape', () {
    test('didApplyAny matches applied.isNotEmpty', () {
      final emptyReport = SchemaMigrationReport(
        fromVersion: 1,
        toVersion: 1,
        applied: const <SchemaMigration>[],
        startedAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
        finishedAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
      );
      expect(emptyReport.didApplyAny, isFalse);

      final nonEmptyReport = SchemaMigrationReport(
        fromVersion: 0,
        toVersion: 1,
        applied: <SchemaMigration>[
          SchemaMigration(version: 1, summary: 'x', apply: (_) {}),
        ],
        startedAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
        finishedAt: DateTime.utc(2026, 5, 30, 12, 0, 1),
      );
      expect(nonEmptyReport.didApplyAny, isTrue);
    });

    test('duration is non-negative', () {
      final report = SchemaMigrationReport(
        fromVersion: 0,
        toVersion: 1,
        applied: const <SchemaMigration>[],
        startedAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
        finishedAt: DateTime.utc(2026, 5, 30, 12, 0, 5),
      );
      expect(report.duration, equals(const Duration(seconds: 5)));
    });

    test('applied list is unmodifiable', () {
      final report = SchemaMigrationReport(
        fromVersion: 0,
        toVersion: 1,
        applied: <SchemaMigration>[
          SchemaMigration(version: 1, summary: 'x', apply: (_) {}),
        ],
        startedAt: DateTime.utc(2026, 5, 30),
        finishedAt: DateTime.utc(2026, 5, 30),
      );
      expect(
        () => report.applied.add(
          SchemaMigration(version: 2, summary: 'y', apply: (_) {}),
        ),
        throwsUnsupportedError,
      );
    });

    test('clock injection drives report timestamps', () {
      // Pin time via the constructor's `clock` parameter so the
      // report's timestamps are deterministic.
      final times = <DateTime>[
        DateTime.utc(2026, 5, 30, 9, 0, 0), // started
        DateTime.utc(2026, 5, 30, 9, 0, 7), // finished
      ];
      var idx = 0;
      final mig = SchemaMigrator(clock: () => times[idx++]);

      final db = sqlite3.openInMemory();
      try {
        final report = mig.migrate(db);
        expect(report.startedAt, equals(times[0]));
        expect(report.finishedAt, equals(times[1]));
        expect(report.duration, equals(const Duration(seconds: 7)));
      } finally {
        db.dispose();
      }
    });
  });

  group('A.28 SchemaMigration toString', () {
    test('mentions version and summary', () {
      final m = SchemaMigration(
        version: 7,
        summary: 'add embedding-model registry',
        apply: (_) {},
      );
      final s = m.toString();
      expect(s, contains('7'));
      expect(s, contains('add embedding-model registry'));
    });
  });
}

/// Returns the set of user-table names in [db], excluding sqlite
/// internal tables. Mirrors the helper in `schema_v1_test.dart`.
Set<String> _tableNames(Database db) {
  final rows = db.select(
    "SELECT name FROM sqlite_master "
    "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}
