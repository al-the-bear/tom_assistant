// A.72 — JsonFileMigrationApi behaviour test.
//
// Locks the contract documented at the top of
// `lib/src/migrations/json_file_migration_api.dart` plus
// `memory_specification.md` § 11:
//
//   1. `start(decl)` materialises `<root>/checkpoints/restructure_<id>.json`.
//   2. `start` is idempotent on `migrationId`; the second call accepts
//      summary / perCycleBudget updates but preserves cursor-side state.
//   3. `cursor(id)` returns `null` when no migration is registered, and
//      `null` while a registered migration has not yet checkpointed.
//   4. `saveCursor(id, position)` persists across api instances —
//      simulating a process restart.
//   5. `saveCursor` mirrors the `processed` / `complete` / `total`
//      convention keys onto the dedicated `MigrationStatus` fields.
//   6. `saveCursor` on an unregistered id throws `StateError` — no
//      file is written.
//   7. `status(id)` reports `progress = processed / total`, falling
//      back to `0.0` when `total == 0`.
//   8. `listInProgress` walks the checkpoints directory, sorts by
//      migrationId, and skips complete migrations.
//   9. Atomic rewrite leaves no temp files behind on the happy path.
//  10. A corrupt JSON file is treated as missing (no throw) — spec
//      § 11.4 allows non-completion; a corrupt checkpoint must not
//      crash a status sweep.
//  11. `migrationId` validation: empty, too long, leading dot,
//      path-traversal characters all rejected with `ArgumentError`
//      before any I/O.
//  12. `start` rejects empty `summary` and non-positive
//      `perCycleBudget`.
//  13. Calling `start` on a fresh id under a *different* api instance
//      backed by the same directory rebuilds from disk.

import 'dart:convert';
import 'dart:io';

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

MemoryDirectory _openMemoryDir(String prefix) {
  final parent = _tempDir(prefix);
  final root = '${parent.path}${Platform.pathSeparator}brain';
  return MemoryDirectory.openOrCreate(
    MemoryConfig.forTesting(root: root),
  );
}

MigrationDecl _decl({
  String id = 'restructure_question_2026_v1',
  String summary = 'Reclassify Question nodes',
  int budget = 200,
}) {
  return MigrationDecl(
    migrationId: id,
    summary: summary,
    candidates: const StreamQuery(filter: SymbolicFilter()),
    perCycleBudget: budget,
  );
}

/// Tiny clock that lets a test advance time deterministically between
/// `start` / `saveCursor` calls so `lastCycleAt` assertions are crisp.
class _StubClock {
  DateTime _now;
  _StubClock(this._now);
  DateTime call() => _now;
  void advance(Duration d) {
    _now = _now.add(d);
  }
}

