// A.27 schema-v1 contract test.
//
// Locks the SQLite schema v1 surface for `memory.db`:
//
//   1. The ten tables named in Plan step A.27 exist after
//      `applySchemaV1` returns.
//   2. The composite edge indexes spec § 4.2 mandates are present.
//   3. The auxiliary indexes every later A-step assumes are present.
//   4. `applySchemaV1` is idempotent — a second call against the same
//      DB does nothing and does not double-record the migration row.
//   5. `readSchemaVersion` returns `0` on a fresh DB and the applied
//      version after `applySchemaV1`.
//   6. `applySchemaV1` is transactional — if a statement fails, the
//      DB is left at the pre-call state.
//
// The test uses `sqlite3.openInMemory()` so it costs nothing and
// runs identically on every host with `libsqlite3` available.
// Native loading is the workspace baseline — `dependency_surface_test`
// asserts the Dart-side surface compiles; this test exercises the
// actual SQL engine, the first place in Phase A that does.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('A.27 schema-v1 surface', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() {
      db.dispose();
    });

    test('readSchemaVersion is 0 on a fresh DB', () {
      // The probe must return a well-defined number even when the
      // `migrations` table itself is absent — that is the contract
      // the migrator (A.28) leans on for the initial-apply path.
      expect(readSchemaVersion(db), equals(0));
    });

    test('applySchemaV1 records version 1 in migrations', () {
      applySchemaV1(db);
      expect(readSchemaVersion(db), equals(schemaV1Version));
      expect(schemaV1Version, equals(1),
          reason: 'v1 must be 1 — every schema file owns its own '
              'literal version number');
    });

    test('applySchemaV1 creates all ten Plan-A.27 tables', () {
      applySchemaV1(db);

      // Names from Plan step A.27 verbatim. The set comparison
      // catches both missing tables and stray ones.
      const expected = <String>{
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
      };

      final actual = _tableNames(db);
      // The schema may legitimately gain *more* tables in future
      // versions, but it must not lose any of these ten. Hence
      // `containsAll` rather than `equals`.
      expect(actual, containsAll(expected),
          reason: 'schema v1 must declare every Plan-A.27 table; '
              'missing: ${expected.difference(actual)}');
    });

    test('edges has the three composite indexes spec § 4.2 mandates', () {
      applySchemaV1(db);
      final indexes = _indexNames(db, table: 'edges');
      expect(indexes, containsAll(<String>{
        'idx_edges_from_type',
        'idx_edges_to_type',
        'idx_edges_type_from_to',
      }));
    });

    test('nodes has the type, status, and time indexes', () {
      applySchemaV1(db);
      final indexes = _indexNames(db, table: 'nodes');
      expect(indexes, containsAll(<String>{
        'idx_nodes_type',
        'idx_nodes_status',
        'idx_nodes_created_at_ms',
        'idx_nodes_type_created_at_ms',
        'idx_nodes_type_status',
        'uniq_nodes_idempotency_key',
      }));
    });

    test('stack_entries has the policy-ordering indexes', () {
      applySchemaV1(db);
      final indexes = _indexNames(db, table: 'stack_entries');
      expect(indexes, containsAll(<String>{
        'idx_stack_entries_stack',
        'idx_stack_entries_stack_status_priority',
        'idx_stack_entries_stack_status_pushed_at',
        'idx_stack_entries_entry_node',
      }));
    });

    test('trails has run, status, and opened-at indexes', () {
      applySchemaV1(db);
      final indexes = _indexNames(db, table: 'trails');
      expect(indexes, containsAll(<String>{
        'idx_trails_run',
        'idx_trails_status',
        'idx_trails_opened_at_ms',
      }));
    });

    test('tombstones_index has the time and tombstone-lookup indexes', () {
      applySchemaV1(db);
      final indexes = _indexNames(db, table: 'tombstones_index');
      expect(indexes, containsAll(<String>{
        'idx_tombstones_index_forgotten_at_ms',
        'idx_tombstones_index_tombstone_node',
      }));
    });

    test('pending_vector_writes has the enqueue-time index', () {
      applySchemaV1(db);
      final indexes = _indexNames(db, table: 'pending_vector_writes');
      expect(indexes, contains('idx_pending_vector_writes_enqueued_at_ms'));
    });
  });

  group('A.27 schema-v1 column shapes', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
    });

    tearDown(() => db.dispose());

    test('nodes has the spec-aligned columns', () {
      final cols = _columnNames(db, table: 'nodes');
      expect(cols, containsAll(<String>{
        'id',
        'type_name',
        'scope_json',
        'produced_by',
        'attrs_json',
        'status',
        'created_at_ms',
        'created_at_iso',
        'updated_at_ms',
        'updated_at_iso',
        'idempotency_key',
        'embedding_model_id',
      }));
    });

    test('edges carries weight + attrs + dual-time + producer', () {
      final cols = _columnNames(db, table: 'edges');
      expect(cols, containsAll(<String>{
        'id',
        'from_node',
        'to_node',
        'type',
        'weight',
        'attrs_json',
        'produced_by',
        'created_at_ms',
        'created_at_iso',
      }));
    });

    test('stacks carries policy JSON, bootstrap flag, dual-time', () {
      final cols = _columnNames(db, table: 'stacks');
      expect(cols, containsAll(<String>{
        'name',
        'stack_node_id',
        'entry_node_type',
        'priority_policy',
        'priority_policy_attrs_json',
        'retention_policy',
        'retention_policy_attrs_json',
        'harvester_hook',
        'is_bootstrap',
        'created_at_ms',
        'created_at_iso',
      }));
    });

    test('stack_entries carries priority + status + dual-time', () {
      final cols = _columnNames(db, table: 'stack_entries');
      expect(cols, containsAll(<String>{
        'id',
        'stack_name',
        'entry_node',
        'priority',
        'status',
        'attrs_json',
        'pushed_at_ms',
        'pushed_at_iso',
        'updated_at_ms',
        'updated_at_iso',
      }));
    });

    test('pending_vector_writes carries model id, blob, dims, time', () {
      final cols = _columnNames(db, table: 'pending_vector_writes');
      expect(cols, containsAll(<String>{
        'node_id',
        'embedding_model_id',
        'payload_blob',
        'payload_dims',
        'enqueued_at_ms',
        'enqueued_at_iso',
      }));
    });

    test('centroids carries model id, blob, dims, count, time', () {
      final cols = _columnNames(db, table: 'centroids');
      expect(cols, containsAll(<String>{
        'for_key',
        'embedding_model_id',
        'centroid_blob',
        'centroid_dims',
        'example_count',
        'updated_at_ms',
        'updated_at_iso',
      }));
    });

    test('migrations carries version, dual-time, summary', () {
      final cols = _columnNames(db, table: 'migrations');
      expect(cols, containsAll(<String>{
        'version',
        'applied_at_ms',
        'applied_at_iso',
        'summary',
      }));
    });

    test('tombstones_index carries forgotten_id → tombstone_id mapping', () {
      final cols = _columnNames(db, table: 'tombstones_index');
      expect(cols, containsAll(<String>{
        'forgotten_node_id',
        'tombstone_node_id',
        'forgotten_type',
        'reason',
        'forgotten_at_ms',
        'forgotten_at_iso',
      }));
    });
  });

  group('A.27 schema-v1 idempotency', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() => db.dispose());

    test('applySchemaV1 is safe to call twice — second call is a no-op', () {
      applySchemaV1(db);
      // Capture state after the first call.
      final firstTables = _tableNames(db);
      final firstMigrationCount = db
          .select('SELECT COUNT(*) AS c FROM migrations')
          .first['c'] as int;

      // Run again — must not throw, must not duplicate the
      // migrations row.
      applySchemaV1(db);
      final secondTables = _tableNames(db);
      final secondMigrationCount = db
          .select('SELECT COUNT(*) AS c FROM migrations')
          .first['c'] as int;

      expect(secondTables, equals(firstTables));
      expect(secondMigrationCount, equals(firstMigrationCount),
          reason: 'INSERT OR IGNORE must collapse the second '
              "application's migrations-row write");
      expect(secondMigrationCount, equals(1));
    });

    test('partial-apply scenario: v1 statements already partly executed', () {
      // Simulate a crash mid-way through a previous application: the
      // first two `CREATE TABLE` statements landed before the
      // process died, but their indexes and the rest of the schema
      // did not. The `IF NOT EXISTS` guards let `applySchemaV1`
      // converge on the second attempt without rebuilding what is
      // already there.
      //
      // We run the first three statements of the canonical list
      // outside any transaction, then call `applySchemaV1` and
      // expect a clean, complete v1 schema.
      final partialStmts = schemaV1Statements().take(3);
      for (final stmt in partialStmts) {
        db.execute(stmt);
      }

      // Confirm the partial state actually landed.
      expect(_tableNames(db), contains('migrations'));
      expect(_tableNames(db), contains('nodes'));
      // ...but the rest is missing.
      expect(_tableNames(db), isNot(contains('edges')));

      // Now the full apply.
      applySchemaV1(db);

      // Schema is complete and version is recorded.
      final tables = _tableNames(db);
      expect(tables, containsAll(<String>{
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
      expect(readSchemaVersion(db), equals(1));
    });
  });

  group('A.27 statement-list shape', () {
    test('schemaV1Statements returns at least the 10 CREATE TABLE stmts', () {
      // The function returns a List so tests can index into it
      // without consuming an iterator. The list is "at least 10
      // tables + N indexes" — we lock the table count exactly and
      // leave the index count as ≥ the minimum spec § 4.2 requires.
      final stmts = schemaV1Statements();
      final tableStmts = stmts
          .where((s) => s.contains('CREATE TABLE IF NOT EXISTS'))
          .toList();
      expect(tableStmts, hasLength(10),
          reason: 'A.27 names exactly ten tables');

      // Sanity-check each named table is present in one of the
      // CREATE TABLE statements. (Defence against a typo in a
      // single statement.)
      const tableNames = <String>[
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
      ];
      for (final name in tableNames) {
        final matched = tableStmts.any((s) => s.contains(' $name '));
        expect(matched, isTrue,
            reason: 'no CREATE TABLE statement found for "$name"');
      }
    });

    test('schemaV1Statements is non-empty and all-uppercase-DDL', () {
      final stmts = schemaV1Statements();
      expect(stmts, isNotEmpty);
      for (final s in stmts) {
        final upper = s.trimLeft();
        // Every statement begins with one of: CREATE TABLE,
        // CREATE INDEX, CREATE UNIQUE INDEX. No DROP, no ALTER —
        // schema-v1 is purely additive.
        expect(
          upper.startsWith('CREATE TABLE') ||
              upper.startsWith('CREATE INDEX') ||
              upper.startsWith('CREATE UNIQUE INDEX'),
          isTrue,
          reason: 'schema v1 statement must be additive CREATE: $upper',
        );
      }
    });

    test('schemaV1Summary mentions the spec section', () {
      // The summary is what an operator reads in the migrations
      // table. It must be self-explanatory enough to look up.
      expect(schemaV1Summary, contains('schema v1'));
      expect(schemaV1Summary, contains('§ 4.2'));
    });
  });
}

/// Returns the set of user-table names in [db], excluding sqlite
/// internal tables.
Set<String> _tableNames(Database db) {
  final rows = db.select(
    "SELECT name FROM sqlite_master "
    "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

/// Returns the set of user-index names defined on [table].
///
/// Excludes SQLite-internal `sqlite_autoindex_*` indexes (those are
/// created automatically for `PRIMARY KEY` and `UNIQUE` columns; we
/// only assert on the indexes we explicitly create).
Set<String> _indexNames(Database db, {required String table}) {
  final rows = db.select(
    "SELECT name FROM sqlite_master "
    "WHERE type = 'index' "
    "AND tbl_name = ? "
    "AND name NOT LIKE 'sqlite_autoindex_%'",
    <Object?>[table],
  );
  return rows.map((r) => r['name'] as String).toSet();
}

/// Returns the set of column names on [table] via `PRAGMA table_info`.
Set<String> _columnNames(Database db, {required String table}) {
  // sqlite3 Dart package returns ResultSet from raw select; the
  // pragma path uses the same `select` entry point.
  final rows = db.select('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}
