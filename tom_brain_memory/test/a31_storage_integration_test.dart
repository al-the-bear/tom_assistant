// A.31 — storage-stack integration test.
//
// Plan step A.31:
//   "Tests: open/close idempotency, schema bump from v0 (empty) to v1,
//    FTS5 unavailable error path, two-DB transaction replay."
//
// A.26–A.30 each ship their own unit-level test file that exercises one
// piece in isolation against `sqlite3.openInMemory()`. A.31 is the
// integration layer: it binds the five pieces together against a real
// on-disk `memory.db` file (the way the production opener will at
// A.32+) and exercises the four named scenarios end-to-end.
//
// What this file proves that the per-step files do not:
//
//   1. Open/close idempotency
//      The per-step files all use `sqlite3.openInMemory()`, which by
//      definition forgets everything on close. Here we open a real
//      file, materialise schema v1, close the handle, re-open the
//      same file, and assert the schema persists. The same dance is
//      repeated three times to make "idempotency" a property of the
//      file, not just of the in-memory connection.
//
//   2. Schema bump from v0 (empty) to v1 — on disk
//      The migrator test in `schema_migrator_test.dart` already proves
//      v0 → v1 against an in-memory DB. The on-disk variant verifies
//      that the migration is durable: re-opening the file shows
//      `readSchemaVersion == 1` with no migration applied on the
//      second pass.
//
//   3. FTS5 unavailable error path
//      `boot_integrity_test.dart` injects all-failing probes; here we
//      inject *only* the FTS5 probe as failed and prove the integrated
//      path: the boot runs against the real on-disk DB, migration still
//      lands, the report carries one failure, `throwIfFailed` raises
//      `BootIntegrityFailure`, and the failure message names
//      `fts5Available` as the specific probe that refused.
//
//   4. Two-DB transaction replay — across an on-disk DB close
//      `two_db_coordinator_test.dart` simulates a crash by tearing down
//      a coordinator and building a fresh one against the *same*
//      in-memory DB handle. Here we go one step further: the failing
//      session writes to a real on-disk `memory.db`, closes the handle,
//      and the recovery session opens the file afresh and replays the
//      pending row. This is the true crash model — a process restart,
//      not just an object lifecycle.
//
// The file deliberately re-exercises the public surface only. No
// internal helpers, no test-only seams, nothing that would let a
// refactor break this test without also breaking real callers.

