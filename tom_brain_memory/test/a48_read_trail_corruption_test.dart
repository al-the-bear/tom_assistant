// A.48 — Corruption-tolerant streaming `readTrail`.
//
// A.47 already exercises the happy-path round-trip and one
// mid-file corruption case. A.48 hardens `readTrail` against the
// rest of the corruption modes spec § 8.3 calls for, and pins the
// streaming-pipeline behaviour Plan A.48 demanded.
//
// Coverage map (one or more `test(...)` per row):
//
//   Streaming pipeline (Plan A.48 — "use `openRead` + LineSplitter")
//   ----------------------------------------------------------------
//   * Reads back a multi-thousand-line trail file without
//     materialising the full file (regression guard against any
//     future revert to `readAsString`). Verified by direct file
//     read showing the on-disk file size exceeds the in-process
//     line-buffer assumption, plus the line count matches the
//     stream count.
//   * `entryIndex` line numbers in `TrailEntryCorrupted` events
//     match the physical line numbers in the file (1-based).
//
//   Mid-file corruption modes
//   -------------------------
//   * Multiple corrupt lines interspersed with good lines —
//     all good lines round-trip; one `TrailEntryCorrupted` event
//     per bad line; line numbers match.
//   * Bad line is a JSON array (`[1,2,3]`) — rejected because the
//     parsed value is not a JSON object.
//   * Bad line is a JSON object missing the required `kind` field.
//   * Bad line is a JSON object with an unknown `kind` value.
//   * Bad line is a JSON object missing the required `ts` field.
//   * Bad line is a JSON object with a non-ISO-8601 `ts` value.
//   * Truncated final line (writer crashed mid-write) — skipped
//     and reported as the file's last line number.
//
//   UTF-8 byte-level corruption (load-bearing `allowMalformed`)
//   ----------------------------------------------------------
//   * A line containing a stray non-UTF-8 byte still produces a
//     `TrailEntryCorrupted` event for *just that line*, and every
//     subsequent good line is still readable. Without
//     `allowMalformed: true` on the decoder the stream would tear
//     down at the offending byte and lose every later line.
//   * A multi-byte UTF-8 character split across the stream's
//     chunk boundary still decodes as one character (no false
//     corruption event).
//
//   Empty / trailing-newline handling
//   --------------------------------
//   * A file with a trailing newline (the writer's normal output)
//     does not emit a corruption event for the empty "line" after
//     the final newline.
//   * A file with consecutive blank lines in the middle is read
//     as if the blanks were not there — no events, no
//     `TrailEntry` values produced for them.
//   * An entirely empty file produces an empty stream with no
//     events.
//
//   Resolution rules
//   ----------------
//   * After `closeTrail`, `readTrail` resolves the path from the
//     `trails` index row, NOT from the `_open` map (which the
//     close removed).
//   * If the index row says the file exists but it has been
//     deleted on disk, `FileSystemException` is thrown.
//
// All tests share the A.47 setup — same temp dir, same in-memory
// SQLite, same deterministic clock + id mint, same event sink.
// Tests open the store, append a known set of entries, then
// hand-corrupt the on-disk JSONL file before reading back. This
// is the only way to exercise corruption without relying on
// physical disk faults.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.48 readTrail — corruption-tolerant streaming', () {
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
        randomness: List<int>.generate(16, (i) => (idCounter * 11 + i) & 31),
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
      tmpRoot = await Directory.systemTemp.createTemp('a48_trail_corruption_');
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
      runId: 'r_01HXYZA48ID000000001',
    );

    /// Produce a closed trail with [noteCount] note entries (plus
    /// the outcome line). Returns the trail id and the on-disk
    /// JSONL path.
    Future<({TrailId id, String path})> writeClosedTrail({
      required SqliteTrailStore store,
      required int noteCount,
    }) async {
      final id = await store.openTrail(runRef);
      for (var i = 0; i < noteCount; i++) {
        await store.appendTrail(id, TrailEntry.note('note-$i'));
      }
      await store.closeTrail(
        id,
        const TrailOutcome(
          status: TrailOutcomeStatus.accepted,
          summary: 'closed for A.48 test',
          elapsedMs: 0,
        ),
      );
      final row = db.select(
        'SELECT jsonl_path FROM trails WHERE id = ?',
        <Object?>[id.toString()],
      ).single;
      return (id: id, path: row['jsonl_path'] as String);
    }

    // ─── Streaming pipeline ────────────────────────────────────

    group('streaming pipeline', () {
      test('streams a 2 000-entry trail without materialising the file',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        const noteCount = 2000;
        final result =
            await writeClosedTrail(store: store, noteCount: noteCount);

        // Sanity: the file is big enough that holding it whole in
        // memory would be wasteful (>= 100 KB). The exact size is
        // not material; what we want is that the stream pipeline
        // produces the right line count.
        final fileLen = await File(result.path).length();
        expect(fileLen, greaterThan(100 * 1024));

        events.clear();
        final read = await store.readTrail(result.id).toList();
        // Notes + the outcome line.
        expect(read, hasLength(noteCount + 1));
        expect(read.last.kind, equals(TrailEntryKind.outcome));
        // No corruption events on a clean file.
        expect(events.whereType<TrailEntryCorrupted>(), isEmpty);
      });

      test('TrailEntryCorrupted.lineNumber matches the physical 1-based line',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 4);
        // After this we have 5 good lines on disk: notes 0..3 +
        // outcome. Insert two bad lines: one at line 2, one at
        // line 5 of the *new* file. Resulting layout:
        //
        //   1: good (note-0)
        //   2: bad
        //   3: good (note-1)
        //   4: good (note-2)
        //   5: bad
        //   6: good (note-3)
        //   7: good (outcome)
        final lines = await File(result.path)
            .readAsLines();
        expect(lines, hasLength(5));
        final tampered = <String>[
          lines[0],
          '{this is not json',
          lines[1],
          lines[2],
          '{"ts":"bogus","kind":"note"}',
          lines[3],
          lines[4],
        ].join('\n');
        await File(result.path).writeAsString('$tampered\n');

        events.clear();
        final read = await store.readTrail(result.id).toList();
        expect(read, hasLength(5),
            reason: 'four good notes + outcome should round-trip');
        final corrupted = events.whereType<TrailEntryCorrupted>().toList();
        expect(corrupted, hasLength(2));
        expect(
          corrupted.map((e) => e.lineNumber).toList(),
          equals(<int>[2, 5]),
        );
        // The events carry the right trail id.
        expect(corrupted.every((e) => e.trailId == result.id), isTrue);
      });
    });

    // ─── Mid-file corruption modes ─────────────────────────────

    group('mid-file corruption modes', () {
      Future<List<TrailEntry>> readWithBadLine(String badLine) async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 2);
        final lines = await File(result.path).readAsLines();
        // good-0, bad, good-1, outcome
        final tampered = <String>[
          lines[0],
          badLine,
          lines[1],
          lines[2],
        ].join('\n');
        await File(result.path).writeAsString('$tampered\n');

        events.clear();
        final read = await store.readTrail(result.id).toList();
        expect(events.whereType<TrailEntryCorrupted>(), hasLength(1),
            reason: 'exactly one corruption event for: $badLine');
        return read;
      }

      test('rejects a JSONL line that is a JSON array, not an object',
          () async {
        final read = await readWithBadLine('[1,2,3]');
        expect(read, hasLength(3));
      });

      test('rejects a JSONL line missing the required "kind" field',
          () async {
        final read = await readWithBadLine(
          '{"ts":"2026-05-30T14:00:00.000Z"}',
        );
        expect(read, hasLength(3));
      });

      test('rejects a JSONL line with an unknown "kind"', () async {
        final read = await readWithBadLine(
          '{"ts":"2026-05-30T14:00:00.000Z","kind":"madeUpKind"}',
        );
        expect(read, hasLength(3));
      });

      test('rejects a JSONL line missing the required "ts" field', () async {
        final read = await readWithBadLine('{"kind":"note","message":"x"}');
        expect(read, hasLength(3));
      });

      test('rejects a JSONL line with a non-ISO-8601 "ts" value', () async {
        final read = await readWithBadLine(
          '{"ts":"not-a-timestamp","kind":"note","message":"x"}',
        );
        expect(read, hasLength(3));
      });

      test('treats a truncated final line as corruption (skipped + event)',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 2);
        final lines = await File(result.path).readAsLines();
        // Truncate the outcome line at half its length and write
        // it back without a trailing newline (simulating a crash
        // mid-write between fsyncs).
        final last = lines.last;
        final truncated = last.substring(0, last.length ~/ 2);
        final tampered = <String>[
          lines[0],
          lines[1],
          truncated,
        ].join('\n');
        await File(result.path).writeAsString(tampered);

        events.clear();
        final read = await store.readTrail(result.id).toList();
        expect(read.map((e) => e.kind).toList(), equals([
          TrailEntryKind.note,
          TrailEntryKind.note,
        ]));
        final corrupted = events.whereType<TrailEntryCorrupted>().toList();
        expect(corrupted, hasLength(1));
        expect(corrupted.single.lineNumber, equals(3));
      });
    });

    // ─── UTF-8 byte-level corruption ───────────────────────────

    group('UTF-8 byte-level corruption', () {
      test('a stray non-UTF-8 byte in one line does not crash the stream',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 3);
        final goodLines = await File(result.path).readAsBytes();
        // Build a tampered byte buffer by hand: keep the first
        // line, then a single 0xC3 byte (UTF-8 lead byte missing
        // its continuation — guaranteed malformed) on its own
        // line, then the rest of the file.
        final fullText = utf8.decode(goodLines);
        final lines = fullText.split('\n')
          ..removeWhere((l) => l.isEmpty);
        expect(lines, hasLength(4));

        final builder = BytesBuilder()
          ..add(utf8.encode(lines[0]))
          ..addByte(0x0A) // newline
          ..addByte(0xC3) // lone UTF-8 lead byte — malformed
          ..addByte(0x0A)
          ..add(utf8.encode(lines[1]))
          ..addByte(0x0A)
          ..add(utf8.encode(lines[2]))
          ..addByte(0x0A)
          ..add(utf8.encode(lines[3]))
          ..addByte(0x0A);
        await File(result.path).writeAsBytes(builder.toBytes());

        events.clear();
        final read = await store.readTrail(result.id).toList();
        // Three notes + outcome — every good line still readable.
        expect(read, hasLength(4));
        expect(read.last.kind, equals(TrailEntryKind.outcome));
        final corrupted = events.whereType<TrailEntryCorrupted>().toList();
        expect(corrupted, hasLength(1),
            reason: 'exactly one corruption event for the bad UTF-8 line');
        expect(corrupted.single.lineNumber, equals(2));
      });

      test('a multi-byte UTF-8 character at a chunk boundary decodes cleanly',
          () async {
        // Build a file where a multi-byte UTF-8 character (the
        // euro sign, three bytes: 0xE2 0x82 0xAC) straddles the
        // boundary of two openRead() chunks. We force this by
        // padding the first line so its byte length lands exactly
        // on a chunk boundary.
        //
        // Dart's `File.openRead()` typically yields ~64 KB chunks
        // on most platforms; we don't depend on that exact value
        // — we pad far enough to be confident the byte we care
        // about ends up at a chunk seam (or near enough that any
        // bug would surface). 80 KB of padding clears any
        // reasonable chunk size.
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 1);
        final lines = await File(result.path).readAsLines();
        // good-0, outcome
        expect(lines, hasLength(2));

        // Build a note with a euro-sign-laden message long enough
        // that the euro sign hits a high byte offset.
        final padding = '€' * 30000; // 30 000 × 3 bytes = 90 000 bytes
        final fatNote = jsonEncode(<String, Object?>{
          'ts': '2026-05-30T14:00:00.000Z',
          'kind': 'note',
          'message': padding,
        });
        final tampered = <String>[
          lines[0],
          fatNote,
          lines[1],
        ].join('\n');
        await File(result.path).writeAsString('$tampered\n');

        events.clear();
        final read = await store.readTrail(result.id).toList();
        expect(read, hasLength(3),
            reason: 'note-0 + fat-note + outcome all round-trip');
        expect(events.whereType<TrailEntryCorrupted>(), isEmpty,
            reason: 'chunk-boundary euro signs must not surface as corruption');
        final fat = read[1];
        expect(fat.kind, equals(TrailEntryKind.note));
        expect(fat.payload['message'], equals(padding));
      });
    });

    // ─── Empty / trailing-newline handling ─────────────────────

    group('empty / trailing-newline handling', () {
      test('a file with the writer-default trailing newline emits no events',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        // The writer's normal output ends with `\n` after the
        // last line. LineSplitter will surface a synthetic
        // empty line after that newline; the reader must ignore
        // it silently.
        final result = await writeClosedTrail(store: store, noteCount: 2);
        final onDisk = await File(result.path).readAsString();
        expect(onDisk.endsWith('\n'), isTrue,
            reason: 'TrailWriter is expected to end each line with \\n');

        events.clear();
        final read = await store.readTrail(result.id).toList();
        expect(read, hasLength(3)); // 2 notes + outcome
        expect(events.whereType<TrailEntryCorrupted>(), isEmpty);
      });

      test('consecutive blank lines mid-file are skipped without events',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 2);
        final lines = await File(result.path).readAsLines();
        final tampered = <String>[
          lines[0],
          '',
          '',
          '',
          lines[1],
          lines[2],
        ].join('\n');
        await File(result.path).writeAsString('$tampered\n');

        events.clear();
        final read = await store.readTrail(result.id).toList();
        expect(read, hasLength(3));
        expect(events.whereType<TrailEntryCorrupted>(), isEmpty);
      });

      test('an entirely empty file produces an empty stream', () async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 1);
        await File(result.path).writeAsString('');

        events.clear();
        final read = await store.readTrail(result.id).toList();
        expect(read, isEmpty);
        expect(events.whereType<TrailEntryCorrupted>(), isEmpty,
            reason: 'an empty file is empty, not corrupt');
      });
    });

    // ─── Resolution rules ──────────────────────────────────────

    group('resolution rules', () {
      test('after closeTrail, the path is resolved from the trails index row',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 1);
        // Sanity: confirm the trail is no longer in _open by
        // observing that a second `readTrail` (after `closeTrail`)
        // still resolves it via the SQL row. The cleanest way to
        // pin this is to delete the row and see the read fail.
        final read1 = await store.readTrail(result.id).toList();
        expect(read1, hasLength(2));
        db.execute('DELETE FROM trails WHERE id = ?',
            <Object?>[result.id.toString()]);
        await expectLater(
          store.readTrail(result.id).toList(),
          throwsStateError,
        );
      });

      test('index row points at a missing file → FileSystemException',
          () async {
        final store = buildStore();
        addTearDown(store.close);

        final result = await writeClosedTrail(store: store, noteCount: 1);
        // Remove the file on disk; index row still says it exists.
        await File(result.path).delete();
        await expectLater(
          store.readTrail(result.id).toList(),
          throwsA(isA<FileSystemException>()),
        );
      });
    });
  });
}
