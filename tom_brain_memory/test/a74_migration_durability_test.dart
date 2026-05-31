// A.74 — Migration durability + monotonic-progress property suite.
//
// Plan step A.74:
//   "Tests: cursor durability across simulated process restart;
//    non-completing migration progresses monotonically."
//
// ─────────────────────────────────────────────────────────────────────
// What this file covers — and why it is not folded into A.72
// ─────────────────────────────────────────────────────────────────────
//
// `a72_migration_api_test.dart` already includes a single-restart
// durability scenario (`'survives a process restart (new api instance,
// same dir)'`, lines 192–222). That test locks the *contract* — after
// one restart, the cursor reads what was last written. It does not
// lock the *property* the spec actually requires.
//
// `memory_specification.md` § 11.4 (Operational properties) names two
// invariants that this file owns:
//
//   1. **Cursor durability across simulated process restart.** A new
//      `JsonFileMigrationApi` over the same directory must read the
//      most-recently-saved cursor — across *any number* of simulated
//      restarts, including restarts interleaved with further writes.
//      The cursor must never replay: a `saveCursor` after a restart
//      must advance from the restored position, not start over.
//
//   2. **Non-completing migrations progress monotonically.** Spec
//      § 11.4 ("non-completion is allowed") means a migration can run
//      indefinitely without ever flipping `complete: true`. The
//      *processed* count must be non-decreasing across successive
//      `saveCursor` calls. The `complete` flag must stay `false` for
//      every cycle that does not explicitly set it. Status reads
//      between cycles must reflect the most recent committed cycle,
//      with no apparent decrease or "ghost completion".
//
// See `prototype_implementation_questions.md` Q-A.74.1 (why a
// separate file from A.72) and Q-A.74.2 (non-decreasing rather than
// strictly increasing).
//
// ─────────────────────────────────────────────────────────────────────
// Test idioms
// ─────────────────────────────────────────────────────────────────────
//
// * "Simulated process restart" = constructing a fresh
//   `JsonFileMigrationApi` over the same `MemoryDirectory` after
//   discarding the prior instance reference. The on-disk file is
//   the only state crossing the boundary.
// * "Cycle" = one `saveCursor` call. Cycles are clock-stamped via
//   `_StubClock` so `lastCycleAt` advances deterministically.
// * Property loops drive 25+ cycles each — well below any test-runner
//   timeout, comfortably above the "one or two iterations" trap that
//   would let an off-by-one slip through.

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
  String id = 'restructure_durability_v1',
  String summary = 'Durability property fixture',
  int budget = 50,
}) {
  return MigrationDecl(
    migrationId: id,
    summary: summary,
    candidates: const StreamQuery(filter: SymbolicFilter()),
    perCycleBudget: budget,
  );
}

/// Deterministic clock used to advance `lastCycleAt` between cycles
/// and across simulated restarts without sleeping.
class _StubClock {
  DateTime _now;
  _StubClock(this._now);
  DateTime call() => _now;
  void advance(Duration d) {
    _now = _now.add(d);
  }
}

