// A.29 boot-integrity contract test.
//
// Locks the boot-time integrity check surface:
//
//   1. Default probes against a real in-memory SQLite
//      - schemaVersion         → ok after migration.
//      - fts5Available         → ok (workspace baseline ships FTS5).
//      - loadExtensionCapable  → ok OR failed; either way the probe
//                                returns a definite verdict (not
//                                skipped, not thrown).
//      - embeddingModelMarker  → skipped, with Q-A.26.2 reference.
//
//   2. `run()` always returns a complete report
//      - Even when injected probes fail, no exception escapes `run`.
//      - `BootIntegrityReport.throwIfFailed()` is the dedicated raise
//        path; calling it on a failure-bearing report throws
//        `BootIntegrityFailure`; calling it on a clean report is a
//        no-op.
//
//   3. SchemaVersionAhead propagates from `run()` unchanged
//      - A DB at v99 with a v1 migrator surfaces `SchemaVersionAhead`,
//        not a wrapped probe failure.
//
//   4. Report aggregation
//      - `failures` / `skipped` / `passed` partition the probe list.
//      - `hasFailures` matches `failures.isNotEmpty`.
//      - The `probes` list is unmodifiable.
//      - `schemaMigration` is the migrator's own report.
//
//   5. Injectable wiring
//      - Custom probes replace the defaults exactly.
//      - Custom migrator (with a fake v2) drives the schema-version
//        probe through the chained path.
//      - Injectable clock pins `startedAt` / `finishedAt`.
//
//   6. Failure object
//      - `BootIntegrityFailure.toString()` lists every failing probe's
//        name and summary on its own line.
//
//   7. Marker-path convention
//      - `kEmbeddingModelMarkerFileName` is the documented constant.
//      - `embeddingModelMarkerPath(dir)` resolves under the directory's
//        absolute root.

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

