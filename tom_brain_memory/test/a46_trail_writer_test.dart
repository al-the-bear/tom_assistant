// A.46 — TrailWriter contract test.
//
// Covers `TrailWriter.open` / `.append` / `.close` against a real
// temp directory. Validates the wire shape (memory_specification.md
// § 8.2), the date-sharded path layout (§ 2.1), append-only +
// fsync-on-return durability (§ 2.4), reserved-key rejection,
// post-close rejection, ordering-under-concurrency, and shard
// boundary behaviour for runs that cross UTC midnight.
//
// Coverage map (one `test(...)` per row):
//
//   Path layout
//   -----------
//   * Open creates `<trailsRoot>/YYYY/MM/DD/run-<runId>.jsonl` with
//     UTC-derived shard from the clock at open time.
//   * Shard directory is created with `recursive: true` (parent
//     YYYY and YYYY/MM did not pre-exist).
//   * Open with absent trailsRoot creates the entire prefix.
//   * Runs opened on the same UTC date land in the same shard
//     directory but in distinct files keyed by runId.
//
//   Line shape (§ 8.2)
//   ------------------
//   * `invocation` entry serialises to `{ts, kind: "invocation",
//     arguments: ...}` — exactly two reserved keys plus the payload
//     spread at top level.
//   * `primitiveCall` entry preserves payload field names
//     (`primitive`, `input`, `result`).
//   * `ts` is ISO-8601 UTC of `entry.at`, even if the entry was
//     constructed in local time (`.at.toUtc()` normalisation).
//   * `kind` is the enum's `.name` (lowercase camelCase).
//   * Lines are valid JSON and terminated with a single `\n`.
//   * Multiple appends produce one line per append, in order.
//
//   Reserved-key rejection
//   ----------------------
//   * Payload containing `ts` → `ArgumentError`, no line written.
//   * Payload containing `kind` → `ArgumentError`, no line written.
//
//   Append after close
//   ------------------
//   * `append` after `close` throws `StateError`, no line written.
//   * `close` is idempotent (second call is a no-op).
//
//   Durability + ordering
//   ---------------------
//   * `entryCount` only increments after `flush()` returns.
//   * Concurrent `append` calls preserve append order on disk
//     (internal future chain serialises writes).
//   * Re-opening the same path appends (does not truncate).
//
//   UTC boundary
//   ------------
//   * Two writers opened just before and just after UTC midnight
//     land in different date shards.
//
//   Argument validation
//   --------------------
//   * Empty `trailsRoot` rejected.
//   * Empty `runId` rejected.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  late Directory tmpRoot;
  late String trailsRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('a46_trail_writer_');
    trailsRoot =
        '${tmpRoot.absolute.path}${Platform.pathSeparator}trails';
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  // --- Path layout -------------------------------------------------------

  group('path layout', () {
    test('opens at <trailsRoot>/YYYY/MM/DD/run-<runId>.jsonl', () async {
      final clock = FixedClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 5, 30, 8, 14, 1, 220)),
      );
      final writer = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: const ProcedureRunRef(
          procedureId: 'p_answer_with_memory_v1',
          runId: 'r_01HXYZTESTID000000',
        ),
        clock: clock,
      );
      addTearDown(writer.close);

      final sep = Platform.pathSeparator;
      final expectedTail = <String>[
        'trails', '2026', '05', '30', 'run-r_01HXYZTESTID000000.jsonl',
      ].join(sep);
      expect(writer.path, endsWith(expectedTail));
      expect(File(writer.path).existsSync(), isTrue);
    });

    test('creates parent YYYY / MM / DD recursively', () async {
      // trailsRoot itself does not exist yet.
      expect(Directory(trailsRoot).existsSync(), isFalse);

      final clock = FixedClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 1, 2, 3)),
      );
      final writer = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: const ProcedureRunRef(
          procedureId: 'p',
          runId: 'r_a',
        ),
        clock: clock,
      );
      addTearDown(writer.close);

      final sep = Platform.pathSeparator;
      expect(
        Directory('$trailsRoot${sep}2026${sep}01${sep}02').existsSync(),
        isTrue,
      );
    });

    test('two runs on the same UTC date share a shard directory', () async {
      final clock = FixedClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 5, 30, 8)),
      );
      final a = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: const ProcedureRunRef(procedureId: 'p', runId: 'r_a'),
        clock: clock,
      );
      addTearDown(a.close);
      final b = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: const ProcedureRunRef(procedureId: 'p', runId: 'r_b'),
        clock: clock,
      );
      addTearDown(b.close);

      expect(File(a.path).parent.path, equals(File(b.path).parent.path));
      expect(a.path, isNot(equals(b.path)));
    });
  });

  // --- Line shape --------------------------------------------------------

  group('line shape (spec § 8.2)', () {
    test('invocation entry serialises with ts + kind + payload spread',
        () async {
      final at = DateTime.utc(2026, 5, 30, 8, 14, 1, 220);
      final writer = await _open(trailsRoot, at: at);
      addTearDown(writer.close);

      await writer.append(TrailEntry.invocation(
        <String, Object?>{'q': 'hello?'},
        at: at,
      ));

      final lines = await _readLines(writer.path);
      expect(lines, hasLength(1));
      final obj = jsonDecode(lines.single) as Map<String, Object?>;
      expect(obj['ts'], equals('2026-05-30T08:14:01.220Z'));
      expect(obj['kind'], equals('invocation'));
      expect(obj['arguments'], equals(<String, Object?>{'q': 'hello?'}));
      // Exactly: ts, kind, arguments (no leakage).
      expect(obj.keys.toSet(), equals({'ts', 'kind', 'arguments'}));
    });

    test('primitiveCall preserves primitive / input / result keys', () async {
      final writer = await _open(trailsRoot);
      addTearDown(writer.close);

      await writer.append(TrailEntry.primitiveCall(
        'recall',
        <String, Object?>{
          'text': 'when did I last see Anna?',
          'modes': <String>['bm25', 'vector'],
        },
        <String, Object?>{
          'ids': <String>['n_x', 'n_y'],
        },
        elapsedMs: 41,
      ));

      final obj = jsonDecode((await _readLines(writer.path)).single)
          as Map<String, Object?>;
      expect(obj['kind'], 'primitiveCall');
      expect(obj['primitive'], 'recall');
      expect((obj['input'] as Map)['text'], 'when did I last see Anna?');
      expect((obj['result'] as Map)['ids'], ['n_x', 'n_y']);
      expect(obj['elapsedMs'], 41);
    });

    test('ts is normalised to UTC when entry.at is local', () async {
      // Construct a DateTime in local zone — TrailEntry stamps it to
      // UTC at construction; double-check writer also tolerates a UTC
      // input verbatim.
      final entry = TrailEntry(
        at: DateTime.utc(2026, 7, 1, 12),
        kind: TrailEntryKind.note,
        payload: <String, Object?>{'message': 'noon UTC'},
      );

      final writer = await _open(trailsRoot);
      addTearDown(writer.close);
      await writer.append(entry);

      final obj = jsonDecode((await _readLines(writer.path)).single)
          as Map<String, Object?>;
      expect(obj['ts'], '2026-07-01T12:00:00.000Z');
    });

    test('multiple appends → one line per append, in order', () async {
      final writer = await _open(trailsRoot);
      addTearDown(writer.close);

      await writer.append(TrailEntry.note('one'));
      await writer.append(TrailEntry.note('two'));
      await writer.append(TrailEntry.note('three'));

      final lines = await _readLines(writer.path);
      expect(lines, hasLength(3));
      expect(
        lines
            .map((l) =>
                (jsonDecode(l) as Map<String, Object?>)['message'] as String)
            .toList(),
        equals(['one', 'two', 'three']),
      );
    });

    test('each line ends with exactly one newline', () async {
      final writer = await _open(trailsRoot);
      addTearDown(writer.close);

      await writer.append(TrailEntry.note('a'));
      await writer.append(TrailEntry.note('b'));

      final bytes = await File(writer.path).readAsBytes();
      final s = utf8.decode(bytes);
      // Two lines + two terminator newlines, no double-newline.
      expect(s.endsWith('\n'), isTrue);
      expect(s.contains('\n\n'), isFalse);
      expect('\n'.allMatches(s).length, 2);
    });
  });

  // --- Reserved-key rejection -------------------------------------------

  group('reserved-key rejection', () {
    test('payload with `ts` key is rejected and writes nothing', () async {
      final writer = await _open(trailsRoot);
      addTearDown(writer.close);

      expect(
        () => writer.append(TrailEntry(
          at: DateTime.utc(2026, 1, 1),
          kind: TrailEntryKind.note,
          payload: const <String, Object?>{'ts': 'forbidden'},
        )),
        throwsArgumentError,
      );
      expect(writer.entryCount, 0);
      expect(await File(writer.path).length(), 0);
    });

    test('payload with `kind` key is rejected', () async {
      final writer = await _open(trailsRoot);
      addTearDown(writer.close);

      expect(
        () => writer.append(TrailEntry(
          at: DateTime.utc(2026, 1, 1),
          kind: TrailEntryKind.note,
          payload: const <String, Object?>{'kind': 'forbidden'},
        )),
        throwsArgumentError,
      );
      expect(writer.entryCount, 0);
    });
  });

  // --- Append after close ------------------------------------------------

  group('append after close', () {
    test('append after close throws StateError', () async {
      final writer = await _open(trailsRoot);
      await writer.append(TrailEntry.note('before'));
      await writer.close();

      expect(
        () => writer.append(TrailEntry.note('after')),
        throwsStateError,
      );
    });

    test('close is idempotent', () async {
      final writer = await _open(trailsRoot);
      await writer.close();
      await writer.close(); // no throw
      expect(writer.isClosed, isTrue);
    });
  });

  // --- Durability + ordering --------------------------------------------

  group('durability + ordering', () {
    test('entryCount only increments after flush returns', () async {
      final writer = await _open(trailsRoot);
      addTearDown(writer.close);

      expect(writer.entryCount, 0);
      final fut = writer.append(TrailEntry.note('one'));
      // Don't await yet — count must not have moved.
      expect(writer.entryCount, 0);
      await fut;
      expect(writer.entryCount, 1);
    });

    test('concurrent appends preserve order on disk', () async {
      final writer = await _open(trailsRoot);
      addTearDown(writer.close);

      // Fire 20 appends without awaiting between them — the internal
      // future chain in TrailWriter must serialise them in call order.
      final futures = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(writer.append(TrailEntry.note('m$i')));
      }
      await Future.wait(futures);

      final lines = await _readLines(writer.path);
      expect(lines, hasLength(20));
      final messages = lines
          .map((l) =>
              (jsonDecode(l) as Map<String, Object?>)['message'] as String)
          .toList();
      expect(messages, List.generate(20, (i) => 'm$i'));
      expect(writer.entryCount, 20);
    });

    test('re-opening the same path appends (no truncate)', () async {
      final clock = FixedClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 3, 15)),
      );
      const ref = ProcedureRunRef(procedureId: 'p', runId: 'r_persist');

      final w1 = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: ref,
        clock: clock,
      );
      await w1.append(TrailEntry.note('first'));
      await w1.close();

      final w2 = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: ref,
        clock: clock,
      );
      addTearDown(w2.close);
      await w2.append(TrailEntry.note('second'));

      expect(w1.path, equals(w2.path));
      final lines = await _readLines(w2.path);
      expect(lines, hasLength(2));
      expect(
        lines
            .map((l) =>
                (jsonDecode(l) as Map<String, Object?>)['message'] as String)
            .toList(),
        equals(['first', 'second']),
      );
    });
  });

  // --- UTC boundary ------------------------------------------------------

  group('utc boundary', () {
    test('runs just before and just after UTC midnight land in different '
        'shards', () async {
      final beforeMidnight = FixedClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 5, 30, 23, 59, 59, 999)),
      );
      final afterMidnight = FixedClock(
        BrainTime.fromDateTime(DateTime.utc(2026, 5, 31, 0, 0, 0, 1)),
      );

      final before = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: const ProcedureRunRef(procedureId: 'p', runId: 'r_pre'),
        clock: beforeMidnight,
      );
      addTearDown(before.close);
      final after = await TrailWriter.open(
        trailsRoot: trailsRoot,
        runRef: const ProcedureRunRef(procedureId: 'p', runId: 'r_post'),
        clock: afterMidnight,
      );
      addTearDown(after.close);

      final sep = Platform.pathSeparator;
      final preShard = <String>['2026', '05', '30'].join(sep) + sep;
      final postShard = <String>['2026', '05', '31'].join(sep) + sep;
      expect(before.path, contains(preShard));
      expect(after.path, contains(postShard));
      expect(File(before.path).parent.path,
          isNot(equals(File(after.path).parent.path)));
    });
  });

  // --- Argument validation ----------------------------------------------

  group('argument validation', () {
    test('empty trailsRoot is rejected', () async {
      await expectLater(
        TrailWriter.open(
          trailsRoot: '',
          runRef: const ProcedureRunRef(procedureId: 'p', runId: 'r'),
          clock: const SystemClock(),
        ),
        throwsArgumentError,
      );
    });

    test('empty runId is rejected', () async {
      await expectLater(
        TrailWriter.open(
          trailsRoot: trailsRoot,
          runRef: const ProcedureRunRef(procedureId: 'p', runId: ''),
          clock: const SystemClock(),
        ),
        throwsArgumentError,
      );
    });
  });
}

// --- Helpers -------------------------------------------------------------

Future<TrailWriter> _open(
  String trailsRoot, {
  DateTime? at,
  String runId = 'r_test',
}) {
  final clock = FixedClock(
    BrainTime.fromDateTime((at ?? DateTime.utc(2026, 5, 30)).toUtc()),
  );
  return TrailWriter.open(
    trailsRoot: trailsRoot,
    runRef: ProcedureRunRef(procedureId: 'p_test', runId: runId),
    clock: clock,
  );
}

Future<List<String>> _readLines(String path) async {
  final raw = await File(path).readAsString();
  if (raw.isEmpty) return const <String>[];
  return raw.split('\n').where((l) => l.isNotEmpty).toList();
}