void main() {
  group('A.74 cursor durability across simulated process restart', () {
    test(
        'three sequential restarts each restore the most-recent cursor '
        'verbatim (no replay)', () async {
      final dir = _openMemoryDir('tbm_a74_durable_3x_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));

      // First lifetime: register + checkpoint.
      var api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      clock.advance(const Duration(minutes: 1));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 100,
        'last_seen_id': 'node_100',
        'tier': 'A',
      });
      final firstSavedAt = clock();

      // Restart 1.
      api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      var restored = await api.cursor(_decl().migrationId);
      expect(restored, isNotNull, reason: 'restart 1: cursor must restore');
      expect(restored!.position['processed'], equals(100));
      expect(restored.position['last_seen_id'], equals('node_100'));
      expect(restored.position['tier'], equals('A'));
      expect(restored.savedAt, equals(firstSavedAt));

      // Cycle past the restore point — must advance, not replay.
      clock.advance(const Duration(minutes: 1));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 250,
        'last_seen_id': 'node_250',
        'tier': 'A',
      });
      final secondSavedAt = clock();

      // Restart 2.
      api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      restored = await api.cursor(_decl().migrationId);
      expect(restored, isNotNull, reason: 'restart 2: cursor must restore');
      expect(restored!.position['processed'], equals(250));
      expect(restored.position['last_seen_id'], equals('node_250'));
      expect(restored.savedAt, equals(secondSavedAt));

      // Cycle again, then restart 3 — same property, deeper sequence.
      clock.advance(const Duration(minutes: 1));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 425,
        'last_seen_id': 'node_425',
        'tier': 'B',
      });
      final thirdSavedAt = clock();

      api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      restored = await api.cursor(_decl().migrationId);
      expect(restored, isNotNull, reason: 'restart 3: cursor must restore');
      expect(restored!.position['processed'], equals(425));
      expect(restored.position['last_seen_id'], equals('node_425'));
      expect(restored.position['tier'], equals('B'));
      expect(restored.savedAt, equals(thirdSavedAt));
    });

    test(
        'restart-after-saveCursor preserves convention-mirrored fields '
        '(processed / total) read via status()', () async {
      final dir = _openMemoryDir('tbm_a74_durable_mirror_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      var api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      clock.advance(const Duration(seconds: 30));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 17,
        'total': 1234,
        'last_seen_id': 'node_17',
      });

      // Simulated restart — the mirrored counts must come back via
      // status(), not just the raw cursor.position payload.
      api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      final status = await api.status(_decl().migrationId);
      expect(status, isNotNull);
      expect(status!.processed, equals(17),
          reason: 'restart must preserve mirrored processedCount');
      expect(status.total, equals(1234),
          reason: 'restart must preserve mirrored totalEstimate');
      expect(status.complete, isFalse,
          reason: 'absent complete-key must remain false');
      expect(status.lastCycleAt, isNotNull);
    });

    test(
        'restart followed by start(decl) with same id is idempotent — '
        'cursor survives, summary/budget update lands', () async {
      final dir = _openMemoryDir('tbm_a74_durable_restart_start_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      var api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl(summary: 'v1', budget: 50));

      clock.advance(const Duration(minutes: 1));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 500,
        'last_seen_id': 'node_500',
      });

      // Restart, then re-call start() — the dispatcher does this on
      // every wakeup to reassert the migration declaration.
      api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl(summary: 'v2', budget: 75));

      // Cursor must NOT be wiped by the idempotent re-registration.
      final cursor = await api.cursor(_decl().migrationId);
      expect(cursor, isNotNull,
          reason: 'idempotent start after restart must not wipe cursor');
      expect(cursor!.position['processed'], equals(500));
      expect(cursor.position['last_seen_id'], equals('node_500'));

      // Status's processed mirror is also preserved.
      final status = await api.status(_decl().migrationId);
      expect(status!.processed, equals(500));
    });

    test(
        'a restart that finds a stray temp file (.tmp.<pid>.<counter>) '
        'still restores the canonical cursor', () async {
      final dir = _openMemoryDir('tbm_a74_durable_stray_tmp_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      var api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      clock.advance(const Duration(minutes: 1));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 30,
        'last_seen_id': 'node_30',
      });

      // Plant a stray temp file simulating a crash mid-write of a
      // *later* checkpoint. The temp must NOT shadow the canonical
      // file's content for cursor reads.
      final stray = File('${dir.checkpointsDir}'
          '${Platform.pathSeparator}'
          'restructure_${_decl().migrationId}.json.tmp.99999.0');
      stray.writeAsStringSync('{"this is a partial write": "ignored"}');
      addTearDown(() {
        if (stray.existsSync()) stray.deleteSync();
      });

      // Simulated restart.
      api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      final cursor = await api.cursor(_decl().migrationId);
      expect(cursor, isNotNull,
          reason: 'stray temp file must not block canonical read');
      expect(cursor!.position['processed'], equals(30));
      expect(cursor.position['last_seen_id'], equals('node_30'));

      // listInProgress() must also ignore the stray (filename suffix
      // check excludes anything past `.json`).
      final inProgress = await api.listInProgress();
      expect(inProgress, hasLength(1));
      expect(inProgress.single.processed, equals(30));
    });

    test(
        'durability survives across many small restarts — 10 cycles, '
        '10 restarts, no loss, monotonic processed', () async {
      final dir = _openMemoryDir('tbm_a74_durable_10x_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      var api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      var lastSeenProcessed = 0;
      for (var i = 1; i <= 10; i++) {
        clock.advance(const Duration(minutes: 1));
        await api.saveCursor(_decl().migrationId, <String, Object?>{
          'processed': i * 100,
          'last_seen_id': 'node_${i * 100}',
        });

        // Simulated restart between every cycle.
        api = JsonFileMigrationApi(directory: dir, clock: clock.call);
        final restored = await api.cursor(_decl().migrationId);
        expect(restored, isNotNull,
            reason: 'cycle $i: cursor must restore after restart');
        expect(restored!.position['processed'], equals(i * 100),
            reason: 'cycle $i: restored processed must equal '
                'last written value');
        expect(restored.position['last_seen_id'],
            equals('node_${i * 100}'));

        // The restored value must never go backwards across restarts.
        final restoredProcessed = restored.position['processed'] as int;
        expect(restoredProcessed, greaterThanOrEqualTo(lastSeenProcessed),
            reason: 'cycle $i: processed must be non-decreasing '
                'across restart boundary');
        lastSeenProcessed = restoredProcessed;
      }

      // After the final restart, listInProgress sees one in-progress
      // migration at the final position.
      final inProgress = await api.listInProgress();
      expect(inProgress, hasLength(1));
      expect(inProgress.single.processed, equals(1000));
      expect(inProgress.single.complete, isFalse);
    });
  });

  group('A.74 non-completing migration progresses monotonically', () {
    test(
        '25 cycles with strictly increasing processed — status reads '
        'monotonic, complete stays false throughout', () async {
      final dir = _openMemoryDir('tbm_a74_mono_25_strict_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      final api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      var previous = 0;
      for (var i = 1; i <= 25; i++) {
        clock.advance(const Duration(seconds: 30));
        await api.saveCursor(_decl().migrationId, <String, Object?>{
          'processed': i * 4,
          'last_seen_id': 'node_${i * 4}',
        });
        final status = await api.status(_decl().migrationId);
        expect(status, isNotNull, reason: 'cycle $i: status must exist');
        expect(status!.processed, equals(i * 4),
            reason: 'cycle $i: processed must equal written value');
        expect(status.processed, greaterThanOrEqualTo(previous),
            reason: 'cycle $i: processed must not decrease');
        expect(status.complete, isFalse,
            reason: 'cycle $i: complete must stay false for a '
                'non-completing migration');
        expect(status.lastCycleAt, equals(clock()),
            reason: 'cycle $i: lastCycleAt must match the clock');
        previous = status.processed;
      }

      // Final state is still in-progress.
      final inProgress = await api.listInProgress();
      expect(inProgress, hasLength(1));
      expect(inProgress.single.complete, isFalse);
      expect(inProgress.single.processed, equals(100));
    });

    test(
        'repeated equal-processed cycles are allowed (non-decreasing, '
        'not strictly increasing) — idle pass invariant', () async {
      // Spec § 11.4 invariant — see Q-A.74.2. An idle pass legitimately
      // checkpoints with the same processed value as the prior pass.
      final dir = _openMemoryDir('tbm_a74_mono_idle_pass_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      final api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      // Six cycles, but `processed` advances on only 1, 3, 5.
      final processedSeries = <int>[10, 10, 25, 25, 47, 47];
      var previous = 0;
      for (var i = 0; i < processedSeries.length; i++) {
        clock.advance(const Duration(seconds: 30));
        await api.saveCursor(_decl().migrationId, <String, Object?>{
          'processed': processedSeries[i],
          'last_seen_id': 'node_${processedSeries[i]}',
        });
        final status = await api.status(_decl().migrationId);
        expect(status!.processed, equals(processedSeries[i]),
            reason: 'cycle ${i + 1}: status must mirror written value');
        expect(status.processed, greaterThanOrEqualTo(previous),
            reason: 'cycle ${i + 1}: processed must be non-decreasing');
        expect(status.complete, isFalse);
        previous = status.processed;
      }

      // Last write must win — lastCycleAt is the most recent.
      final finalStatus = await api.status(_decl().migrationId);
      expect(finalStatus!.processed, equals(47));
      expect(finalStatus.lastCycleAt, equals(clock()));
    });

    test(
        'malformed convention values (negative processed, wrong-typed '
        'complete) cannot cause status.processed to decrease', () async {
      // The JsonFileMigrationApi ignores malformed convention values
      // (a72 test "ignores malformed convention values"). The
      // *property* this locks at A.74 is that even when ignored, the
      // prior mirrored processedCount is retained — so a malformed
      // mid-sequence write cannot drag status.processed backwards.
      final dir = _openMemoryDir('tbm_a74_mono_malformed_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      final api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 500,
        'last_seen_id': 'node_500',
      });
      var status = await api.status(_decl().migrationId);
      expect(status!.processed, equals(500));

      // Malformed cycle — values must be ignored, mirrored count
      // retained at 500.
      clock.advance(const Duration(seconds: 30));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': -10, // ignored
        'complete': 'maybe', // ignored
        'last_seen_id': 'node_garbage',
      });
      status = await api.status(_decl().migrationId);
      expect(status!.processed, equals(500),
          reason: 'malformed processed must not decrease the mirror');
      expect(status.complete, isFalse,
          reason: 'malformed complete must not flip the flag');

      // Subsequent valid cycle must advance from 500, not from 0.
      clock.advance(const Duration(seconds: 30));
      await api.saveCursor(_decl().migrationId, <String, Object?>{
        'processed': 700,
      });
      status = await api.status(_decl().migrationId);
      expect(status!.processed, equals(700));
      expect(status.processed, greaterThan(500),
          reason: 'valid cycle after malformed must advance forward');
    });

    test(
        'non-completing migration stays out of the complete-filter even '
        'after dozens of cycles — listInProgress always returns it',
        () async {
      final dir = _openMemoryDir('tbm_a74_mono_listed_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      final api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      for (var i = 1; i <= 30; i++) {
        clock.advance(const Duration(seconds: 30));
        await api.saveCursor(_decl().migrationId, <String, Object?>{
          'processed': i * 3,
        });
        final inProgress = await api.listInProgress();
        expect(inProgress, hasLength(1),
            reason: 'cycle $i: non-completing migration must remain '
                'in listInProgress');
        expect(inProgress.single.complete, isFalse);
        expect(inProgress.single.processed, equals(i * 3));
      }
    });

    test(
        'multiple concurrent migrations progress independently and '
        'monotonically — no cross-id leakage', () async {
      final dir = _openMemoryDir('tbm_a74_mono_multi_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      final api = JsonFileMigrationApi(directory: dir, clock: clock.call);

      await api.start(_decl(id: 'mig_alpha'));
      await api.start(_decl(id: 'mig_beta'));
      await api.start(_decl(id: 'mig_gamma'));

      final prev = <String, int>{
        'mig_alpha': 0,
        'mig_beta': 0,
        'mig_gamma': 0,
      };

      for (var i = 1; i <= 12; i++) {
        clock.advance(const Duration(seconds: 30));
        // Each migration advances by a different step so cross-leakage
        // would be immediately visible.
        await api
            .saveCursor('mig_alpha', <String, Object?>{'processed': i * 1});
        await api
            .saveCursor('mig_beta', <String, Object?>{'processed': i * 7});
        await api.saveCursor(
            'mig_gamma', <String, Object?>{'processed': i * 13});

        for (final id in <String>['mig_alpha', 'mig_beta', 'mig_gamma']) {
          final status = await api.status(id);
          expect(status!.processed, greaterThanOrEqualTo(prev[id]!),
              reason: '$id cycle $i: non-decreasing');
          expect(status.complete, isFalse);
          prev[id] = status.processed;
        }
      }

      expect(prev['mig_alpha'], equals(12));
      expect(prev['mig_beta'], equals(84));
      expect(prev['mig_gamma'], equals(156));

      final inProgress = await api.listInProgress();
      expect(inProgress.map((s) => s.migrationId).toList(),
          equals(<String>['mig_alpha', 'mig_beta', 'mig_gamma']));
      expect(inProgress.every((s) => !s.complete), isTrue);
    });

    test(
        'monotonic invariant survives an interleaved restart sequence '
        '(restart between every cycle, full processed series checked)',
        () async {
      // The two properties combined — durability + monotonicity — held
      // across the same sequence. This is the headline guarantee spec
      // § 11.4 implies for the dispatcher loop.
      final dir = _openMemoryDir('tbm_a74_mono_durability_combo_');
      final clock = _StubClock(DateTime.utc(2026, 5, 30, 12));
      var api = JsonFileMigrationApi(directory: dir, clock: clock.call);
      await api.start(_decl());

      var previous = 0;
      final processedSeries = <int>[5, 12, 12, 30, 30, 45, 100, 100, 220];

      for (var i = 0; i < processedSeries.length; i++) {
        clock.advance(const Duration(seconds: 30));
        await api.saveCursor(_decl().migrationId, <String, Object?>{
          'processed': processedSeries[i],
          'last_seen_id': 'node_${processedSeries[i]}',
        });

        // Restart between every cycle.
        api = JsonFileMigrationApi(directory: dir, clock: clock.call);

        final status = await api.status(_decl().migrationId);
        expect(status!.processed, equals(processedSeries[i]),
            reason: 'cycle ${i + 1}: post-restart status must mirror '
                'the last written processed');
        expect(status.processed, greaterThanOrEqualTo(previous),
            reason: 'cycle ${i + 1}: processed must be non-decreasing '
                'across the restart boundary');
        expect(status.complete, isFalse,
            reason: 'cycle ${i + 1}: complete must stay false across '
                'the restart boundary');
        previous = status.processed;
      }

      expect(previous, equals(220));
    });
  });
}