Directory _tempDir(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

MemoryDirectory _freshMemoryDirectory(String label) {
  final parent = _tempDir('tbm_a29_${label}_');
  final root = '${parent.path}${Platform.pathSeparator}brain';
  return MemoryDirectory.openOrCreate(
    MemoryConfig.forTesting(root: root),
  );
}

MemoryConfig _testConfig(MemoryDirectory dir) =>
    MemoryConfig.forTesting(root: dir.root);

void main() {
  group('A.29 default probes against in-memory SQLite', () {
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
    });

    tearDown(() => db.dispose());

    test('defaultFts5Probe returns ok on the workspace SQLite build', () {
      final r = defaultFts5Probe(db);
      expect(r.name, equals('fts5Available'));
      expect(r.status, equals(IntegrityProbeStatus.ok),
          reason: 'workspace baseline sqlite3 must ship FTS5');
      expect(r.isOk, isTrue);
      expect(r.cause, isNull);
    });

    test(
        'defaultLoadExtensionProbe returns a definite verdict '
        '(ok or failed, never skipped)', () {
      final r = defaultLoadExtensionProbe(db);
      expect(r.name, equals('loadExtensionCapable'));
      expect(
        r.status,
        anyOf(
          equals(IntegrityProbeStatus.ok),
          equals(IntegrityProbeStatus.failed),
        ),
        reason: 'capability is binary; the probe must answer',
      );
      expect(r.isSkipped, isFalse);
    });

    test(
        'defaultLoadExtensionProbe agrees with this build\'s actual '
        'load_extension availability', () {
      // Ground truth, read straight from the live build: extension loading
      // exists unless OMIT_LOAD_EXTENSION was compiled in. This holds on every
      // host — Apple's system SQLite omits it, Homebrew's and
      // sqlite3_flutter_libs' builds do not — so the assertion is a real
      // agreement check rather than a host-specific expectation.
      final omitted = db.select(
            "SELECT sqlite_compileoption_used('OMIT_LOAD_EXTENSION') AS x",
          ).first['x'] ==
          1;

      expect(defaultLoadExtensionProbe(db).isOk, equals(!omitted));
    });

    // The verdict logic is tested apart from the live build because no single
    // host can exhibit every signature: the workspace baseline is whichever
    // SQLite the running process resolved. Driving the classifier directly
    // covers the builds this code must get right without owning three of them.
    group('classifyLoadExtensionCapability', () {
      IntegrityProbeResult classify({
        required bool omit,
        required bool enable,
        required bool fn,
      }) =>
          classifyLoadExtensionCapability(
            omitCompiledIn: omit,
            enableCompiledIn: enable,
            functionAvailable: fn,
          );

      test('a stock build is capable even though ENABLE_LOAD_EXTENSION is 0',
          () {
        // Homebrew sqlite 3.53.3, measured: omit=0, enable=0, load_extension
        // prepares. SQLite enables extension loading by default and only
        // *removes* it under OMIT_LOAD_EXTENSION, so ENABLE_LOAD_EXTENSION
        // being unset proves nothing. Treating it as the verdict rejects every
        // stock build.
        final r = classify(omit: false, enable: false, fn: true);
        expect(r.name, equals('loadExtensionCapable'));
        expect(r.isOk, isTrue);
      });

      test('OMIT_LOAD_EXTENSION is the definitive negative', () {
        // Apple's system SQLite, measured: omit=1, enable=0, and the
        // load_extension SQL function does not exist.
        final r = classify(omit: true, enable: false, fn: false);
        expect(r.isFailed, isTrue);
        expect(r.summary, contains('OMIT_LOAD_EXTENSION'));
      });

      test('OMIT wins over every positive signal', () {
        expect(classify(omit: true, enable: true, fn: true).isFailed, isTrue);
      });

      test('an explicit ENABLE define is honoured on its own', () {
        // sqlite3_flutter_libs compiles the define in; keep accepting it even
        // if the function probe could not be run.
        expect(classify(omit: false, enable: true, fn: false).isOk, isTrue);
      });

      test('no capability signal at all → failed', () {
        expect(classify(omit: false, enable: false, fn: false).isFailed, isTrue);
      });
    });

    test('defaultEmbeddingMarkerProbe returns skipped with Q-A.26.2 reference',
        () {
      final dir = _freshMemoryDirectory('marker');
      final cfg = _testConfig(dir);
      final r = defaultEmbeddingMarkerProbe(dir, cfg);
      expect(r.name, equals('embeddingModelMarker'));
      expect(r.status, equals(IntegrityProbeStatus.skipped));
      expect(r.isSkipped, isTrue);
      expect(r.summary, contains('A.50+'));
      expect(r.summary, contains('Q-A.26.2'));
    });
  });

  group('A.29 BootIntegrityCheck.run on a real in-memory DB', () {
    late Database db;
    late MemoryDirectory dir;
    late MemoryConfig cfg;

    setUp(() {
      db = sqlite3.openInMemory();
      dir = _freshMemoryDirectory('run');
      cfg = _testConfig(dir);
    });

    tearDown(() => db.dispose());

    test('fresh DB migrates to latest; all real probes converge', () {
      final report = BootIntegrityCheck().run(
        memoryDb: db,
        directory: dir,
        config: cfg,
      );

      // Migration record.
      expect(report.schemaMigration.fromVersion, equals(0));
      expect(report.schemaMigration.toVersion, equals(2));
      expect(report.schemaMigration.didApplyAny, isTrue);

      // Exactly four probes, in the order the plan lists them.
      expect(
        report.probes.map((p) => p.name).toList(),
        equals(<String>[
          'schemaVersion',
          'fts5Available',
          'loadExtensionCapable',
          'embeddingModelMarker',
        ]),
      );

      // schemaVersion + fts5Available are guaranteed ok on this
      // workspace baseline; loadExtension may legitimately be ok or
      // failed depending on the SQLite build; the marker is skipped.
      final byName = {for (final p in report.probes) p.name: p};
      expect(byName['schemaVersion']!.isOk, isTrue);
      expect(byName['fts5Available']!.isOk, isTrue);
      expect(byName['embeddingModelMarker']!.isSkipped, isTrue);
      expect(byName['loadExtensionCapable']!.isSkipped, isFalse);
    });

    test('already-at-latest DB → migration no-op, probes unchanged', () {
      // Bring DB to the latest version in a separate migrator call so
      // the second run() sees an already-migrated DB.
      SchemaMigrator().migrate(db);

      final report = BootIntegrityCheck().run(
        memoryDb: db,
        directory: dir,
        config: cfg,
      );

      expect(report.schemaMigration.fromVersion, equals(2));
      expect(report.schemaMigration.toVersion, equals(2));
      expect(report.schemaMigration.didApplyAny, isFalse);

      // Probes still run and report identically.
      expect(report.probes, hasLength(4));
      final byName = {for (final p in report.probes) p.name: p};
      expect(byName['schemaVersion']!.isOk, isTrue);
      expect(byName['fts5Available']!.isOk, isTrue);
      expect(byName['embeddingModelMarker']!.isSkipped, isTrue);
    });
  });

  group('A.29 SchemaVersionAhead propagation', () {
    late Database db;
    late MemoryDirectory dir;
    late MemoryConfig cfg;

    setUp(() {
      db = sqlite3.openInMemory();
      dir = _freshMemoryDirectory('ahead');
      cfg = _testConfig(dir);

      // Bring DB to v1, then plant a v99 row to simulate a DB written
      // by a much newer binary (same setup as schema_migrator_test).
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
    });

    tearDown(() => db.dispose());

    test('run() lets SchemaVersionAhead propagate unchanged', () {
      expect(
        () => BootIntegrityCheck().run(
          memoryDb: db,
          directory: dir,
          config: cfg,
        ),
        throwsA(isA<SchemaVersionAhead>()
            .having((e) => e.databaseVersion, 'databaseVersion', 99)
            .having((e) => e.latestKnownVersion, 'latestKnownVersion', 2)),
      );
    });
  });

  group('A.29 injectable probes', () {
    late Database db;
    late MemoryDirectory dir;
    late MemoryConfig cfg;

    setUp(() {
      db = sqlite3.openInMemory();
      dir = _freshMemoryDirectory('inject');
      cfg = _testConfig(dir);
    });

    tearDown(() => db.dispose());

    test('all-failing probes → report carries failures, no throw from run',
        () {
      IntegrityProbeResult fail(String name) => IntegrityProbeResult(
            name: name,
            status: IntegrityProbeStatus.failed,
            summary: 'injected failure for $name',
          );

      final check = BootIntegrityCheck(
        fts5Probe: (_) => fail('fts5Available'),
        loadExtensionProbe: (_) => fail('loadExtensionCapable'),
        embeddingMarkerProbe: (_, _) => fail('embeddingModelMarker'),
      );

      final report = check.run(
        memoryDb: db,
        directory: dir,
        config: cfg,
      );

      // Migration still ran (it precedes the probes); only the
      // probes themselves failed.
      expect(report.schemaMigration.toVersion, equals(2));

      // schemaVersion (the static probe) is ok; the three injected
      // probes are failed.
      expect(report.failures.map((p) => p.name).toList(), equals(<String>[
        'fts5Available',
        'loadExtensionCapable',
        'embeddingModelMarker',
      ]));
      expect(report.passed.map((p) => p.name).toList(),
          equals(<String>['schemaVersion']));
      expect(report.skipped, isEmpty);
      expect(report.hasFailures, isTrue);
    });

    test('injected ok marker probe → marker probe reports ok', () {
      final check = BootIntegrityCheck(
        embeddingMarkerProbe: (_, _) => const IntegrityProbeResult(
          name: 'embeddingModelMarker',
          status: IntegrityProbeStatus.ok,
          summary: 'test override: marker present and matches',
        ),
      );

      final report = check.run(
        memoryDb: db,
        directory: dir,
        config: cfg,
      );

      final marker =
          report.probes.firstWhere((p) => p.name == 'embeddingModelMarker');
      expect(marker.isOk, isTrue);
      expect(marker.summary, contains('marker present'));
      expect(report.skipped, isEmpty);
    });

    test('injected probe receives the same db / directory / config', () {
      late Database seenDb;
      late MemoryDirectory seenDir;
      late MemoryConfig seenCfg;

      final check = BootIntegrityCheck(
        fts5Probe: (d) {
          seenDb = d;
          return const IntegrityProbeResult(
            name: 'fts5Available',
            status: IntegrityProbeStatus.ok,
            summary: 'observed',
          );
        },
        embeddingMarkerProbe: (d, c) {
          seenDir = d;
          seenCfg = c;
          return const IntegrityProbeResult(
            name: 'embeddingModelMarker',
            status: IntegrityProbeStatus.ok,
            summary: 'observed',
          );
        },
      );

      check.run(memoryDb: db, directory: dir, config: cfg);

      expect(identical(seenDb, db), isTrue);
      expect(identical(seenDir, dir), isTrue);
      expect(identical(seenCfg, cfg), isTrue);
    });

    test(
        'injected migrator with fake v2 advances DB and reports through '
        'schemaVersion probe', () {
      void fakeApplyV2(Database d) {
        d.execute('BEGIN');
        try {
          d.execute('CREATE TABLE IF NOT EXISTS _v2_marker '
              '(id INTEGER PRIMARY KEY)');
          final now = DateTime.now().toUtc();
          d.execute(
            'INSERT OR IGNORE INTO migrations '
            '(version, applied_at_ms, applied_at_iso, summary) '
            'VALUES (?, ?, ?, ?)',
            <Object?>[
              2,
              now.millisecondsSinceEpoch,
              now.toIso8601String(),
              'fake v2',
            ],
          );
          d.execute('COMMIT');
        } catch (_) {
          d.execute('ROLLBACK');
          rethrow;
        }
      }

      final chainedMigrator = SchemaMigrator(
        migrations: <SchemaMigration>[
          SchemaMigration(
            version: schemaV1Version,
            summary: schemaV1Summary,
            apply: applySchemaV1,
          ),
          SchemaMigration(
            version: 2,
            summary: 'fake v2',
            apply: fakeApplyV2,
          ),
        ],
      );

      final report = BootIntegrityCheck(migrator: chainedMigrator).run(
        memoryDb: db,
        directory: dir,
        config: cfg,
      );

      expect(report.schemaMigration.toVersion, equals(2));
      final schema =
          report.probes.firstWhere((p) => p.name == 'schemaVersion');
      expect(schema.isOk, isTrue);
      expect(schema.summary, contains('v2'));
    });

    test('clock injection pins startedAt and finishedAt', () {
      final times = <DateTime>[
        DateTime.utc(2026, 5, 30, 10, 0, 0),
        DateTime.utc(2026, 5, 30, 10, 0, 4),
      ];
      var idx = 0;

      final check = BootIntegrityCheck(clock: () => times[idx++]);
      final report = check.run(
        memoryDb: db,
        directory: dir,
        config: cfg,
      );

      expect(report.startedAt, equals(times[0]));
      expect(report.finishedAt, equals(times[1]));
      expect(report.duration, equals(const Duration(seconds: 4)));
    });
  });

  group('A.29 BootIntegrityReport surface', () {
    test('throwIfFailed is a no-op on a clean report', () {
      final report = BootIntegrityReport(
        schemaMigration: SchemaMigrationReport(
          fromVersion: 0,
          toVersion: 1,
          applied: const <SchemaMigration>[],
          startedAt: DateTime.utc(2026, 5, 30),
          finishedAt: DateTime.utc(2026, 5, 30),
        ),
        probes: const <IntegrityProbeResult>[
          IntegrityProbeResult(
            name: 'schemaVersion',
            status: IntegrityProbeStatus.ok,
            summary: 'ok',
          ),
          IntegrityProbeResult(
            name: 'embeddingModelMarker',
            status: IntegrityProbeStatus.skipped,
            summary: 'deferred',
          ),
        ],
        startedAt: DateTime.utc(2026, 5, 30, 9),
        finishedAt: DateTime.utc(2026, 5, 30, 9, 0, 1),
      );

      // Must not throw.
      report.throwIfFailed();

      expect(report.hasFailures, isFalse);
      expect(report.failures, isEmpty);
      expect(report.passed.map((p) => p.name), equals(<String>['schemaVersion']));
      expect(report.skipped.map((p) => p.name),
          equals(<String>['embeddingModelMarker']));
    });

    test('throwIfFailed raises BootIntegrityFailure when any probe failed',
        () {
      final report = BootIntegrityReport(
        schemaMigration: SchemaMigrationReport(
          fromVersion: 0,
          toVersion: 1,
          applied: const <SchemaMigration>[],
          startedAt: DateTime.utc(2026, 5, 30),
          finishedAt: DateTime.utc(2026, 5, 30),
        ),
        probes: const <IntegrityProbeResult>[
          IntegrityProbeResult(
            name: 'fts5Available',
            status: IntegrityProbeStatus.failed,
            summary: 'FTS5 missing',
          ),
        ],
        startedAt: DateTime.utc(2026, 5, 30),
        finishedAt: DateTime.utc(2026, 5, 30),
      );

      expect(
        report.throwIfFailed,
        throwsA(isA<BootIntegrityFailure>().having(
          (e) => e.failures.length,
          'failures.length',
          1,
        )),
      );
    });

    test('probes list is unmodifiable', () {
      final report = BootIntegrityReport(
        schemaMigration: SchemaMigrationReport(
          fromVersion: 0,
          toVersion: 1,
          applied: const <SchemaMigration>[],
          startedAt: DateTime.utc(2026, 5, 30),
          finishedAt: DateTime.utc(2026, 5, 30),
        ),
        probes: <IntegrityProbeResult>[
          const IntegrityProbeResult(
            name: 'schemaVersion',
            status: IntegrityProbeStatus.ok,
            summary: 'ok',
          ),
        ],
        startedAt: DateTime.utc(2026, 5, 30),
        finishedAt: DateTime.utc(2026, 5, 30),
      );

      expect(
        () => report.probes.add(
          const IntegrityProbeResult(
            name: 'extra',
            status: IntegrityProbeStatus.ok,
            summary: 'should not be addable',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('duration is non-negative and matches start/finish difference', () {
      final report = BootIntegrityReport(
        schemaMigration: SchemaMigrationReport(
          fromVersion: 0,
          toVersion: 1,
          applied: const <SchemaMigration>[],
          startedAt: DateTime.utc(2026, 5, 30),
          finishedAt: DateTime.utc(2026, 5, 30),
        ),
        probes: const <IntegrityProbeResult>[],
        startedAt: DateTime.utc(2026, 5, 30, 12, 0, 0),
        finishedAt: DateTime.utc(2026, 5, 30, 12, 0, 6),
      );
      expect(report.duration, equals(const Duration(seconds: 6)));
    });
  });

  group('A.29 BootIntegrityFailure surface', () {
    test('toString lists every failing probe on its own line', () {
      const failure = BootIntegrityFailure(
        failures: <IntegrityProbeResult>[
          IntegrityProbeResult(
            name: 'fts5Available',
            status: IntegrityProbeStatus.failed,
            summary: 'no FTS5 module',
          ),
          IntegrityProbeResult(
            name: 'loadExtensionCapable',
            status: IntegrityProbeStatus.failed,
            summary: 'ENABLE_LOAD_EXTENSION not compiled in',
          ),
        ],
      );

      final s = failure.toString();
      expect(s, contains('2 integrity probe(s) failed'));
      expect(s, contains('fts5Available'));
      expect(s, contains('no FTS5 module'));
      expect(s, contains('loadExtensionCapable'));
      expect(s, contains('ENABLE_LOAD_EXTENSION not compiled in'));
    });
  });

  group('A.29 marker-path convention', () {
    test('kEmbeddingModelMarkerFileName is the documented constant', () {
      expect(kEmbeddingModelMarkerFileName, equals('.embedding-model'));
    });

    test('embeddingModelMarkerPath resolves under the directory root', () {
      final dir = _freshMemoryDirectory('marker_path');
      final path = embeddingModelMarkerPath(dir);
      expect(path,
          equals('${dir.root}${Platform.pathSeparator}.embedding-model'));
    });
  });

  group('A.29 IntegrityProbeResult shape', () {
    test('toString includes name, status, and summary', () {
      const r = IntegrityProbeResult(
        name: 'fts5Available',
        status: IntegrityProbeStatus.ok,
        summary: 'available',
      );
      final s = r.toString();
      expect(s, contains('fts5Available'));
      expect(s, contains('available'));
      expect(s, contains('ok'));
    });

    test('status-derived helpers (isOk / isFailed / isSkipped) are exclusive',
        () {
      const ok = IntegrityProbeResult(
        name: 'x',
        status: IntegrityProbeStatus.ok,
        summary: '',
      );
      const failed = IntegrityProbeResult(
        name: 'x',
        status: IntegrityProbeStatus.failed,
        summary: '',
      );
      const skipped = IntegrityProbeResult(
        name: 'x',
        status: IntegrityProbeStatus.skipped,
        summary: '',
      );

      expect([ok.isOk, ok.isFailed, ok.isSkipped],
          equals(<bool>[true, false, false]));
      expect([failed.isOk, failed.isFailed, failed.isSkipped],
          equals(<bool>[false, true, false]));
      expect([skipped.isOk, skipped.isFailed, skipped.isSkipped],
          equals(<bool>[false, false, true]));
    });
  });
}