void main() {
  group('A.72 JsonFileMigrationApi.start', () {
    test('creates the on-disk record for a fresh id', () async {
      final dir = _openMemoryDir('tbm_a72_start_');
      final api = JsonFileMigrationApi(directory: dir);

      await api.start(_decl());

      final file = File('${dir.checkpointsDir}'
          '${Platform.pathSeparator}'
          'restructure_restructure_question_2026_v1.json');
      expect(file.existsSync(), isTrue,
          reason: 'start() must materialise the checkpoints file');

      final decoded = jsonDecode(file.readAsStringSync()) as Map;
      expect(decoded['schemaVersion'], equals(1));
      expect(decoded['migrationId'],
          equals('restructure_question_2026_v1'));
      expect(decoded['summary'], equals('Reclassify Question nodes'));
      expect(decoded['perCycleBudget'], equals(200));
      expect(decoded['complete'], isFalse);
      expect(decoded['processedCount'], equals(0));
      expect(decoded['totalEstimate'], equals(0));
      expect(decoded['startedAt'], isA<String>());
      // Cursor-side fields absent until the first saveCursor.
      expect(decoded.containsKey('lastCycleAt'), isFalse);
      expect(decoded.containsKey('position'), isFalse);
    });

    test('is idempotent on migrationId — preserves cursor state', () async {
      final dir = _openMemoryDir('tbm_a72_start_idem_');
      final api = JsonFileMigrationApi(directory: dir);

      await api.start(_decl(summary: 'v1 summary', budget: 100));
      await api.saveCursor(
        'restructure_question_2026_v1',
        <String, Object?>{
          'processed': 42,
          'last_seen_id': 'node_42',
        },
      );

      // Re-call with a rev'd declaration.
      await api.start(_decl(summary: 'v2 summary', budget: 250));

      final status =
          await api.status('restructure_question_2026_v1');
      expect(status, isNotNull);
      expect(status!.processed, equals(42),
          reason: 'idempotent start must preserve processedCount');
      expect(status.lastCycleAt, isNotNull,
          reason: 'idempotent start must preserve lastCycleAt');

      final cursor =
          await api.cursor('restructure_question_2026_v1');
      expect(cursor, isNotNull);
      expect(cursor!.position['last_seen_id'], equals('node_42'),
          reason: 'idempotent start must preserve position payload');

      // The new summary / budget take effect on the file.
      final file = File('${dir.checkpointsDir}'
          '${Platform.pathSeparator}'
          'restructure_restructure_question_2026_v1.json');
      final decoded = jsonDecode(file.readAsStringSync()) as Map;
      expect(decoded['summary'], equals('v2 summary'));
      expect(decoded['perCycleBudget'], equals(250));
    });

    test('rejects empty summary', () async {
      final dir = _openMemoryDir('tbm_a72_start_emptysum_');
      final api = JsonFileMigrationApi(directory: dir);
      expect(
        () => api.start(_decl(summary: '')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects perCycleBudget <= 0', () async {
      final dir = _openMemoryDir('tbm_a72_start_badbudget_');
      final api = JsonFileMigrationApi(directory: dir);
      expect(
        () => api.start(_decl(budget: 0)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => api.start(_decl(budget: -1)),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('A.72 JsonFileMigrationApi.cursor', () {
    test('returns null for an unregistered migrationId', () async {
      final dir = _openMemoryDir('tbm_a72_cursor_missing_');
      final api = JsonFileMigrationApi(directory: dir);
      expect(await api.cursor('never_started_v1'), isNull);
    });

    test('returns null for a registered migration with no checkpoint',
        () async {
      final dir = _openMemoryDir('tbm_a72_cursor_nocheckpoint_');
      final api = JsonFileMigrationApi(directory: dir);
      await api.start(_decl());
      expect(
        await api.cursor('restructure_question_2026_v1'),
        isNull,
        reason: 'cursor() returns null until the first saveCursor',
      );
    });

    test('survives a process restart (new api instance, same dir)',
        () async {
      final dir = _openMemoryDir('tbm_a72_cursor_durable_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      final firstApi =
          JsonFileMigrationApi(directory: dir, clock: clock.call);
      await firstApi.start(_decl());

      clock.advance(const Duration(minutes: 5));
      await firstApi.saveCursor(
        'restructure_question_2026_v1',
        <String, Object?>{
          'processed': 1400,
          'last_seen_id': 'node_1400',
          'tier': 'B',
        },
      );

      // Simulate a process restart — fresh api over the same dir.
      final secondApi =
          JsonFileMigrationApi(directory: dir, clock: clock.call);
      final restored =
          await secondApi.cursor('restructure_question_2026_v1');
      expect(restored, isNotNull);
      expect(restored!.migrationId,
          equals('restructure_question_2026_v1'));
      expect(restored.position['last_seen_id'], equals('node_1400'));
      expect(restored.position['tier'], equals('B'));
      expect(restored.savedAt,
          equals(DateTime.utc(2026, 5, 30, 12, 5)));
    });
  });

  group('A.72 JsonFileMigrationApi.saveCursor', () {
    test('throws StateError when no migration is registered', () async {
      final dir = _openMemoryDir('tbm_a72_save_noreg_');
      final api = JsonFileMigrationApi(directory: dir);
      expect(
        () => api.saveCursor(
          'ghost_v1',
          <String, Object?>{'processed': 1},
        ),
        throwsA(isA<StateError>()),
      );
      // No file should have been written.
      final dirHandle = Directory(dir.checkpointsDir);
      expect(dirHandle.listSync().whereType<File>().isEmpty, isTrue);
    });

    test('mirrors processed/complete/total convention keys', () async {
      final dir = _openMemoryDir('tbm_a72_save_convention_');
      final api = JsonFileMigrationApi(directory: dir);
      await api.start(_decl());

      await api.saveCursor(
        'restructure_question_2026_v1',
        <String, Object?>{
          'processed': 50,
          'total': 1000,
          // 'complete' deliberately absent → stays false.
        },
      );

      var s = await api.status('restructure_question_2026_v1');
      expect(s, isNotNull);
      expect(s!.processed, equals(50));
      expect(s.total, equals(1000));
      expect(s.complete, isFalse);
      expect(s.progress, closeTo(0.05, 1e-9));

      await api.saveCursor(
        'restructure_question_2026_v1',
        <String, Object?>{
          'processed': 1000,
          'complete': true,
        },
      );
      s = await api.status('restructure_question_2026_v1');
      expect(s!.processed, equals(1000));
      expect(s.total, equals(1000),
          reason: 'absent total key must retain prior value');
      expect(s.complete, isTrue);
      expect(s.progress, closeTo(1.0, 1e-9));
    });

    test('ignores malformed convention values', () async {
      final dir = _openMemoryDir('tbm_a72_save_malformed_');
      final api = JsonFileMigrationApi(directory: dir);
      await api.start(_decl());
      await api.saveCursor(
        'restructure_question_2026_v1',
        <String, Object?>{
          'processed': -3, // negative — must be ignored
          'complete': 'yes', // wrong type — must be ignored
          'total': 'lots', // wrong type — must be ignored
        },
      );

      final s = await api.status('restructure_question_2026_v1');
      expect(s!.processed, equals(0));
      expect(s.complete, isFalse);
      expect(s.total, equals(0));
    });

    test('writes are atomic — no temp files left behind', () async {
      final dir = _openMemoryDir('tbm_a72_save_atomic_');
      final api = JsonFileMigrationApi(directory: dir);
      await api.start(_decl());
      for (var i = 0; i < 5; i++) {
        await api.saveCursor(
          'restructure_question_2026_v1',
          <String, Object?>{'processed': i, 'last_seen_id': 'n_$i'},
        );
      }
      final files = Directory(dir.checkpointsDir)
          .listSync()
          .whereType<File>()
          .toList();
      // Exactly one canonical file; no `.tmp.*` leftovers.
      expect(files, hasLength(1));
      expect(files.single.path,
          endsWith('restructure_restructure_question_2026_v1.json'));
    });
  });

  group('A.72 JsonFileMigrationApi.status', () {
    test('returns null for an unknown migrationId', () async {
      final dir = _openMemoryDir('tbm_a72_status_missing_');
      final api = JsonFileMigrationApi(directory: dir);
      expect(await api.status('never_v1'), isNull);
    });

    test('returns 0 progress before any saveCursor has landed',
        () async {
      final dir = _openMemoryDir('tbm_a72_status_zero_');
      final api = JsonFileMigrationApi(directory: dir);
      await api.start(_decl());
      final s = await api.status('restructure_question_2026_v1');
      expect(s, isNotNull);
      expect(s!.processed, equals(0));
      expect(s.total, equals(0));
      expect(s.progress, equals(0.0));
      expect(s.lastCycleAt, isNull);
    });
  });

  group('A.72 JsonFileMigrationApi.listInProgress', () {
    test('returns empty list when no migrations exist', () async {
      final dir = _openMemoryDir('tbm_a72_list_empty_');
      final api = JsonFileMigrationApi(directory: dir);
      expect(await api.listInProgress(), isEmpty);
    });

    test('skips complete migrations and sorts by migrationId',
        () async {
      final dir = _openMemoryDir('tbm_a72_list_sort_');
      final api = JsonFileMigrationApi(directory: dir);
      await api.start(_decl(id: 'mig_c'));
      await api.start(_decl(id: 'mig_a'));
      await api.start(_decl(id: 'mig_b'));

      await api.saveCursor('mig_b', <String, Object?>{
        'processed': 10,
        'complete': true, // → excluded
      });
      await api.saveCursor('mig_a', <String, Object?>{
        'processed': 3,
      });

      final inProgress = await api.listInProgress();
      expect(inProgress.map((s) => s.migrationId).toList(),
          equals(<String>['mig_a', 'mig_c']));
    });

    test('ignores unrelated files in the checkpoints directory',
        () async {
      final dir = _openMemoryDir('tbm_a72_list_filter_');
      final api = JsonFileMigrationApi(directory: dir);
      await api.start(_decl(id: 'mig_a'));

      File('${dir.checkpointsDir}${Platform.pathSeparator}README.md')
          .writeAsStringSync('# notes');
      File('${dir.checkpointsDir}'
              '${Platform.pathSeparator}restructure_only_prefix')
          .writeAsStringSync('not a json file');

      final inProgress = await api.listInProgress();
      expect(inProgress, hasLength(1));
      expect(inProgress.single.migrationId, equals('mig_a'));
    });

    test('treats corrupt JSON files as missing — does not throw',
        () async {
      final dir = _openMemoryDir('tbm_a72_list_corrupt_');
      final api = JsonFileMigrationApi(directory: dir);

      // A "happy" registration plus a corrupt sibling file.
      await api.start(_decl(id: 'mig_ok'));
      File('${dir.checkpointsDir}'
              '${Platform.pathSeparator}restructure_mig_bad.json')
          .writeAsStringSync('{not valid json');

      // Both should be skippable without an exception.
      final inProgress = await api.listInProgress();
      expect(inProgress.map((s) => s.migrationId).toList(),
          equals(<String>['mig_ok']));

      expect(await api.status('mig_bad'), isNull,
          reason: 'corrupt file must look like missing to status()');
      expect(await api.cursor('mig_bad'), isNull,
          reason: 'corrupt file must look like missing to cursor()');
    });
  });

  group('A.72 JsonFileMigrationApi — migrationId validation', () {
    test('rejects empty id', () async {
      final dir = _openMemoryDir('tbm_a72_id_empty_');
      final api = JsonFileMigrationApi(directory: dir);
      expect(() => api.start(_decl(id: '')),
          throwsA(isA<ArgumentError>()));
      expect(() => api.cursor(''), throwsA(isA<ArgumentError>()));
      expect(() => api.status(''), throwsA(isA<ArgumentError>()));
      expect(
        () =>
            api.saveCursor('', const <String, Object?>{'processed': 1}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects ids longer than 128 characters', () async {
      final dir = _openMemoryDir('tbm_a72_id_toolong_');
      final api = JsonFileMigrationApi(directory: dir);
      final tooLong = 'a' * 129;
      expect(() => api.start(_decl(id: tooLong)),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects ids that would enable path traversal', () async {
      final dir = _openMemoryDir('tbm_a72_id_traversal_');
      final api = JsonFileMigrationApi(directory: dir);
      for (final bad in <String>[
        '../escape',
        'sub/dir',
        r'win\back',
        '.hidden',
        'has space',
        'bell\u0007',
      ]) {
        expect(
          () => api.start(_decl(id: bad)),
          throwsA(isA<ArgumentError>()),
          reason: 'expected ArgumentError for id "$bad"',
        );
      }
    });

    test('accepts conservative dotted / dashed ids', () async {
      final dir = _openMemoryDir('tbm_a72_id_ok_');
      final api = JsonFileMigrationApi(directory: dir);
      for (final ok in <String>[
        'a',
        'mig_a',
        'mig-a',
        'mig.a',
        'mig_a.v1-rev2',
      ]) {
        await api.start(_decl(id: ok));
      }
      final names = Directory(api.checkpointsDir)
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .toList()
        ..sort();
      expect(names, equals(<String>[
        'restructure_a.json',
        'restructure_mig-a.json',
        'restructure_mig.a.json',
        'restructure_mig_a.json',
        'restructure_mig_a.v1-rev2.json',
      ]));
    });
  });
}
