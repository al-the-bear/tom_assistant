// A.49 — Trail subsystem cross-cut integration tests.
//
// A.46–A.48 cover the per-class contracts in isolation
// (`TrailWriter` append/fsync; `SqliteTrailStore` open/append/close
// lifecycle + index-row invariant; streaming `readTrail` corruption
// tolerance). A.49 wires the three together and pins the four
// cross-cut behaviours the plan calls out:
//
//   1. **append-fsync ordering** — many appends fired without
//      awaiting between them land on disk in call order, and the
//      file's line count matches the writer's `entryCount`.
//
//   2. **mid-line corruption skip** end-to-end — open → append a
//      mix of entry kinds → tamper the JSONL file → close → readback
//      surfaces every good line as a `TrailEntry` and exactly one
//      `TrailEntryCorrupted` event per tampered line.
//
//   3. **close-emit-event ordering** — the event sequence for a
//      closing trail is `TrailOpened → TrailEntryAppended(real)* →
//      TrailEntryAppended(outcome) → TrailClosed`, and the last
//      durable line on disk has the same JSON shape as the
//      `outcome` column on the index row.
//
//   4. **read-back roundtrip across a store restart** — close the
//      store, drop the in-process `_open` map by constructing a
//      fresh `SqliteTrailStore`, and confirm `readTrail` still
//      resolves via the index row alone and yields the original
//      entries.
//
// Plus the deferred fault-injection cases A.48 carried forward:
//
//   5. **crash between fsync and index-row insert** — simulated by
//      writing through `TrailWriter` directly (which fsyncs) and
//      never letting the store insert the row. Post-crash, the
//      orphan JSONL file is intact on disk, the `trails` table has
//      no row for the orphan, a fresh store can open a new trail
//      side-by-side without disturbing the orphan, and the orphan
//      file is recoverable by direct read.
//
//   6. **crash mid-run, after several appends, before closeTrail**
//      — simulated by opening a store, appending N entries (the
//      first `appendTrail` inserts the index row in `active`
//      status), then dropping the store reference without
//      `closeTrail`. Post-crash the file has the N lines but no
//      `outcome` line, the index row stays in `active`, and a
//      fresh store can either re-open the trail or run a
//      reconciliation sweep over the orphan.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.49 trail subsystem — cross-cut integration', () {
    late Directory tmpRoot;
    late String trailsRoot;
    late Database db;
    late List<MemoryEvent> events;
    late MutableTestClock clock;
    late int idCounter;

    TrailId mintTrailId() {
      idCounter += 1;
      return TrailId.generate(
        at: clock.now(),
        randomness: List<int>.generate(16, (i) => (idCounter * 13 + i) & 31),
      );
    }

    SqliteTrailStore buildStore({void Function(MemoryEvent)? sink}) =>
        SqliteTrailStore(
          memoryDb: db,
          trailsRoot: trailsRoot,
          clock: clock,
          idMint: mintTrailId,
          eventSink: sink ?? events.add,
        );

    setUp(() async {
      tmpRoot = await Directory.systemTemp.createTemp('a49_trail_crosscut_');
      trailsRoot = '${tmpRoot.absolute.path}${Platform.pathSeparator}trails';
      Directory(trailsRoot).createSync(recursive: true);
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      events = <MemoryEvent>[];
      clock = MutableTestClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 5, 30, 18, 0, 0)),
      );
      idCounter = 0;
    });

    tearDown(() async {
      db.dispose();
      if (await tmpRoot.exists()) {
        await tmpRoot.delete(recursive: true);
      }
    });

    const runRef = ProcedureRunRef(
      procedureId: 'p_answer_with_memory_v1',
      runId: 'r_01HXYZA49ID000000001',
    );

    // ─── End-to-end open → varied appends → corrupt → close → read ──

    group('end-to-end pipeline', () {
      test(
          'full lifecycle round-trips every entry kind and surfaces injected corruption exactly once per bad line',
          () async {
        // Open the store, dispatch a realistic mix of entry kinds,
        // close, then *tamper* with two mid-file lines on disk
        // before reading back. The readback stream is expected to
        // produce every good entry (including the synthesised
        // outcome line) and one `TrailEntryCorrupted` event per bad
        // line.
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);

        // Seven real appends (writer.entryCount → 7 once the
        // outcome line lands inside closeTrail).
        await store.appendTrail(
          id,
          TrailEntry.invocation(<String, Object?>{'prompt': 'what is 2+2?'}),
        );
        await store.appendTrail(
          id,
          TrailEntry.primitiveCall(
            'recall',
            <String, Object?>{'query': 'math basics'},
            <String, Object?>{'hits': 3},
            elapsedMs: 11,
          ),
        );
        await store.appendTrail(id, TrailEntry.persist('n_concept_arithmetic'));
        await store.appendTrail(
          id,
          TrailEntry.note('substrate selected: local-gemma3:27b'),
        );
        await store.appendTrail(
          id,
          TrailEntry.error(
            'TransientNetworkError',
            'embed call failed; retrying',
            details: <String, Object?>{'attempt': 1},
          ),
        );
        await store.appendTrail(id, TrailEntry.persist('n_answer_4'));
        await store.appendTrail(id, TrailEntry.note('done'));

        // Capture the on-disk path *before* close, then close to
        // emit the synth outcome line.
        final pathRow = db.select(
          'SELECT jsonl_path FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        final jsonlPath = pathRow['jsonl_path'] as String;

        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: '4',
            details: <String, Object?>{'tokens': 14},
            elapsedMs: 42,
          ),
        );

        // Sanity: file has 8 lines (7 real + 1 outcome).
        final original = await File(jsonlPath).readAsLines();
        expect(original, hasLength(8));

        // Tamper: replace lines 3 and 6 with bad JSON (1-based file
        // line numbers; index 2 and 5 in the zero-based list).
        final tampered = <String>[
          original[0],
          original[1],
          '{this is not json at all',
          original[3],
          original[4],
          '{"ts":"not-a-real-timestamp","kind":"note","message":"x"}',
          original[6],
          original[7],
        ].join('\n');
        await File(jsonlPath).writeAsString('$tampered\n');

        events.clear();
        final read = await store.readTrail(id).toList();
        // 8 lines on disk (7 real + outcome); 2 tampered → 6 good.
        expect(read, hasLength(6));

        // Kinds in order: invocation, primitiveCall, (skip),
        // note, error, (skip), note, outcome
        // ... but we tampered lines 3 and 6, which were the
        // `persist` at index 2 and the second `persist` at index 5.
        expect(
          read.map((e) => e.kind).toList(),
          equals(<TrailEntryKind>[
            TrailEntryKind.invocation,
            TrailEntryKind.primitiveCall,
            // persist at line 3 skipped
            TrailEntryKind.note,
            TrailEntryKind.error,
            // persist at line 6 skipped
            TrailEntryKind.note,
            TrailEntryKind.outcome,
          ]),
        );

        // Payload spot-checks on a few survivors.
        final invocation = read.first;
        expect(invocation.payload['arguments'],
            equals(<String, Object?>{'prompt': 'what is 2+2?'}));
        final outcome = read.last;
        expect(outcome.payload['status'],
            equals(TrailOutcomeStatus.accepted.name));
        expect(outcome.payload['summary'], equals('4'));
        expect(outcome.payload['elapsedMs'], equals(42));
        expect(outcome.payload['details'],
            equals(<String, Object?>{'tokens': 14}));

        // Exactly two corruption events, at line numbers 3 and 6.
        final corruption = events.whereType<TrailEntryCorrupted>().toList();
        expect(corruption, hasLength(2));
        expect(
          corruption.map((e) => e.lineNumber).toList(),
          equals(<int>[3, 6]),
        );
        expect(corruption.every((e) => e.trailId == id), isTrue);
      });

      test(
          'a fresh store (no `_open` entries) reads back a closed trail via the trails index row',
          () async {
        // Pin: after a process restart, the JSONL path lives only in
        // the `trails` row. The fresh store has an empty `_open`
        // map; readTrail must resolve through SQL alone and produce
        // the same entries.
        final firstStore = buildStore();
        final id = await firstStore.openTrail(runRef);
        await firstStore.appendTrail(
          id,
          TrailEntry.note('survives across stores'),
        );
        await firstStore.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'restart-roundtrip',
            elapsedMs: 0,
          ),
        );
        await firstStore.close();

        // New store sharing the same db handle + trails dir; the
        // `_open` map is empty.
        final secondStore = buildStore();
        addTearDown(secondStore.close);

        final read = await secondStore.readTrail(id).toList();
        expect(
          read.map((e) => e.kind).toList(),
          equals(<TrailEntryKind>[
            TrailEntryKind.note,
            TrailEntryKind.outcome,
          ]),
        );
        expect(read[0].payload['message'], equals('survives across stores'));
        expect(read[1].payload['summary'], equals('restart-roundtrip'));
      });
    });

    // ─── append-fsync ordering under concurrent firing ──────────────

    group('append-fsync ordering', () {
      test(
          '100 appends fired without awaiting between them land on disk in call order',
          () async {
        // The writer's internal future chain (`_tail`) serialises
        // overlapping appends; this is the cross-cut guarantee the
        // engine relies on when bridged primitives fire back-to-back.
        // We fire the appends, then await all futures at once.
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        // First append must complete first so the index row is in
        // place — the store's `_insertIndexRow` runs inside that
        // call, and re-entrant `appendTrail` would otherwise race.
        await store.appendTrail(id, TrailEntry.note('append-000'));

        // Now fire 99 more without awaiting between them.
        final futures = <Future<void>>[];
        for (var i = 1; i < 100; i++) {
          final n = i.toString().padLeft(3, '0');
          futures.add(store.appendTrail(id, TrailEntry.note('append-$n')));
        }
        await Future.wait(futures);

        // Capture path and close.
        final pathRow = db.select(
          'SELECT jsonl_path FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        final jsonlPath = pathRow['jsonl_path'] as String;
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'order-100',
            elapsedMs: 0,
          ),
        );

        // 100 real notes + 1 outcome line on disk.
        final lines = await File(jsonlPath).readAsLines();
        expect(lines, hasLength(101));
        for (var i = 0; i < 100; i++) {
          final n = i.toString().padLeft(3, '0');
          final decoded = jsonDecode(lines[i]) as Map<String, Object?>;
          expect(decoded['kind'], equals('note'));
          expect(decoded['message'], equals('append-$n'),
              reason: 'on-disk order at line ${i + 1} must match call order');
        }

        // entryCount matches the file's line count.
        final closedEntries = events
            .whereType<TrailClosed>()
            .single
            .entriesWritten;
        expect(closedEntries, equals(101));

        // entryIndex events span 1..101 monotonically.
        final indices = events
            .whereType<TrailEntryAppended>()
            .map((e) => e.entryIndex)
            .toList();
        expect(indices, equals(List<int>.generate(101, (i) => i + 1)));
      });

      test(
          'a payload that violates the reserved-key rule does not stop subsequent appends',
          () async {
        // The writer's `_tail` chain swallows its own errors so a
        // failed append does not poison the chain. Cross-cut check:
        // after a bad append throws, subsequent good appends still
        // land on disk in order.
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('before-bad'));

        await expectLater(
          store.appendTrail(
            id,
            // Manually construct an entry whose payload shadows
            // the reserved `kind` key.
            TrailEntry(
              at: clock.now(),
              kind: TrailEntryKind.note,
              payload: <String, Object?>{'kind': 'oops', 'message': 'bad'},
            ),
          ),
          throwsArgumentError,
        );

        await store.appendTrail(id, TrailEntry.note('after-bad'));

        final pathRow = db.select(
          'SELECT jsonl_path FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        final jsonlPath = pathRow['jsonl_path'] as String;
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'survived-bad-append',
            elapsedMs: 0,
          ),
        );

        // before-bad, after-bad, outcome — three durable lines.
        final lines = await File(jsonlPath).readAsLines();
        expect(lines, hasLength(3));
        final firstDecoded = jsonDecode(lines[0]) as Map<String, Object?>;
        final secondDecoded = jsonDecode(lines[1]) as Map<String, Object?>;
        expect(firstDecoded['message'], equals('before-bad'));
        expect(secondDecoded['message'], equals('after-bad'));
      });
    });

    // ─── closeTrail event ordering + outcome parity ─────────────────

    group('close emits events in order; on-disk outcome matches SQL outcome',
        () {
      test(
          'events are TrailOpened → TrailEntryAppended(real) → TrailEntryAppended(outcome) → TrailClosed',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('first'));
        await store.appendTrail(id, TrailEntry.note('second'));
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'event-order',
            elapsedMs: 5,
          ),
        );

        // Project the event sequence to (kind, entryKind | null).
        final shape = events.map((e) {
          if (e is TrailOpened) return <Object?>['opened', null];
          if (e is TrailEntryAppended) {
            return <Object?>['appended', e.entryKind];
          }
          if (e is TrailClosed) return <Object?>['closed', null];
          return <Object?>[e.kind, null];
        }).toList();

        expect(
          shape,
          equals(<List<Object?>>[
            <Object?>['opened', null],
            <Object?>['appended', TrailEntryKind.note], // first
            <Object?>['appended', TrailEntryKind.note], // second
            <Object?>['appended', TrailEntryKind.outcome], // synth
            <Object?>['closed', null],
          ]),
        );

        // The TrailClosed event reports 3 entries written (two
        // notes + the outcome line).
        final closed = events.whereType<TrailClosed>().single;
        expect(closed.entriesWritten, equals(3));
      });

      test(
          'last JSONL line on disk equals the trails.outcome JSON payload',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('only line before close'));

        final outcome = TrailOutcome(
          status: TrailOutcomeStatus.accepted,
          summary: 'parity-check',
          details: <String, Object?>{'note': 'on-disk and SQL must agree'},
          elapsedMs: 17,
        );
        await store.closeTrail(id, outcome);

        final row = db.select(
          'SELECT jsonl_path, outcome FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        final jsonlPath = row['jsonl_path'] as String;
        final sqlOutcomeRaw = row['outcome'] as String;
        final sqlOutcome = jsonDecode(sqlOutcomeRaw) as Map<String, Object?>;

        final lines = await File(jsonlPath).readAsLines();
        final lastLine = jsonDecode(lines.last) as Map<String, Object?>;

        // SQL column carries {status, summary, details?, elapsedMs}.
        // JSONL line carries the same fields PLUS the writer-stamped
        // `ts` and `kind: outcome` envelope.
        expect(lastLine['kind'], equals('outcome'));
        expect(lastLine['ts'], isA<String>());
        for (final key in sqlOutcome.keys) {
          expect(
            lastLine[key],
            equals(sqlOutcome[key]),
            reason: 'on-disk outcome.$key must match trails.outcome.$key',
          );
        }
      });
    });

    // ─── Fault injection: crash between fsync and index-row insert ──

    group('fault injection — crash between fsync and index-row insert', () {
      test(
          'orphan file is durable on disk; trails has no row; fresh store can run a side-by-side recovery trail',
          () async {
        // Simulate the crash window inside SqliteTrailStore.appendTrail:
        // the writer fsync'd, then the process died before
        // `_insertIndexRow` could run. We model this by writing
        // through `TrailWriter` directly — the writer's fsync is
        // the *same* fsync the store relies on, but no store is
        // wrapping it, so no SQL row is ever inserted.
        final orphanRunRef = const ProcedureRunRef(
          procedureId: 'p_answer_with_memory_v1',
          runId: 'r_01HXYZA49CRASH00000A',
        );
        final orphanWriter = await TrailWriter.open(
          trailsRoot: trailsRoot,
          runRef: orphanRunRef,
          clock: clock,
        );
        await orphanWriter.append(
          TrailEntry.note('pre-crash line (durable, no SQL row)'),
        );
        // Deliberately do NOT close the writer or call any store
        // path — this is the crash window.

        // Post-crash observable state #1: the orphan file exists at
        // the date-sharded path and has the one fsync'd line.
        expect(File(orphanWriter.path).existsSync(), isTrue);
        final orphanLines = await File(orphanWriter.path).readAsLines();
        expect(orphanLines, hasLength(1));
        final orphanDecoded =
            jsonDecode(orphanLines.single) as Map<String, Object?>;
        expect(orphanDecoded['kind'], equals('note'));
        expect(
          orphanDecoded['message'],
          equals('pre-crash line (durable, no SQL row)'),
        );

        // Post-crash observable state #2: the trails table has no
        // row for the orphan's run_id.
        final rows = db.select(
          'SELECT id FROM trails WHERE run_id = ?',
          <Object?>[orphanRunRef.runId],
        );
        expect(rows, isEmpty);

        // Post-crash observable state #3: a fresh store can open a
        // brand-new trail for a *different* run without disturbing
        // the orphan file. (Using a fresh run id keeps the recovery
        // scenario at the level of the "no event ever truly lost"
        // invariant — engine-driven re-attach via the same run id
        // would append into the orphan file, which is a separate
        // recovery mode not under test here.)
        final recoveryStore = buildStore();
        addTearDown(recoveryStore.close);
        const recoveryRunRef = ProcedureRunRef(
          procedureId: 'p_answer_with_memory_v1',
          runId: 'r_01HXYZA49RECOVER0001B',
        );
        final recoveryId = await recoveryStore.openTrail(recoveryRunRef);
        await recoveryStore.appendTrail(
          recoveryId,
          TrailEntry.note('post-crash recovery line'),
        );
        await recoveryStore.closeTrail(
          recoveryId,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'recovery-after-crash',
            elapsedMs: 0,
          ),
        );

        // Orphan file is still on disk and still intact.
        expect(File(orphanWriter.path).existsSync(), isTrue);
        final orphanLinesAfter = await File(orphanWriter.path).readAsLines();
        expect(orphanLinesAfter, equals(orphanLines));

        // The recovery trail's index row IS present.
        final recoveryRows = db.select(
          'SELECT status FROM trails WHERE id = ?',
          <Object?>[recoveryId.toString()],
        );
        expect(recoveryRows, hasLength(1));
        expect(recoveryRows.single['status'], equals('closed'));
      });

      test(
          'orphan file is recoverable by direct file read alone (no SQL lookup needed)',
          () async {
        // The orphan file IS the durable record. A reconciliation
        // sweep (future plan step) walks `trails/YYYY/MM/DD/` and
        // either re-attaches the file to a `trails` row or imports
        // it cold. The cross-cut guarantee A.49 pins here is the
        // weaker one: the bytes on disk are valid JSONL and can be
        // decoded by the same `_tryDecodeEntry` logic the store
        // uses for indexed trails — no special path needed.
        const orphanRunRef = ProcedureRunRef(
          procedureId: 'p_recovery',
          runId: 'r_01HXYZA49ORPHAN0001',
        );
        final orphanWriter = await TrailWriter.open(
          trailsRoot: trailsRoot,
          runRef: orphanRunRef,
          clock: clock,
        );
        await orphanWriter.append(TrailEntry.note('orphan-1'));
        await orphanWriter.append(TrailEntry.note('orphan-2'));
        await orphanWriter.append(TrailEntry.note('orphan-3'));
        // Crash: leave the writer open and abandon it.

        // Read the file directly and decode the lines.
        final lines = await File(orphanWriter.path).readAsLines();
        expect(lines, hasLength(3));
        final decoded = lines
            .map((l) => jsonDecode(l) as Map<String, Object?>)
            .toList();
        expect(
          decoded.map((m) => m['message']).toList(),
          equals(<String>['orphan-1', 'orphan-2', 'orphan-3']),
        );
        for (final m in decoded) {
          expect(m['kind'], equals('note'));
          expect(m['ts'], isA<String>());
          // The decoded ts parses as a valid ISO-8601 UTC string.
          final ts = DateTime.parse(m['ts'] as String);
          expect(ts.isUtc, isTrue);
        }

        // Defensive close so the tear-down can delete the temp dir
        // on all platforms (Windows holds open file handles).
        await orphanWriter.close();
      });
    });

    // ─── Fault injection: crash mid-run, before closeTrail ──────────

    group('fault injection — crash mid-run before closeTrail', () {
      test(
          'index row stays in `active`, file has N appended lines and no outcome line, a fresh store can readTrail the orphan',
          () async {
        // Simulate a process death after several `appendTrail` calls
        // but before `closeTrail`. The first `appendTrail` inserted
        // the `trails` row in `active` status; subsequent appends
        // fsync'd their lines. The crash leaves the row in `active`
        // and the file without an `outcome` line.
        //
        // The implementation models this by opening the store,
        // appending three entries, then dropping the reference
        // without calling closeTrail. To make the simulation
        // accurate we also DO NOT call store.close() — that would
        // drain the writer cleanly. Instead we let GC pick up the
        // dangling writer (the temp dir tear-down handles the file
        // handle release).
        late TrailId orphanId;
        late String orphanPath;
        {
          final crashedStore = buildStore();
          orphanId = await crashedStore.openTrail(runRef);
          await crashedStore.appendTrail(orphanId, TrailEntry.note('mid-1'));
          await crashedStore.appendTrail(orphanId, TrailEntry.note('mid-2'));
          await crashedStore.appendTrail(orphanId, TrailEntry.note('mid-3'));
          final row = db.select(
            'SELECT jsonl_path, status, closed_at_ms FROM trails WHERE id = ?',
            <Object?>[orphanId.toString()],
          ).single;
          orphanPath = row['jsonl_path'] as String;
          expect(row['status'], equals('active'));
          expect(row['closed_at_ms'], isNull);
          // Drop reference without close — simulates a crash.
        }

        // Post-crash invariants:
        //
        // 1. The row stays in `active` — no implicit close ran.
        final postRow = db.select(
          'SELECT status, outcome, closed_at_ms FROM trails WHERE id = ?',
          <Object?>[orphanId.toString()],
        ).single;
        expect(postRow['status'], equals('active'));
        expect(postRow['outcome'], isNull);
        expect(postRow['closed_at_ms'], isNull);

        // 2. The file has three lines (no outcome).
        final lines = await File(orphanPath).readAsLines();
        expect(lines, hasLength(3));
        for (final line in lines) {
          final m = jsonDecode(line) as Map<String, Object?>;
          expect(m['kind'], equals('note'));
        }

        // 3. A fresh store, given the orphan id, can readTrail it
        //    end-to-end (resolution path: index row, since the
        //    fresh store has no `_open` entries). The corruption
        //    counter stays at zero — three good lines is three good
        //    entries.
        final freshStore = buildStore();
        addTearDown(freshStore.close);
        events.clear();
        final read = await freshStore.readTrail(orphanId).toList();
        expect(read, hasLength(3));
        expect(
          read.map((e) => e.payload['message']).toList(),
          equals(<String>['mid-1', 'mid-2', 'mid-3']),
        );
        expect(events.whereType<TrailEntryCorrupted>(), isEmpty);
      });
    });
  });
}
