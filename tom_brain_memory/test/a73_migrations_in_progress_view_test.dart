// A.73 — MigrationsInProgressView behaviour test.
//
// Locks the contract documented at the top of
// `lib/src/migrations/migrations_in_progress_view.dart` plus
// `memory_specification.md` § 11.3:
//
//   1. `snapshot()` over an empty checkpoints dir returns an empty
//      snapshot stamped with the view's clock.
//   2. The snapshot delegates filtering and ordering to
//      `MigrationApi.listInProgress` — complete migrations are
//      excluded, in-progress rows are alphabetically sorted by
//      migrationId.
//   3. `health == neverStarted` when the migration has never
//      checkpointed; `sinceLastCycleMs == null`.
//   4. `health == active` when `lastCycleAt` is within the view's
//      `staleAfter` window; `sinceLastCycleMs` matches the
//      clock-derived age.
//   5. `health == stalled` when `lastCycleAt` predates the
//      `staleAfter` window.
//   6. Exact-boundary case: a row whose age equals `staleAfter` is
//      `active` (the threshold is inclusive).
//   7. `progressPercent` is `(status.progress * 100).round()`,
//      returns 0 when `total <= 0`.
//   8. `snapshot.at` matches the value read from the injected clock
//      at the moment of the call.
//   9. Custom `staleAfter` is honoured (defaults are not hard-coded).
//  10. `staleAfter <= Duration.zero` is rejected with `ArgumentError`
//      at construction time.
//  11. End-to-end against `JsonFileMigrationApi` — the view sees
//      what the dispatcher writes through `start` + `saveCursor`.

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

/// Deterministic clock the view can read repeatedly.
class _StubClock {
  DateTime _now;
  _StubClock(this._now);
  DateTime call() => _now;
  void advance(Duration d) {
    _now = _now.add(d);
  }

  void set(DateTime t) {
    _now = t;
  }
}

/// Hand-rolled `MigrationApi` fake the view tests use when they want
/// to drive `listInProgress` directly without going through file I/O.
/// Keeps the view's contract test independent of `JsonFileMigrationApi`
/// (the test at the end pins the end-to-end behaviour separately).
class _FakeApi implements MigrationApi {
  final List<MigrationStatus> rows;
  int listCalls = 0;
  _FakeApi(this.rows);

  @override
  Future<List<MigrationStatus>> listInProgress() async {
    listCalls += 1;
    return List<MigrationStatus>.unmodifiable(rows);
  }

  // The view never calls these — concrete returns are arbitrary.
  @override
  Future<MigrationCursor?> cursor(String migrationId) async => null;

  @override
  Future<void> saveCursor(
    String migrationId,
    Map<String, Object?> position,
  ) async {}

  @override
  Future<void> start(MigrationDecl decl) async {}

  @override
  Future<MigrationStatus?> status(String migrationId) async => null;
}

MigrationStatus _stat({
  required String id,
  int processed = 0,
  int total = 0,
  bool complete = false,
  DateTime? lastCycleAt,
}) {
  return MigrationStatus(
    migrationId: id,
    processed: processed,
    total: total,
    complete: complete,
    lastCycleAt: lastCycleAt,
  );
}

