// MemoryProfileLogWriter — the §5.6 per-profile memory log
// (`tom_brain_logging.md` §10 step #8).
//
// For every memory access a run issues (recall / persist / edge / stackPush /
// …) the writer appends one line to `memory/<profile>.log`, each line linking
// to the authoritative `<memory.root>/[profiles/<profile>/]trails/…jsonl`
// entry. Files are size-rotated (10 MB × 5, §8) and writes are best-effort
// (§9): a trail-write failure never fails a turn.

import 'dart:io';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show MemoryAccessRecord;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

MemoryAccessRecord _recall({
  String? profile = 'work',
  String runId = 'disp-fg-run-7',
  List<String> modes = const <String>['bm25', 'vector'],
  int k = 8,
  int returned = 8,
  bool degraded = false,
}) =>
    MemoryAccessRecord(
      primitive: 'recall',
      input: <String, Object?>{'text': 'q', 'modes': modes, 'k': k},
      result: <String, Object?>{
        'nodes': List<Object?>.generate(returned, (i) => <String, Object?>{}),
        'report': <String, Object?>{'degraded': degraded},
      },
      elapsedMs: 5,
      profile: profile,
      runId: runId,
      trailId: 'trail_x',
      turnId: 'turn_x',
      at: DateTime.utc(2026, 6, 1, 12, 0, 0),
    );

MemoryAccessRecord _write({
  required String primitive,
  required Map<String, Object?> input,
  String id = 'node_01JZ',
  String? profile = 'work',
  String runId = 'disp-fg-run-7',
}) =>
    MemoryAccessRecord(
      primitive: primitive,
      input: input,
      result: <String, Object?>{'id': id},
      elapsedMs: 2,
      profile: profile,
      runId: runId,
      trailId: 'trail_x',
      turnId: 'turn_x',
      at: DateTime.utc(2026, 6, 1, 12, 0, 0),
    );

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tbr_memory_log_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File memoryLog(String profile) =>
      File('${root.path}/memory/$profile.log');

  group('MemoryProfileLogWriter — file routing (§5.6)', () {
    test('writes memory/<profile>.log for a named profile', () {
      MemoryProfileLogWriter(root: root).write(_recall());
      expect(memoryLog('work').existsSync(), isTrue,
          reason: 'a named profile buckets into memory/<profile>.log');
    });

    test('a null profile buckets into memory/default.log', () {
      MemoryProfileLogWriter(root: root).write(_recall(profile: null));
      expect(memoryLog('default').existsSync(), isTrue,
          reason: 'the process-default profile logs as "default"');
    });

    test('separate profiles never share a file', () {
      final writer = MemoryProfileLogWriter(root: root);
      writer.write(_recall(profile: 'work'));
      writer.write(_recall(profile: 'home'));
      expect(memoryLog('work').existsSync(), isTrue);
      expect(memoryLog('home').existsSync(), isTrue);
    });
  });

  group('MemoryProfileLogWriter — line format (§5.6)', () {
    test('a recall line carries modes, k, returned, and links to the jsonl',
        () {
      MemoryProfileLogWriter(root: root).write(_recall());
      final line = memoryLog('work').readAsStringSync().trim();

      expect(line, contains('recall'));
      expect(line, contains('bm25+vector'));
      expect(line, contains('k=8'));
      expect(line, contains('8'), reason: 'the returned count');
      // The §5.6 link to the authoritative jsonl entry, with the profile prefix.
      expect(line,
          contains('profiles/work/trails/2026/06/01/run-disp-fg-run-7.jsonl'));
      // Not degraded → no degraded marker.
      expect(line.contains('degraded'), isFalse);
    });

    test('a degraded recall renders the degraded marker', () {
      MemoryProfileLogWriter(root: root).write(_recall(degraded: true));
      expect(memoryLog('work').readAsStringSync(), contains('degraded'));
    });

    test('a null-profile recall links without the profiles/ prefix', () {
      MemoryProfileLogWriter(root: root).write(_recall(profile: null));
      final line = memoryLog('default').readAsStringSync();
      expect(line, contains('trails/2026/06/01/run-disp-fg-run-7.jsonl'));
      expect(line.contains('profiles/'), isFalse,
          reason: 'an unbound store has no profiles/<profile>/ prefix');
    });

    test('persist / edge / stackPush lines carry the primitive, id, and link',
        () {
      final writer = MemoryProfileLogWriter(root: root);
      writer.write(_write(
          primitive: 'persist',
          input: <String, Object?>{'typeName': 'Conclusion', 'values': {}}));
      writer.write(_write(primitive: 'edge', input: <String, Object?>{
        'from': 'node_a',
        'type': 'produced_by',
        'to': 'node_b',
      }));
      writer.write(_write(primitive: 'stackPush', input: <String, Object?>{
        'name': 'recent_runs',
        'nodeId': 'node_a',
        'priority': 1.0,
      }));

      final lines = memoryLog('work').readAsLinesSync();
      expect(lines, hasLength(3));
      expect(lines[0], contains('persist'));
      expect(lines[0], contains('node_01JZ'));
      expect(lines[0], contains('run-disp-fg-run-7.jsonl'));
      expect(lines[1], contains('edge'));
      expect(lines[2], contains('stackPush'));
    });

    test('one line is appended per access', () {
      final writer = MemoryProfileLogWriter(root: root);
      writer.write(_recall());
      writer.write(_recall());
      writer.write(_recall());
      expect(memoryLog('work').readAsLinesSync().where((l) => l.isNotEmpty),
          hasLength(3));
    });
  });

  group('MemoryProfileLogWriter — size rotation (§8)', () {
    test('rotates to <file>.1 when a write would cross the byte cap', () {
      // A tiny cap forces a rotation on the second write.
      final writer = MemoryProfileLogWriter(root: root, rotateBytes: 80);
      writer.write(_recall());
      writer.write(_recall());

      expect(memoryLog('work').existsSync(), isTrue);
      expect(File('${memoryLog('work').path}.1').existsSync(), isTrue,
          reason: 'the first segment rotated to .1');
    });
  });

  group('MemoryProfileLogWriter — best-effort (§9)', () {
    test('a write failure never throws into the caller', () {
      // A file (not a directory) at the trail root makes every mkdir/write
      // under it fail; the writer must swallow it.
      final blocked = File('${root.path}/blocker')..createSync();
      final writer = MemoryProfileLogWriter(root: Directory(blocked.path));
      expect(() => writer.write(_recall()), returnsNormally);
    });
  });
}
