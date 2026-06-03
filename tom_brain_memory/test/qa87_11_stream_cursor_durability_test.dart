// Q-A.87.11 — durable `StreamCursor` save / restore / clear (§ 9.2).
//
// ─────────────────────────────────────────────────────────────────────
// What this file locks
// ─────────────────────────────────────────────────────────────────────
//
// `memory_specification.md` § 9.2 promises: "Cursors survive process
// restarts via `StreamCursor.save()` / `restore()`." Before this step
// the `StreamCursor` / `StreamQuery` value types existed but no durable
// persistence surface backed them — a cognitive agent walking the full
// node set across a crash restarted from zero (Q-A.87.11).
//
// `JsonFileStreamCursorStore` is the durable surface, modelled on the
// existing `JsonFileMigrationApi` cursor (§ 11.2): a JSON file per
// stream under `checkpoints/stream_<streamId>.json`, written through
// write-temp-then-rename so a reader never sees a partial write, and a
// defensive read that degrades a corrupt checkpoint to "no cursor"
// (start fresh) rather than crashing the agent.
//
// The properties this file owns:
//
//   1. **Round-trip.** `save(cursor)` then `restore(streamId)` returns
//      the payload verbatim.
//   2. **Durability across simulated restart.** A fresh store over the
//      same directory restores the most-recently-saved cursor — across
//      any number of restarts, with no replay (a save after a restart
//      advances from the restored position).
//   3. **Completion clears the cursor.** `clear(streamId)` removes the
//      checkpoint so the next run of a completed walk starts fresh.
//   4. **Corruption tolerance.** A truncated / non-JSON / wrong-shape
//      checkpoint restores as `null`, never throws.
//   5. **Isolation.** Distinct stream ids never collide, and stream
//      checkpoints never collide with migration `restructure_*.json`
//      files sharing the same `checkpoints/` directory.
//   6. **Id safety.** A malformed `streamId` (empty, over-long, path
//      traversal, illegal chars) is rejected before any I/O.

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

/// Deterministic clock for `savedAt` stamps across simulated restarts.
class _StubClock {
  DateTime _now;
  _StubClock(this._now);
  DateTime call() => _now;
  void advance(Duration d) {
    _now = _now.add(d);
  }
}

