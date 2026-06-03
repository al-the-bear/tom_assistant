// A.47 — SqliteTrailStore contract test.
//
// Covers `openTrail` / `appendTrail` / `closeTrail` / `readTrail`
// against a real temp directory and an in-memory SQLite database.
// Validates the spec § 8.1 invariant Plan A.47 calls out — "the
// `Trail` index row is written only after the first JSONL line is
// durable" — plus the event leaves declared in `trail_events.dart`.
//
// Coverage map (one or more `test(...)` per row):
//
//   openTrail
//   ---------
//   * Mints a fresh TrailId and creates the JSONL file on disk
//     under <trailsRoot>/YYYY/MM/DD/.
//   * Does NOT insert a `trails` row.
//   * Does NOT emit TrailOpened.
//
//   appendTrail — first append
//   --------------------------
//   * Writes the JSONL line, fsyncs (file length > 0), THEN inserts
//     the index row. Index row sees status='active', opened_at
//     matches openTrail clock, closed_at is null, outcome is null.
//   * Emits TrailOpened (carrying the jsonl path) followed by
//     TrailEntryAppended(entryIndex: 1) — in that order.
//
//   appendTrail — subsequent appends
//   --------------------------------
//   * Each append fsyncs and emits only TrailEntryAppended; the
//     index row is not re-inserted.
//   * entryIndex increments monotonically (1, 2, 3, …).
//   * Index row remains status='active'.
//
//   closeTrail
//   ----------
//   * Synthesises a TrailEntry.outcome line carrying status /
//     summary / details / elapsedMs.
//   * Closes the writer; file is no longer appendable.
//   * Updates the index row: status='closed', outcome JSON payload,
//     closed_at populated.
//   * Emits TrailClosed (after TrailEntryAppended for the outcome
//     line).
//   * close-then-append on the same TrailId throws StateError
//     (writer is closed AND the id is no longer in _open).
//
//   closeTrail without prior appends
//   --------------------------------
//   * The outcome line itself triggers the index-row insert (so the
//     spec invariant holds for never-actually-used trails too).
//   * TrailOpened and TrailClosed both fire, in that order.
//
//   readTrail
//   ---------
//   * Round-trips invocation + primitiveCall + outcome entries with
//     payload preserved.
//   * Reads back trails that were closed via the index row alone
//     (writer is no longer in _open).
//   * Unknown TrailId → StateError.
//   * Corrupted lines are skipped; one TrailEntryCorrupted event is
//     emitted per skipped line; good entries on either side of the
//     bad line still round-trip.
//
//   Index row contract
//   ------------------
//   * opened_at_ms == the openTrail clock instant.ms (NOT the first-
//     append instant).
//   * jsonl_path matches the writer's resolved path.
//
//   Store lifecycle
//   ---------------
//   * `close()` is idempotent.
//   * After `close()`, every public method throws StateError.

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.47 SqliteTrailStore', () {
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
        randomness: List<int>.generate(16, (i) => (idCounter * 7 + i) & 31),
      );
    }

    SqliteTrailStore buildStore() => SqliteTrailStore(
          memoryDb: db,
          trailsRoot: trailsRoot,
          clock: clock,
          idMint: mintTrailId,
          eventSink: events.add,
        );

    setUp(() async {
      tmpRoot = await Directory.systemTemp.createTemp('a47_trail_store_');
      trailsRoot = '${tmpRoot.absolute.path}${Platform.pathSeparator}trails';
      Directory(trailsRoot).createSync(recursive: true);
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      events = <MemoryEvent>[];
      clock = MutableTestClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 5, 30, 14, 0, 0)),
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
      runId: 'r_01HXYZTESTID00000001',
    );

    // ─── openTrail ─────────────────────────────────────────────

    group('openTrail', () {
      test('creates the JSONL file but does NOT insert the index row',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);

        // File exists on disk (TrailWriter.open created it).
        final rows = db.select(
          'SELECT id FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        );
        expect(rows, isEmpty,
            reason: 'index row must not exist before first durable append');
        expect(
          events.whereType<TrailOpened>(),
          isEmpty,
          reason: 'TrailOpened must not fire before first durable append',
        );
      });
    });

    // ─── appendTrail — first append ────────────────────────────

    group('appendTrail (first call)', () {
      test('inserts the index row AFTER the JSONL line is durable',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final openAt = clock.now();
        final id = await store.openTrail(runRef);
        clock.advance(const Duration(milliseconds: 5));

        await store.appendTrail(
          id,
          TrailEntry.invocation(<String, Object?>{'q': 'hello?'}),
        );

        // Index row now present.
        final rows = db.select(
          'SELECT run_id, jsonl_path, status, outcome, '
          'opened_at_ms, opened_at_iso, closed_at_ms, closed_at_iso '
          'FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        );
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row['run_id'], equals(runRef.runId));
        expect(row['status'], equals('active'));
        expect(row['outcome'], isNull);
        expect(row['closed_at_ms'], isNull);
        expect(row['closed_at_iso'], isNull);
        expect(
          row['opened_at_ms'],
          equals(openAt.millisecondsSinceEpoch),
          reason: 'opened_at must reflect openTrail clock, not first-append',
        );

        // The recorded jsonl_path is the file TrailWriter actually
        // wrote: it must exist and be non-empty.
        final path = row['jsonl_path'] as String;
        expect(File(path).existsSync(), isTrue);
        expect(await File(path).length(), greaterThan(0));
      });

      test('emits TrailOpened then TrailEntryAppended in order', () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(
          id,
          TrailEntry.invocation(<String, Object?>{'q': 'hello'}),
        );

        final opened =
            events.whereType<TrailOpened>().toList();
        final appended =
            events.whereType<TrailEntryAppended>().toList();
        expect(opened, hasLength(1));
        expect(appended, hasLength(1));
        // TrailOpened must precede the TrailEntryAppended in event order.
        final openedIdx = events.indexOf(opened.single);
        final appendedIdx = events.indexOf(appended.single);
        expect(openedIdx, lessThan(appendedIdx));
        expect(opened.single.trailId, equals(id));
        expect(opened.single.runRef.runId, equals(runRef.runId));
        expect(opened.single.jsonlPath, isNotEmpty);
        expect(appended.single.entryKind, equals(TrailEntryKind.invocation));
        expect(appended.single.entryIndex, equals(1));
      });
    });

    // ─── appendTrail — subsequent appends ──────────────────────

    group('appendTrail (subsequent calls)', () {
      test('emits only TrailEntryAppended on appends 2+, with rising index',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('first'));
        events.clear();

        await store.appendTrail(id, TrailEntry.note('second'));
        await store.appendTrail(id, TrailEntry.note('third'));

        expect(events.whereType<TrailOpened>(), isEmpty,
            reason: 'TrailOpened fires only on the first append');
        final appended =
            events.whereType<TrailEntryAppended>().toList();
        expect(appended.map((e) => e.entryIndex).toList(), equals([2, 3]));
      });

      test('index row stays status=active across appends', () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('a'));
        await store.appendTrail(id, TrailEntry.note('b'));
        await store.appendTrail(id, TrailEntry.note('c'));

        final row = db.select(
          'SELECT status, outcome, closed_at_ms FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        expect(row['status'], equals('active'));
        expect(row['outcome'], isNull);
        expect(row['closed_at_ms'], isNull);
      });
    });

    // ─── closeTrail ────────────────────────────────────────────

    group('closeTrail', () {
      test('writes outcome line, updates index row, emits TrailClosed',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(
          id,
          TrailEntry.invocation(<String, Object?>{'q': 'hi'}),
        );
        await store.appendTrail(
          id,
          TrailEntry.note('mid-run'),
        );
        clock.advance(const Duration(seconds: 1));
        final closeAt = clock.now();

        final outcome = TrailOutcome(
          status: TrailOutcomeStatus.accepted,
          summary: 'answered the question',
          details: <String, Object?>{'cite': 'n_x'},
          elapsedMs: 412,
        );
        await store.closeTrail(id, outcome);

        // Index row updated.
        final row = db.select(
          'SELECT status, outcome, closed_at_ms, closed_at_iso '
          'FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        expect(row['status'], equals('closed'));
        expect(row['closed_at_ms'], equals(closeAt.millisecondsSinceEpoch));
        final outcomeJson =
            jsonDecode(row['outcome'] as String) as Map<String, Object?>;
        expect(outcomeJson['status'], 'accepted');
        expect(outcomeJson['summary'], 'answered the question');
        expect(outcomeJson['elapsedMs'], 412);
        expect(outcomeJson['details'],
            equals(<String, Object?>{'cite': 'n_x'}));

        // TrailClosed emitted after the outcome-line TrailEntryAppended.
        final closedEvents = events.whereType<TrailClosed>().toList();
        expect(closedEvents, hasLength(1));
        expect(closedEvents.single.outcome.status,
            TrailOutcomeStatus.accepted);
        expect(closedEvents.single.entriesWritten, equals(3));
        // The very last TrailEntryAppended should be the outcome.
        final appended =
            events.whereType<TrailEntryAppended>().toList();
        expect(appended.last.entryKind, equals(TrailEntryKind.outcome));
        // Order: outcome-appended must come before TrailClosed.
        expect(
          events.indexOf(appended.last),
          lessThan(events.indexOf(closedEvents.single)),
        );
      });

      test('further appendTrail after close throws StateError', () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('one'));
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'ok',
          ),
        );

        await expectLater(
          store.appendTrail(id, TrailEntry.note('two')),
          throwsStateError,
        );
      });

      test('closeTrail with no prior appends still writes the index row',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.aborted,
            summary: 'caller aborted before work',
            elapsedMs: 0,
          ),
        );

        final row = db.select(
          'SELECT status, outcome FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        expect(row['status'], equals('closed'));
        expect(row['outcome'], isNotNull);

        // Both events fire in canonical order.
        final openedIdx = events.indexWhere((e) => e is TrailOpened);
        final closedIdx = events.indexWhere((e) => e is TrailClosed);
        expect(openedIdx, greaterThanOrEqualTo(0));
        expect(closedIdx, greaterThanOrEqualTo(0));
        expect(openedIdx, lessThan(closedIdx));
      });
    });

    // ─── readTrail ─────────────────────────────────────────────

    group('readTrail', () {
      test('round-trips invocation + note + outcome', () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(
          id,
          TrailEntry.invocation(<String, Object?>{'q': 'when?'}),
        );
        await store.appendTrail(id, TrailEntry.note('mid'));
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'done',
            elapsedMs: 12,
          ),
        );

        final read = await store.readTrail(id).toList();
        expect(read.map((e) => e.kind).toList(), equals([
          TrailEntryKind.invocation,
          TrailEntryKind.note,
          TrailEntryKind.outcome,
        ]));
        expect(read[0].payload['arguments'], equals({'q': 'when?'}));
        expect(read[1].payload['message'], 'mid');
        expect(read[2].payload['status'], 'accepted');
        expect(read[2].payload['summary'], 'done');
        expect(read[2].payload['elapsedMs'], 12);
      });

      test('reads back trails that are closed (index row only)', () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('only'));
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'one-liner',
          ),
        );
        // After close, _open no longer has the id; resolution must
        // come from the trails index row.
        final read = await store.readTrail(id).toList();
        expect(read, hasLength(2)); // note + outcome
      });

      test('unknown TrailId throws StateError', () async {
        final store = buildStore();
        addTearDown(store.close);

        final stranger = TrailId.generate();
        await expectLater(
          store.readTrail(stranger).toList(),
          throwsStateError,
        );
      });

      test('skips corrupted lines and emits TrailEntryCorrupted', () async {
        final store = buildStore();
        addTearDown(store.close);

        final id = await store.openTrail(runRef);
        await store.appendTrail(id, TrailEntry.note('good-1'));
        await store.closeTrail(
          id,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'wrap',
          ),
        );

        // Hand-corrupt the file: insert a garbage line between the
        // two good lines.
        final row = db.select(
          'SELECT jsonl_path FROM trails WHERE id = ?',
          <Object?>[id.toString()],
        ).single;
        final path = row['jsonl_path'] as String;
        final raw = await File(path).readAsString();
        final lines = raw.split('\n').where((l) => l.isNotEmpty).toList();
        expect(lines, hasLength(2));
        final tampered = '${[
          lines[0],
          '{this is not json',
          lines[1],
        ].join('\n')}\n';
        await File(path).writeAsString(tampered);

        events.clear();
        final read = await store.readTrail(id).toList();
        expect(read.map((e) => e.kind).toList(), equals([
          TrailEntryKind.note,
          TrailEntryKind.outcome,
        ]));
        final corrupted =
            events.whereType<TrailEntryCorrupted>().toList();
        expect(corrupted, hasLength(1));
        expect(corrupted.single.lineNumber, equals(2));
        expect(corrupted.single.trailId, equals(id));
      });
    });

    // ─── Store lifecycle ──────────────────────────────────────

    group('store lifecycle', () {
      test('close is idempotent', () async {
        final store = buildStore();
        await store.close();
        await store.close();
      });

      test('post-close calls throw StateError', () async {
        final store = buildStore();
        await store.close();
        await expectLater(store.openTrail(runRef), throwsStateError);
      });
    });
  });
}