import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Creates a temp parent and registers a `tearDown` that removes it.
Directory _tempParent(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

/// Returns the set of user-table names in [db], excluding sqlite
/// internal tables. Mirrors the helper in `schema_v1_test.dart` and
/// `schema_migrator_test.dart`.
Set<String> _tableNames(Database db) {
  final rows = db.select(
    "SELECT name FROM sqlite_master "
    "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

/// The ten tables schema v1 ships, copied here so the assertion is
/// self-describing in the failure message.
const Set<String> _v1Tables = <String>{
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

void main() {
  // ──────────────────────────────────────────────────────────────────
  // Scenario 1: open/close idempotency
  // ──────────────────────────────────────────────────────────────────

  group('A.31 open/close idempotency (on-disk memory.db)', () {
    test(
        'open → schema v1 → close → re-open → still v1 → close → re-open '
        '→ still v1 (no migration applied on the later opens)', () {
      final parent = _tempParent('tbm_a31_oc_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final cfg = MemoryConfig.forTesting(root: root);

      // First open materialises the directory.
      final dir1 = MemoryDirectory.openOrCreate(cfg);
      expect(dir1.wasCreated, isTrue);
      expect(dir1.isFresh, isTrue,
          reason: 'no DB files yet — the first open must report fresh');

      // First DB open: bring the file up to v1 via the migrator.
      final db1 = sqlite3.open(dir1.memoryDbPath);
      try {
        final report1 = SchemaMigrator().migrate(db1);
        expect(report1.fromVersion, equals(0));
        expect(report1.toVersion, equals(1));
        expect(report1.didApplyAny, isTrue);
        expect(_tableNames(db1), containsAll(_v1Tables));
      } finally {
        db1.dispose();
      }

      // The file must now exist on disk.
      expect(File(dir1.memoryDbPath).existsSync(), isTrue,
          reason: 'sqlite3.open should have materialised the file');

      // Second open of the *same root* — directory reports wasCreated
      // == false; the DB file is no longer fresh.
      final dir2 = MemoryDirectory.openOrCreate(cfg);
      expect(dir2.wasCreated, isFalse,
          reason: 're-opening an existing root is a no-op at the directory '
              'layer');
      expect(dir2, equals(dir1),
          reason: 'MemoryDirectory equality is by root path');
      expect(dir2.memoryDbExists, isTrue);
      expect(dir2.isFresh, isFalse);

      // Second DB open: migrator must be a no-op.
      final db2 = sqlite3.open(dir2.memoryDbPath);
      try {
        final report2 = SchemaMigrator().migrate(db2);
        expect(report2.fromVersion, equals(1));
        expect(report2.toVersion, equals(1));
        expect(report2.applied, isEmpty);
        expect(report2.didApplyAny, isFalse,
            reason: 'a re-open of a v1 file must not apply any migration');

        // The migrations table still has exactly one row.
        final count = db2
            .select('SELECT COUNT(*) AS c FROM migrations')
            .first['c'] as int;
        expect(count, equals(1));

        // All ten tables still present.
        expect(_tableNames(db2), containsAll(_v1Tables));
      } finally {
        db2.dispose();
      }

      // Third open: same story. The point of repeating is to prove
      // that "idempotent" is a property of the file across an
      // arbitrary number of close+open cycles, not a coincidence of
      // the second pass.
      final dir3 = MemoryDirectory.openOrCreate(cfg);
      expect(dir3.wasCreated, isFalse);

      final db3 = sqlite3.open(dir3.memoryDbPath);
      try {
        expect(readSchemaVersion(db3), equals(1));
        final report3 = SchemaMigrator().migrate(db3);
        expect(report3.didApplyAny, isFalse);
        expect(_tableNames(db3), containsAll(_v1Tables));
      } finally {
        db3.dispose();
      }
    });

    test(
        'directory subdirectories survive close-and-re-open of the DB '
        'handle', () {
      // The three operational subdirectories are created at directory-
      // open time, not at DB-open time. Re-opening the SQLite handle
      // must not perturb them.
      final parent = _tempParent('tbm_a31_subdirs_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final cfg = MemoryConfig.forTesting(root: root);
      final dir = MemoryDirectory.openOrCreate(cfg);

      final db = sqlite3.open(dir.memoryDbPath);
      SchemaMigrator().migrate(db);
      db.dispose();

      for (final sub in [dir.trailsDir, dir.tombstonesDir, dir.checkpointsDir]) {
        expect(Directory(sub).existsSync(), isTrue,
            reason: 'subdir vanished after first DB cycle: $sub');
      }

      // Re-open the directory + DB; subdirs unchanged.
      final dir2 = MemoryDirectory.openOrCreate(cfg);
      final db2 = sqlite3.open(dir2.memoryDbPath);
      db2.dispose();

      for (final sub in [
        dir2.trailsDir,
        dir2.tombstonesDir,
        dir2.checkpointsDir,
      ]) {
        expect(Directory(sub).existsSync(), isTrue,
            reason: 'subdir vanished after second DB cycle: $sub');
      }
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // Scenario 2: schema bump from v0 (empty) to v1
  // ──────────────────────────────────────────────────────────────────

  group('A.31 schema bump v0 (empty) → v1 (on-disk memory.db)', () {
    test(
        'a freshly-created memory.db file is v0; the migrator brings it '
        'to v1 and the bump is durable', () {
      final parent = _tempParent('tbm_a31_bump_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );

      // First open of a never-touched file: schema version is 0
      // *before* the migrator runs. We assert this explicitly because
      // the v0 = "empty" semantics is part of the contract that lets
      // the migrator detect "fresh DB" without a separate marker.
      final db = sqlite3.open(dir.memoryDbPath);
      try {
        expect(readSchemaVersion(db), equals(0),
            reason: 'a never-migrated file must read as v0 — the migrator '
                'uses this to detect a fresh DB');
        // No tables exist yet — the migrations table itself is not
        // created until applySchemaV1 runs.
        expect(_tableNames(db), isEmpty);

        final report = SchemaMigrator().migrate(db);
        expect(report.fromVersion, equals(0));
        expect(report.toVersion, equals(1));
        expect(report.applied.map((m) => m.version), equals(<int>[1]));
        expect(report.didApplyAny, isTrue);

        // Exactly one row was written to the migrations table.
        final rows = db.select('SELECT version FROM migrations');
        expect(rows.length, equals(1));
        expect(rows.first['version'], equals(1));

        // All ten v1 tables present.
        expect(_tableNames(db), containsAll(_v1Tables));
      } finally {
        db.dispose();
      }

      // Durability check: re-open the same file in a *new* sqlite3
      // process-local handle and confirm the bump survived.
      final db2 = sqlite3.open(dir.memoryDbPath);
      try {
        expect(readSchemaVersion(db2), equals(1),
            reason: 'the v0 → v1 bump must survive a close+reopen');
        expect(_tableNames(db2), containsAll(_v1Tables));
        // A second migration call on the already-v1 file is a no-op.
        final report = SchemaMigrator().migrate(db2);
        expect(report.didApplyAny, isFalse);
        expect(report.fromVersion, equals(1));
        expect(report.toVersion, equals(1));
      } finally {
        db2.dispose();
      }
    });

    test('v0 → v1 bump is observable through the BootIntegrityCheck path',
        () {
      // The boot path is the way the production opener will call the
      // migrator. Exercising it here proves that "v0 → v1" is the
      // visible state transition at the integration layer, not just
      // a property of `SchemaMigrator.migrate` in isolation.
      final parent = _tempParent('tbm_a31_bump_boot_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      final cfg = MemoryConfig.forTesting(root: dir.root);

      final db = sqlite3.open(dir.memoryDbPath);
      try {
        // Inject a pass-through marker probe so the report stays
        // failure-free; FTS5 + loadExtension defaults are fine on the
        // workspace baseline.
        final check = BootIntegrityCheck(
          embeddingMarkerProbe: (_, _) => const IntegrityProbeResult(
            name: 'embeddingModelMarker',
            status: IntegrityProbeStatus.ok,
            summary: 'test override: marker considered present',
          ),
        );
        final report = check.run(memoryDb: db, directory: dir, config: cfg);

        expect(report.schemaMigration.fromVersion, equals(0));
        expect(report.schemaMigration.toVersion, equals(1));
        expect(report.schemaMigration.didApplyAny, isTrue);

        // throwIfFailed must not throw — the failure path is the next
        // scenario.
        report.throwIfFailed();

        // The schema-version probe reports ok.
        final schema = report.probes.firstWhere(
          (p) => p.name == 'schemaVersion',
        );
        expect(schema.isOk, isTrue);
      } finally {
        db.dispose();
      }
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // Scenario 3: FTS5 unavailable error path
  // ──────────────────────────────────────────────────────────────────

  group('A.31 FTS5 unavailable error path (boot refuses to open)', () {
    test(
        'a synthetic FTS5-unavailable build surfaces as a '
        '`BootIntegrityFailure` from `throwIfFailed`', () {
      // The workspace baseline sqlite3 ships with FTS5, so the failure
      // path can only be exercised by injecting a probe. The injection
      // models the production "FTS5 not compiled in" case the plan
      // requires us to test — the boot-integrity surface is the
      // mechanism by which the failure becomes visible to the host.
      final parent = _tempParent('tbm_a31_fts5_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      final cfg = MemoryConfig.forTesting(root: dir.root);

      final db = sqlite3.open(dir.memoryDbPath);
      try {
        final check = BootIntegrityCheck(
          fts5Probe: (_) => const IntegrityProbeResult(
            name: 'fts5Available',
            status: IntegrityProbeStatus.failed,
            summary: 'FTS5 module not compiled into this SQLite build',
          ),
        );

        final report = check.run(memoryDb: db, directory: dir, config: cfg);

        // Migration still ran: probes come *after* migration, so a
        // probe failure does not prevent the schema bump (the bump is
        // still observable in the DB).
        expect(report.schemaMigration.toVersion, equals(1));
        expect(readSchemaVersion(db), equals(1));

        // The report knows there is a failure.
        expect(report.hasFailures, isTrue);
        expect(
          report.failures.map((p) => p.name).toList(),
          equals(<String>['fts5Available']),
        );

        // `throwIfFailed` is the dedicated raise path — the host calls
        // it to refuse to open the store.
        Object? caught;
        try {
          report.throwIfFailed();
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<BootIntegrityFailure>(),
            reason: 'FTS5 missing must be a hard refusal, not a warning');

        final failure = caught as BootIntegrityFailure;
        expect(failure.failures.length, equals(1));
        expect(failure.failures.single.name, equals('fts5Available'));
        expect(
          failure.toString(),
          contains('fts5Available'),
          reason: 'the operator-facing message must name the failing probe',
        );
        expect(
          failure.toString(),
          contains('FTS5 module not compiled into this SQLite build'),
          reason: 'the summary text from the probe must be preserved verbatim',
        );
      } finally {
        db.dispose();
      }
    });

    test(
        'a passing FTS5 probe + failing loadExtension probe partition '
        'the failures correctly', () {
      // The FTS5 path is the named A.31 scenario, but the boot surface
      // should partition the four probes cleanly. This second case
      // pins that down: the host can distinguish *which* invariant
      // refused, not just "something refused".
      final parent = _tempParent('tbm_a31_fts5_partition_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      final cfg = MemoryConfig.forTesting(root: dir.root);

      final db = sqlite3.open(dir.memoryDbPath);
      try {
        final check = BootIntegrityCheck(
          loadExtensionProbe: (_) => const IntegrityProbeResult(
            name: 'loadExtensionCapable',
            status: IntegrityProbeStatus.failed,
            summary: 'ENABLE_LOAD_EXTENSION not compiled in',
          ),
          embeddingMarkerProbe: (_, _) => const IntegrityProbeResult(
            name: 'embeddingModelMarker',
            status: IntegrityProbeStatus.skipped,
            summary: 'deferred to A.50+',
          ),
        );

        final report = check.run(memoryDb: db, directory: dir, config: cfg);

        // FTS5 is *not* in the failures — only loadExtension.
        expect(
          report.failures.map((p) => p.name).toList(),
          equals(<String>['loadExtensionCapable']),
        );
        final passedNames = report.passed.map((p) => p.name).toSet();
        expect(passedNames, contains('fts5Available'));
        expect(passedNames, contains('schemaVersion'));
        expect(report.skipped.map((p) => p.name),
            equals(<String>['embeddingModelMarker']));
      } finally {
        db.dispose();
      }
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // Scenario 4: two-DB transaction replay (across an on-disk close)
  // ──────────────────────────────────────────────────────────────────

  group('A.31 two-DB transaction replay (process-restart model)', () {
    test(
        'failing apply leaves a pending row in the on-disk memory.db; a '
        'fresh process re-opens the file and `recoverPending` replays it',
        () {
      final parent = _tempParent('tbm_a31_replay_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );

      final failing = _FailingVectorApplier(StateError('disk full'));
      final clock = MutableTestClock(BrainTime.utc(2026, 5, 31, 9, 0, 0));

      // Phase 1 — the "crashy" process. Open the file, migrate, write a
      // node whose vector apply throws, then dispose the handle (the
      // proxy for a process exit). The pending row is now on disk; the
      // process is gone.
      {
        final db = sqlite3.open(dir.memoryDbPath);
        try {
          SchemaMigrator().migrate(db);

          final crashy = TwoDbCoordinator(
            memoryDb: db,
            applier: failing,
            clock: clock,
          );

          expect(
            () => crashy.persistNodeWithVector(
              nodeId: 'n_crash',
              writeNode: (db) => _insertMinimalNode(db, id: 'n_crash'),
              vector: _payload(modelId: 'nomic-embed-text', dims: 4),
            ),
            throwsA(isA<StateError>()),
          );

          // Pre-close invariants — the row + pending entry are committed.
          expect(crashy.pendingCount(), equals(1));
          expect(
            db
                .select("SELECT id FROM nodes WHERE id = 'n_crash'")
                .length,
            equals(1),
          );
        } finally {
          db.dispose();
        }
      }

      // Sanity: the file lives on disk; we never touched vectors.db
      // (the applier failed before any vector-side work could happen,
      // and at A.30+ the coordinator does not own vectors.db anyway).
      expect(File(dir.memoryDbPath).existsSync(), isTrue);

      // Phase 2 — the "recovery" process. Re-open the same file, build
      // a coordinator with a healthy applier, call `recoverPending`,
      // and assert convergence: the row replays, the pending entry
      // clears, and both stores are consistent.
      final healthy = _FakeVectorApplier();
      {
        final db = sqlite3.open(dir.memoryDbPath);
        try {
          // The schema is already at v1; migrate must be a no-op here
          // (this is also the open/close-idempotency invariant, but
          // we re-assert in context).
          final migrationReport = SchemaMigrator().migrate(db);
          expect(migrationReport.didApplyAny, isFalse);

          final recovered = TwoDbCoordinator(
            memoryDb: db,
            applier: healthy,
            clock: clock,
          );

          // Before recovery: the pending row from the crashy process
          // is still visible.
          expect(recovered.pendingCount(), equals(1));
          final pending = recovered.listPending();
          expect(pending.single.nodeId, equals('n_crash'));
          expect(pending.single.embeddingModelId, equals('nomic-embed-text'));
          expect(pending.single.payloadDims, equals(4));

          // Replay.
          final report = recovered.recoverPending();
          expect(report.scanned, equals(1));
          expect(report.succeeded, equals(1));
          expect(report.failures, isEmpty);
          expect(report.hasFailures, isFalse);

          // The healthy applier saw the same payload the crashy
          // coordinator originally enqueued.
          expect(healthy.applied.length, equals(1));
          expect(healthy.applied.single.nodeId, equals('n_crash'));
          expect(
            healthy.applied.single.embeddingModelId,
            equals('nomic-embed-text'),
          );
          expect(healthy.applied.single.payloadDims, equals(4));
          // The blob round-tripped intact (16 bytes for 4 float32s).
          expect(healthy.applied.single.payloadBlob.length, equals(16));

          // Pending row is gone — both stores consistent.
          expect(recovered.pendingCount(), equals(0));
          expect(recovered.listPending(), isEmpty);
        } finally {
          db.dispose();
        }
      }

      // Phase 3 — a *third* open of the same file. The point is to
      // verify that the recovery delete is durable; a re-open must
      // observe zero pending rows even without running recovery again.
      {
        final db = sqlite3.open(dir.memoryDbPath);
        try {
          final c = db
              .select('SELECT COUNT(*) AS c FROM pending_vector_writes')
              .first['c'] as int;
          expect(c, equals(0),
              reason: 'recover-and-clear must be durable across re-open');

          // The node row is still present too.
          final nodes = db
              .select("SELECT id FROM nodes WHERE id = 'n_crash'");
          expect(nodes.length, equals(1));
        } finally {
          db.dispose();
        }
      }
    });

    test(
        'replay survives the BootIntegrityCheck path: opener → migrate → '
        'probes → recover', () {
      // The production open sequence (when it lands at A.32+) is:
      //   1. MemoryDirectory.openOrCreate
      //   2. sqlite3.open(memoryDbPath)
      //   3. BootIntegrityCheck.run (migration + probes)
      //   4. coordinator.recoverPending()
      //
      // This test stitches steps 1-4 together for the "crash-leftover"
      // case so we lock the integration order: probes before recovery,
      // recovery before the host's first observable read.

      final parent = _tempParent('tbm_a31_replay_boot_');
      final root = '${parent.path}${Platform.pathSeparator}brain';
      final dir = MemoryDirectory.openOrCreate(
        MemoryConfig.forTesting(root: root),
      );
      final cfg = MemoryConfig.forTesting(root: dir.root);
      final clock = MutableTestClock(BrainTime.utc(2026, 5, 31, 10, 0, 0));

      // Phase 1 — leave a pending row behind via a failing applier.
      {
        final db = sqlite3.open(dir.memoryDbPath);
        try {
          SchemaMigrator().migrate(db);
          final crashy = TwoDbCoordinator(
            memoryDb: db,
            applier: _FailingVectorApplier(StateError('out of disk')),
            clock: clock,
          );
          expect(
            () => crashy.persistNodeWithVector(
              nodeId: 'n_boot_replay',
              writeNode: (db) => _insertMinimalNode(db, id: 'n_boot_replay'),
              vector: _payload(modelId: 'nomic-embed-text', dims: 2),
            ),
            throwsA(isA<StateError>()),
          );
        } finally {
          db.dispose();
        }
      }

      // Phase 2 — the "production-shaped" boot: integrity check first
      // (must be clean), then recovery.
      final healthy = _FakeVectorApplier();
      {
        final db = sqlite3.open(dir.memoryDbPath);
        try {
          final integrity = BootIntegrityCheck(
            embeddingMarkerProbe: (_, _) => const IntegrityProbeResult(
              name: 'embeddingModelMarker',
              status: IntegrityProbeStatus.ok,
              summary: 'test override',
            ),
          );
          final report =
              integrity.run(memoryDb: db, directory: dir, config: cfg);
          // The DB was already at v1 from the crashy phase; integrity
          // should be a no-op migration and pass the probes.
          expect(report.schemaMigration.didApplyAny, isFalse);
          report.throwIfFailed();

          final coordinator = TwoDbCoordinator(
            memoryDb: db,
            applier: healthy,
            clock: clock,
          );
          final replay = coordinator.recoverPending();
          expect(replay.scanned, equals(1));
          expect(replay.succeeded, equals(1));
          expect(replay.failures, isEmpty);

          expect(healthy.applied.length, equals(1));
          expect(healthy.applied.single.nodeId, equals('n_boot_replay'));
          expect(coordinator.pendingCount(), equals(0));
        } finally {
          db.dispose();
        }
      }
    });
  });
}

// ─────────────────────────────────────────────────────────────────────
// Test helpers — mirror those in `two_db_coordinator_test.dart`.
//
// They are duplicated here on purpose. Sharing helpers between unit
// tests and the integration test would create a hidden coupling: the
// integration test exists to verify that the *public* contract holds
// when the pieces are wired together. Importing a private helper from
// a sibling test file would let a refactor break the integration test
// without anyone noticing the seam moved. Duplication, in this case,
// is the cheaper invariant.
// ─────────────────────────────────────────────────────────────────────

/// Inserts a minimal valid row into the `nodes` table for the given id.
void _insertMinimalNode(Database db, {required String id}) {
  db.execute(
    'INSERT INTO nodes '
    '(id, type_name, scope_json, attrs_json, status, '
    'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    <Object?>[
      id,
      'TestType',
      '{}',
      '{}',
      'active',
      0,
      '1970-01-01T00:00:00.000Z',
      0,
      '1970-01-01T00:00:00.000Z',
    ],
  );
}

PendingVectorWritePayload _payload({
  required String modelId,
  required int dims,
}) =>
    PendingVectorWritePayload(
      embeddingModelId: modelId,
      payloadBlob: Uint8List(dims * 4),
      payloadDims: dims,
    );

final class _FakeVectorApplier implements VectorApplier {
  final List<PendingVectorWrite> applied = [];

  @override
  void apply(PendingVectorWrite write) {
    applied.add(write);
  }
}

final class _FailingVectorApplier implements VectorApplier {
  final Object _error;
  int applyCallCount = 0;

  _FailingVectorApplier(this._error);

  @override
  void apply(PendingVectorWrite write) {
    applyCallCount++;
    throw _error;
  }
}