void main() {
  group('A.73 MigrationsInProgressView — construction', () {
    test('rejects staleAfter <= Duration.zero', () {
      expect(
        () => MigrationsInProgressView(
          api: _FakeApi(const <MigrationStatus>[]),
          staleAfter: Duration.zero,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => MigrationsInProgressView(
          api: _FakeApi(const <MigrationStatus>[]),
          staleAfter: const Duration(seconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('exposes the configured staleAfter window', () {
      final v = MigrationsInProgressView(
        api: _FakeApi(const <MigrationStatus>[]),
        staleAfter: const Duration(minutes: 7),
      );
      expect(v.staleAfter, equals(const Duration(minutes: 7)));
    });

    test('default staleAfter is 30 minutes', () {
      final v = MigrationsInProgressView(
        api: _FakeApi(const <MigrationStatus>[]),
      );
      expect(v.staleAfter, equals(const Duration(minutes: 30)));
      expect(MigrationsInProgressView.defaultStaleAfter,
          equals(const Duration(minutes: 30)));
    });
  });

  group('A.73 MigrationsInProgressView — snapshot shape', () {
    test('empty snapshot when listInProgress returns nothing', () async {
      final clock = _StubClock(DateTime.utc(2026, 5, 31, 9));
      final view = MigrationsInProgressView(
        api: _FakeApi(const <MigrationStatus>[]),
        clock: clock.call,
      );

      final snap = await view.snapshot();
      expect(snap.isEmpty, isTrue);
      expect(snap.isNotEmpty, isFalse);
      expect(snap.length, equals(0));
      expect(snap.rows, isEmpty);
      expect(snap.at, equals(DateTime.utc(2026, 5, 31, 9)));
    });

    test('snapshot.at stamps the clock value read at call time',
        () async {
      final clock = _StubClock(DateTime.utc(2026, 1, 1));
      final view = MigrationsInProgressView(
        api: _FakeApi(const <MigrationStatus>[]),
        clock: clock.call,
      );

      final first = await view.snapshot();
      expect(first.at, equals(DateTime.utc(2026, 1, 1)));

      clock.advance(const Duration(hours: 2));
      final second = await view.snapshot();
      expect(second.at, equals(DateTime.utc(2026, 1, 1, 2)));
    });

    test('delegates row order to listInProgress (no view-side sort)',
        () async {
      // Fake returns out-of-order rows; the view must NOT silently
      // re-sort — sorting is `MigrationApi.listInProgress`'s job.
      final api = _FakeApi(<MigrationStatus>[
        _stat(id: 'mig_c'),
        _stat(id: 'mig_a'),
        _stat(id: 'mig_b'),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        clock: _StubClock(DateTime.utc(2026, 5, 31)).call,
      );
      final snap = await view.snapshot();
      expect(snap.rows.map((r) => r.migrationId).toList(),
          equals(<String>['mig_c', 'mig_a', 'mig_b']));
    });

    test('row.at matches snapshot.at', () async {
      final clock = _StubClock(DateTime.utc(2026, 5, 31, 12));
      final api = _FakeApi(<MigrationStatus>[
        _stat(id: 'mig_a'),
        _stat(id: 'mig_b'),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        clock: clock.call,
      );
      final snap = await view.snapshot();
      for (final row in snap.rows) {
        expect(row.at, equals(snap.at),
            reason: 'row.at must equal snapshot.at');
      }
    });
  });

  group('A.73 MigrationsInProgressView — health classification', () {
    test('neverStarted when lastCycleAt == null', () async {
      final api = _FakeApi(<MigrationStatus>[
        _stat(id: 'mig_neverstarted'),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        clock: _StubClock(DateTime.utc(2026, 5, 31)).call,
      );
      final snap = await view.snapshot();
      expect(snap.rows.single.health,
          equals(MigrationHealth.neverStarted));
      expect(snap.rows.single.sinceLastCycleMs, isNull);
    });

    test('active when lastCycleAt is within staleAfter window',
        () async {
      final at = DateTime.utc(2026, 5, 31, 12);
      final api = _FakeApi(<MigrationStatus>[
        _stat(
          id: 'mig_active',
          processed: 50,
          total: 100,
          lastCycleAt: at.subtract(const Duration(minutes: 5)),
        ),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        staleAfter: const Duration(minutes: 30),
        clock: _StubClock(at).call,
      );
      final row = (await view.snapshot()).rows.single;
      expect(row.health, equals(MigrationHealth.active));
      expect(row.sinceLastCycleMs,
          equals(const Duration(minutes: 5).inMilliseconds));
    });

    test('stalled when lastCycleAt is older than staleAfter window',
        () async {
      final at = DateTime.utc(2026, 5, 31, 12);
      final api = _FakeApi(<MigrationStatus>[
        _stat(
          id: 'mig_stalled',
          processed: 30,
          total: 1000,
          lastCycleAt: at.subtract(const Duration(hours: 4)),
        ),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        staleAfter: const Duration(minutes: 30),
        clock: _StubClock(at).call,
      );
      final row = (await view.snapshot()).rows.single;
      expect(row.health, equals(MigrationHealth.stalled));
      expect(row.sinceLastCycleMs,
          equals(const Duration(hours: 4).inMilliseconds));
    });

    test('exact staleAfter boundary is active (inclusive)', () async {
      final at = DateTime.utc(2026, 5, 31, 12);
      final api = _FakeApi(<MigrationStatus>[
        _stat(
          id: 'mig_boundary',
          lastCycleAt: at.subtract(const Duration(minutes: 30)),
        ),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        staleAfter: const Duration(minutes: 30),
        clock: _StubClock(at).call,
      );
      final row = (await view.snapshot()).rows.single;
      expect(row.health, equals(MigrationHealth.active),
          reason: 'exact-boundary age must classify as active');
      expect(row.sinceLastCycleMs,
          equals(const Duration(minutes: 30).inMilliseconds));
    });

    test(
        'classification respects a custom staleAfter window '
        '(no hard-coded defaults leak through)', () async {
      final at = DateTime.utc(2026, 5, 31, 12);
      final api = _FakeApi(<MigrationStatus>[
        _stat(
          id: 'mig_short_window',
          lastCycleAt: at.subtract(const Duration(seconds: 90)),
        ),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        staleAfter: const Duration(seconds: 60),
        clock: _StubClock(at).call,
      );
      final row = (await view.snapshot()).rows.single;
      expect(row.health, equals(MigrationHealth.stalled),
          reason: '90s age must classify as stalled when '
              'staleAfter is 60s');
    });

    test('clock-skew (negative age) is surfaced, not clamped',
        () async {
      // lastCycleAt is *after* the clock — operator should see the
      // anomaly via a negative sinceLastCycleMs, not have it
      // silently rounded.
      final at = DateTime.utc(2026, 5, 31, 12);
      final api = _FakeApi(<MigrationStatus>[
        _stat(
          id: 'mig_skew',
          lastCycleAt: at.add(const Duration(minutes: 10)),
        ),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        clock: _StubClock(at).call,
      );
      final row = (await view.snapshot()).rows.single;
      expect(row.sinceLastCycleMs,
          equals(-const Duration(minutes: 10).inMilliseconds));
      // Negative age is still <= staleAfter, so it is active.
      expect(row.health, equals(MigrationHealth.active));
    });
  });

  group('A.73 MigrationsInProgressView — progress percent', () {
    test('progressPercent == 0 when total <= 0', () async {
      final api = _FakeApi(<MigrationStatus>[
        _stat(id: 'mig_zero', processed: 7, total: 0),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        clock: _StubClock(DateTime.utc(2026, 1, 1)).call,
      );
      final row = (await view.snapshot()).rows.single;
      expect(row.progressPercent, equals(0));
    });

    test('progressPercent rounds half-away-from-zero', () async {
      final api = _FakeApi(<MigrationStatus>[
        // 0.5 of 1 → 50%
        _stat(id: 'mig_a_half', processed: 1, total: 2),
        // 1/3 ≈ 0.333… → 33%
        _stat(id: 'mig_b_third', processed: 1, total: 3),
        // 2/3 ≈ 0.666… → 67%
        _stat(id: 'mig_c_twothirds', processed: 2, total: 3),
        // 1/1 → 100%
        _stat(id: 'mig_d_full', processed: 1, total: 1),
      ]);
      final view = MigrationsInProgressView(
        api: api,
        clock: _StubClock(DateTime.utc(2026, 1, 1)).call,
      );
      final rows = (await view.snapshot()).rows;
      final byId = <String, int>{
        for (final r in rows) r.migrationId: r.progressPercent,
      };
      expect(byId['mig_a_half'], equals(50));
      expect(byId['mig_b_third'], equals(33));
      expect(byId['mig_c_twothirds'], equals(67));
      expect(byId['mig_d_full'], equals(100));
    });
  });

  group('A.73 MigrationsInProgressView — end-to-end over '
      'JsonFileMigrationApi', () {
    test('the view reflects what the dispatcher persists', () async {
      final dir = _openMemoryDir('tbm_a73_e2e_');
      final apiClock = _StubClock(DateTime.utc(2026, 5, 31, 10));
      final api = JsonFileMigrationApi(
        directory: dir,
        clock: apiClock.call,
      );

      // Three migrations registered. mig_b will be marked complete;
      // mig_a will have one active cycle; mig_c will never checkpoint.
      await api.start(_decl(id: 'mig_a'));
      await api.start(_decl(id: 'mig_b'));
      await api.start(_decl(id: 'mig_c'));

      apiClock.advance(const Duration(minutes: 2));
      await api.saveCursor('mig_a', <String, Object?>{
        'processed': 25,
        'total': 100,
        'last_seen_id': 'n_25',
      });

      apiClock.advance(const Duration(minutes: 3));
      await api.saveCursor('mig_b', <String, Object?>{
        'processed': 50,
        'total': 50,
        'complete': true,
      });

      // The view's clock runs ahead of the api clock — it observes
      // the system *after* the writes happened.
      final viewClock = _StubClock(DateTime.utc(2026, 5, 31, 10, 10));
      final view = MigrationsInProgressView(
        api: api,
        staleAfter: const Duration(minutes: 30),
        clock: viewClock.call,
      );

      final snap = await view.snapshot();
      // mig_b is complete → filtered out by listInProgress; remaining
      // rows are alphabetical.
      expect(snap.rows.map((r) => r.migrationId).toList(),
          equals(<String>['mig_a', 'mig_c']));
      expect(snap.at, equals(DateTime.utc(2026, 5, 31, 10, 10)));

      final migA = snap.rows.firstWhere((r) => r.migrationId == 'mig_a');
      expect(migA.health, equals(MigrationHealth.active));
      expect(migA.progressPercent, equals(25));
      expect(migA.status.processed, equals(25));
      expect(migA.status.total, equals(100));
      expect(migA.sinceLastCycleMs,
          equals(const Duration(minutes: 8).inMilliseconds),
          reason: 'view clock was 8 minutes after the mig_a cycle');

      final migC = snap.rows.firstWhere((r) => r.migrationId == 'mig_c');
      expect(migC.health, equals(MigrationHealth.neverStarted));
      expect(migC.sinceLastCycleMs, isNull);
      expect(migC.progressPercent, equals(0));
    });
  });
}