void main() {
  group('JsonFileStreamCursorStore round-trip', () {
    test('restore on a never-saved stream returns null (fresh start)',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_fresh_');
      final store = JsonFileStreamCursorStore(directory: dir);
      expect(await store.restore('extractor_full_walk'), isNull);
    });

    test('save then restore returns the payload verbatim', () async {
      final dir = _openMemoryDir('tbm_qa8711_roundtrip_');
      final store = JsonFileStreamCursorStore(directory: dir);

      const cursor = StreamCursor(
        streamId: 'extractor_full_walk',
        payload: <String, Object?>{
          'last_seen_id': 'node_4096',
          'sort_key': 1717459200,
          'tier': 'A',
        },
      );
      await store.save(cursor);

      final restored = await store.restore('extractor_full_walk');
      expect(restored, isNotNull);
      expect(restored!.streamId, equals('extractor_full_walk'));
      expect(restored.payload['last_seen_id'], equals('node_4096'));
      expect(restored.payload['sort_key'], equals(1717459200));
      expect(restored.payload['tier'], equals('A'));
    });

    test('a later save overwrites the prior cursor (last write wins)',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_overwrite_');
      final store = JsonFileStreamCursorStore(directory: dir);

      await store.save(const StreamCursor(
        streamId: 's',
        payload: <String, Object?>{'last_seen_id': 'node_1'},
      ));
      await store.save(const StreamCursor(
        streamId: 's',
        payload: <String, Object?>{'last_seen_id': 'node_2'},
      ));

      final restored = await store.restore('s');
      expect(restored!.payload['last_seen_id'], equals('node_2'));
    });

    test('the checkpoint lands at checkpoints/stream_<id>.json', () async {
      final dir = _openMemoryDir('tbm_qa8711_filename_');
      final store = JsonFileStreamCursorStore(directory: dir);
      await store.save(const StreamCursor(
        streamId: 'connector_pass',
        payload: <String, Object?>{'last_seen_id': 'node_9'},
      ));
      final file = File('${dir.checkpointsDir}'
          '${Platform.pathSeparator}stream_connector_pass.json');
      expect(file.existsSync(), isTrue,
          reason: 'cursor must persist under the spec § 9.2 filename');
    });
  });

  group('JsonFileStreamCursorStore durability across simulated restart',
      () {
    test('a fresh store over the same directory restores the cursor',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_restart_');
      final clock = _StubClock(DateTime.utc(2026, 6, 3, 12));

      var store = JsonFileStreamCursorStore(directory: dir, clock: clock.call);
      await store.save(const StreamCursor(
        streamId: 'extractor_full_walk',
        payload: <String, Object?>{'last_seen_id': 'node_500'},
      ));

      // Simulated process restart — drop the instance, re-open the dir.
      store = JsonFileStreamCursorStore(directory: dir, clock: clock.call);
      final restored = await store.restore('extractor_full_walk');
      expect(restored, isNotNull);
      expect(restored!.payload['last_seen_id'], equals('node_500'));
    });

    test('10 cycles, 10 restarts — no loss, no replay', () async {
      final dir = _openMemoryDir('tbm_qa8711_restart_10x_');
      final clock = _StubClock(DateTime.utc(2026, 6, 3, 12));
      var store =
          JsonFileStreamCursorStore(directory: dir, clock: clock.call);

      for (var i = 1; i <= 10; i++) {
        clock.advance(const Duration(minutes: 1));
        await store.save(StreamCursor(
          streamId: 'walk',
          payload: <String, Object?>{
            'last_seen_id': 'node_${i * 100}',
            'count': i * 100,
          },
        ));

        // Restart between every cycle.
        store = JsonFileStreamCursorStore(directory: dir, clock: clock.call);
        final restored = await store.restore('walk');
        expect(restored, isNotNull, reason: 'cycle $i: must restore');
        expect(restored!.payload['count'], equals(i * 100),
            reason: 'cycle $i: restored count must equal last written value');
        expect(restored.payload['last_seen_id'], equals('node_${i * 100}'));
      }
    });
  });

  group('JsonFileStreamCursorStore clear', () {
    test('clear removes the cursor so a completed walk restarts fresh',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_clear_');
      final store = JsonFileStreamCursorStore(directory: dir);
      await store.save(const StreamCursor(
        streamId: 'walk',
        payload: <String, Object?>{'last_seen_id': 'node_1'},
      ));
      expect(await store.restore('walk'), isNotNull);

      await store.clear('walk');
      expect(await store.restore('walk'), isNull,
          reason: 'a cleared cursor must restore as null (fresh start)');
    });

    test('clear on a never-saved stream is a no-op (does not throw)',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_clear_missing_');
      final store = JsonFileStreamCursorStore(directory: dir);
      await store.clear('never_saved'); // must not throw
      expect(await store.restore('never_saved'), isNull);
    });
  });

  group('JsonFileStreamCursorStore corruption tolerance', () {
    test('a truncated / non-JSON checkpoint restores as null, no throw',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_corrupt_');
      final store = JsonFileStreamCursorStore(directory: dir);
      final file = File('${dir.checkpointsDir}'
          '${Platform.pathSeparator}stream_walk.json');
      file.writeAsStringSync('{ this is not valid json');
      expect(await store.restore('walk'), isNull);
    });

    test('a wrong-shape checkpoint (no payload object) restores as null',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_wrongshape_');
      final store = JsonFileStreamCursorStore(directory: dir);
      final file = File('${dir.checkpointsDir}'
          '${Platform.pathSeparator}stream_walk.json');
      file.writeAsStringSync('{"schemaVersion":1,"streamId":"walk"}');
      expect(await store.restore('walk'), isNull);
    });

    test('a stray temp file does not shadow the canonical cursor',
        () async {
      final dir = _openMemoryDir('tbm_qa8711_stray_tmp_');
      final store = JsonFileStreamCursorStore(directory: dir);
      await store.save(const StreamCursor(
        streamId: 'walk',
        payload: <String, Object?>{'last_seen_id': 'node_30'},
      ));

      final stray = File('${dir.checkpointsDir}'
          '${Platform.pathSeparator}stream_walk.json.tmp.99999.0');
      stray.writeAsStringSync('{"partial":"write"}');
      addTearDown(() {
        if (stray.existsSync()) stray.deleteSync();
      });

      final restored = await store.restore('walk');
      expect(restored, isNotNull);
      expect(restored!.payload['last_seen_id'], equals('node_30'));
    });
  });

  group('JsonFileStreamCursorStore isolation', () {
    test('distinct stream ids never collide', () async {
      final dir = _openMemoryDir('tbm_qa8711_distinct_');
      final store = JsonFileStreamCursorStore(directory: dir);
      await store.save(const StreamCursor(
        streamId: 'extractor',
        payload: <String, Object?>{'last_seen_id': 'e_1'},
      ));
      await store.save(const StreamCursor(
        streamId: 'connector',
        payload: <String, Object?>{'last_seen_id': 'c_99'},
      ));

      expect((await store.restore('extractor'))!.payload['last_seen_id'],
          equals('e_1'));
      expect((await store.restore('connector'))!.payload['last_seen_id'],
          equals('c_99'));
    });

    test(
        'stream checkpoints share checkpoints/ with migration files '
        'without collision', () async {
      final dir = _openMemoryDir('tbm_qa8711_coexist_');
      final migrations = JsonFileMigrationApi(directory: dir);
      await migrations.start(const MigrationDecl(
        migrationId: 'walk',
        summary: 'a migration that happens to share an id with a stream',
        candidates: StreamQuery(filter: SymbolicFilter()),
        perCycleBudget: 10,
      ));
      await migrations.saveCursor('walk', <String, Object?>{'processed': 7});

      final cursors = JsonFileStreamCursorStore(directory: dir);
      await cursors.save(const StreamCursor(
        streamId: 'walk',
        payload: <String, Object?>{'last_seen_id': 'node_3'},
      ));

      // Neither clobbered the other — different filename prefixes.
      final migrationCursor = await migrations.cursor('walk');
      expect(migrationCursor!.position['processed'], equals(7));
      final streamCursor = await cursors.restore('walk');
      expect(streamCursor!.payload['last_seen_id'], equals('node_3'));

      // The migration's in-progress view ignores the stream_*.json file.
      final inProgress = await migrations.listInProgress();
      expect(inProgress, hasLength(1));
      expect(inProgress.single.migrationId, equals('walk'));
    });
  });

  group('JsonFileStreamCursorStore id safety', () {
    test('empty streamId is rejected before I/O', () async {
      final dir = _openMemoryDir('tbm_qa8711_id_empty_');
      final store = JsonFileStreamCursorStore(directory: dir);
      expect(
        () => store.save(const StreamCursor(
            streamId: '', payload: <String, Object?>{})),
        throwsArgumentError,
      );
      expect(() => store.restore(''), throwsArgumentError);
      expect(() => store.clear(''), throwsArgumentError);
    });

    test('path-traversal streamId is rejected', () async {
      final dir = _openMemoryDir('tbm_qa8711_id_traversal_');
      final store = JsonFileStreamCursorStore(directory: dir);
      expect(
        () => store.save(const StreamCursor(
            streamId: '../escape', payload: <String, Object?>{})),
        throwsArgumentError,
      );
      expect(() => store.restore('a/b'), throwsArgumentError);
    });

    test('over-long streamId is rejected', () async {
      final dir = _openMemoryDir('tbm_qa8711_id_long_');
      final store = JsonFileStreamCursorStore(directory: dir);
      final tooLong = 'x' * 129;
      expect(
        () => store.save(StreamCursor(
            streamId: tooLong, payload: const <String, Object?>{})),
        throwsArgumentError,
      );
    });

    test('dot-leading streamId (hidden file) is rejected', () async {
      final dir = _openMemoryDir('tbm_qa8711_id_dot_');
      final store = JsonFileStreamCursorStore(directory: dir);
      expect(() => store.restore('.hidden'), throwsArgumentError);
    });
  });
}
