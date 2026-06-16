// schema_v2 migration test (memory-optimization plan step 1).
//
// Locks the forward-only `schema_v2` migration that adds the node usage
// columns (`memory_specification.md` § 12.2.1):
//
//   1. Forward migration over a populated v1 DB
//      - The three columns (`last_access_ms`, `last_access_iso`,
//        `access_count`) exist on `nodes` after the migration.
//      - The recency index `idx_nodes_last_access_ms` exists.
//      - Backfill: every pre-existing row has `last_access_ms ==
//        created_at_ms`, `last_access_iso == created_at_iso`, and
//        `access_count == 0`.
//      - The `migrations` table records v2.
//
//   2. Idempotency / re-run safety
//      - Re-applying v2 against a v2 DB is a no-op (no "duplicate
//        column" error, migrations count unchanged).
//      - A re-run never clobbers real access data: a row whose
//        `last_access_ms` was advanced past its creation time keeps
//        that value across a second apply.
//
//   3. Through the real migrator
//      - The canonical `kSchemaMigrations` chains v0 → v1 → v2 and
//        leaves the DB at v2 with the columns + index present.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  late Database db;

  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.dispose());

  /// Inserts a v1-shaped node row with the given creation timestamp.
  void insertV1Node(
    String id, {
    required int createdAtMs,
    required String createdAtIso,
  }) {
    db.execute(
      'INSERT INTO nodes '
      '(id, type_name, scope_json, attrs_json, status, '
      ' created_at_ms, created_at_iso, updated_at_ms, updated_at_iso) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        id,
        'Claim',
        '{}',
        '{"statement":"x"}',
        'active',
        createdAtMs,
        createdAtIso,
        createdAtMs,
        createdAtIso,
      ],
    );
  }

  Set<String> nodeColumns() => <String>{
        for (final row in db.select('PRAGMA table_info(nodes)'))
          row['name'] as String,
      };

  bool indexExists(String name) => db
      .select(
        "SELECT name FROM sqlite_master WHERE type='index' AND name = ?",
        <Object?>[name],
      )
      .isNotEmpty;

  group('schema_v2 forward migration over a populated v1 DB', () {
    test('adds the usage columns + index and backfills from created_at', () {
      // Start at v1 with two pre-existing nodes.
      applySchemaV1(db);
      insertV1Node('n_a', createdAtMs: 1000, createdAtIso: '2026-01-01T00:00:00.000Z');
      insertV1Node('n_b', createdAtMs: 2000, createdAtIso: '2026-01-02T00:00:00.000Z');

      applySchemaV2(db);

      // Columns present.
      expect(
        nodeColumns(),
        containsAll(<String>['last_access_ms', 'last_access_iso', 'access_count']),
      );

      // Index present.
      expect(indexExists('idx_nodes_last_access_ms'), isTrue);

      // Backfill: last_access mirrors created_at; access_count is 0.
      final rows = db.select(
        'SELECT id, created_at_ms, created_at_iso, '
        '       last_access_ms, last_access_iso, access_count '
        'FROM nodes ORDER BY id',
      );
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['last_access_ms'], equals(row['created_at_ms']));
        expect(row['last_access_iso'], equals(row['created_at_iso']));
        expect(row['access_count'], equals(0));
      }

      // The migration is recorded.
      final versions = db
          .select('SELECT version FROM migrations ORDER BY version')
          .map((r) => r['version'] as int)
          .toList();
      expect(versions, equals(<int>[1, 2]));
    });
  });

  group('schema_v2 idempotency / re-run safety', () {
    test('re-applying v2 is a no-op (no duplicate-column error)', () {
      applySchemaV1(db);
      insertV1Node('n_a', createdAtMs: 1000, createdAtIso: '2026-01-01T00:00:00.000Z');
      applySchemaV2(db);

      // Second apply must not throw and must not duplicate the row.
      expect(() => applySchemaV2(db), returnsNormally);

      final count =
          db.select('SELECT COUNT(*) AS c FROM migrations').first['c'] as int;
      expect(count, equals(2));
      expect(nodeColumns(), containsAll(<String>['last_access_ms', 'access_count']));
    });

    test('a re-run never clobbers real access data', () {
      applySchemaV1(db);
      insertV1Node('n_a', createdAtMs: 1000, createdAtIso: '2026-01-01T00:00:00.000Z');
      applySchemaV2(db);

      // Simulate a real access recorded after the first migration.
      db.execute(
        'UPDATE nodes SET last_access_ms = ?, last_access_iso = ?, '
        'access_count = ? WHERE id = ?',
        <Object?>[9999, '2026-03-01T00:00:00.000Z', 7, 'n_a'],
      );

      // A second apply (e.g. a crash-retry that reaches the backfill)
      // must leave the advanced values untouched — the backfill only
      // touches NULL rows.
      applySchemaV2(db);

      final row = db.select(
        'SELECT last_access_ms, last_access_iso, access_count '
        'FROM nodes WHERE id = ?',
        <Object?>['n_a'],
      ).first;
      expect(row['last_access_ms'], equals(9999));
      expect(row['last_access_iso'], equals('2026-03-01T00:00:00.000Z'));
      expect(row['access_count'], equals(7));
    });
  });

  group('schema_v2 through the real migrator', () {
    test('kSchemaMigrations chains v0 → v2 with columns + index present', () {
      final report = SchemaMigrator().migrate(db);

      expect(report.fromVersion, equals(0));
      expect(report.toVersion, equals(2));
      expect(report.applied.map((m) => m.version), equals(<int>[1, 2]));

      expect(
        nodeColumns(),
        containsAll(<String>['last_access_ms', 'last_access_iso', 'access_count']),
      );
      expect(indexExists('idx_nodes_last_access_ms'), isTrue);
    });
  });
}
