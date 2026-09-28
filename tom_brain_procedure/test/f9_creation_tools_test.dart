// Todo 9 (G-C2) — the creation tool families
// (`creation_specification.md` § 5.2, § 5.3, § 12.1 decision 2).
//
// What this suite locks:
//
//   F.9-1 — `file.edit` applies a structured replace / insert / delete by
//           1-based line range, writing the result back within scope, and
//           refuses an out-of-range or escaping edit.
//   F.9-2 — `file.diff` produces a unified-style line diff between a file and a
//           proposed content without writing anything.
//   F.9-3 — the `analyze.*` / `test.*` families route through the allow-listed
//           `ToolProcessSurface`, each naming exactly one fixed executable —
//           never a raw `Process.run` (no general shell, § 5.4) — and raise
//           `ToolSurfaceUnavailable` when the run carries no process surface.
//           `analyze.format` is `readOnly`, so it is also run for real to
//           prove it writes nothing (`-o none`).
//   F.9-4 — `file.delete` is the reversible counterpart to `file.write`: it
//           removes a file within scope (the rollback of a rejected draft,
//           § 4.7), is idempotent on a missing target, and refuses an escaping
//           path before touching the filesystem.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show TomBrainMemoryClient;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('f9_root_'));
  tearDown(() => root.deleteSync(recursive: true));

  group('F.9-1 file.edit structured edits', () {
    test('replace swaps a 1-based inclusive line range', () async {
      File(p.join(root.path, 'a.txt'))
          .writeAsStringSync('one\ntwo\nthree\n');
      final ctx = _ctx(roots: <String>[root.path]);

      final out = await _run(
        'file.edit',
        {'path': 'a.txt', 'op': 'replace', 'start': 2, 'end': 2, 'text': 'TWO'},
        ctx,
      );

      expect((out! as Map)['op'], 'replace');
      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(),
          'one\nTWO\nthree\n');
    });

    test('insert places text before the start line', () async {
      File(p.join(root.path, 'a.txt')).writeAsStringSync('one\ntwo\n');
      final ctx = _ctx(roots: <String>[root.path]);

      await _run(
        'file.edit',
        {'path': 'a.txt', 'op': 'insert', 'start': 2, 'text': 'between'},
        ctx,
      );

      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(),
          'one\nbetween\ntwo\n');
    });

    test('delete removes a 1-based inclusive range', () async {
      File(p.join(root.path, 'a.txt'))
          .writeAsStringSync('one\ntwo\nthree\n');
      final ctx = _ctx(roots: <String>[root.path]);

      await _run(
        'file.edit',
        {'path': 'a.txt', 'op': 'delete', 'start': 1, 'end': 2},
        ctx,
      );

      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(), 'three\n');
    });

    test('an out-of-range replace is refused', () async {
      File(p.join(root.path, 'a.txt')).writeAsStringSync('one\n');
      final ctx = _ctx(roots: <String>[root.path]);

      await expectLater(
        _run('file.edit',
            {'path': 'a.txt', 'op': 'replace', 'start': 5, 'text': 'x'}, ctx),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a path escaping the root is rejected before any write', () async {
      final ctx = _ctx(roots: <String>[root.path]);
      await expectLater(
        _run('file.edit',
            {'path': '../escape.txt', 'op': 'insert', 'start': 1, 'text': 'x'},
            ctx),
        throwsA(isA<FileScopeViolation>()),
      );
    });
  });

  group('F.9-2 file.diff', () {
    test('reports added / removed lines against the on-disk file', () async {
      File(p.join(root.path, 'a.txt')).writeAsStringSync('one\ntwo\n');
      final ctx = _ctx(roots: <String>[root.path]);

      final out = await _run(
        'file.diff',
        {'path': 'a.txt', 'content': 'one\nTWO\n'},
        ctx,
      );
      final m = out! as Map;
      final diff = m['diff'] as String;

      expect(m['changed'], isTrue);
      expect(diff, contains('-two'));
      expect(diff, contains('+TWO'));
      expect(diff, contains(' one'));
      // Read-only: the on-disk file is untouched.
      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(), 'one\ntwo\n');
    });

    test('identical content reports no change', () async {
      File(p.join(root.path, 'a.txt')).writeAsStringSync('same\n');
      final ctx = _ctx(roots: <String>[root.path]);

      final out = await _run(
        'file.diff',
        {'path': 'a.txt', 'content': 'same\n'},
        ctx,
      );

      expect((out! as Map)['changed'], isFalse);
    });
  });

  group('F.9-3 analyze.* / test.* route through the process surface', () {
    test('analyze.dart runs `dart analyze` on the resolved path', () async {
      File(p.join(root.path, 'lib.dart')).writeAsStringSync('void main() {}');
      final process = _FakeProcess();
      final ctx = _ctx(roots: <String>[root.path], process: process);

      final out =
          await _run('analyze.dart', {'path': 'lib.dart'}, ctx) as Map;

      expect(process.calls, hasLength(1));
      expect(process.calls.single.exe, 'dart');
      expect(process.calls.single.args.first, 'analyze');
      expect(process.calls.single.args.last,
          p.join(_norm(root.path), 'lib.dart'));
      expect(out['ok'], isTrue);
      expect(out['exitCode'], 0);
    });

    test('analyze.format runs `dart format -o none --set-exit-if-changed`',
        () async {
      File(p.join(root.path, 'lib.dart')).writeAsStringSync('void main(){}');
      final process = _FakeProcess(
          result: const ProcessRunResult(
              exitCode: 1, stdout: '', stderr: 'changed'));
      final ctx = _ctx(roots: <String>[root.path], process: process);

      final out =
          await _run('analyze.format', {'path': 'lib.dart'}, ctx) as Map;

      expect(process.calls.single.exe, 'dart');
      expect(process.calls.single.args,
          containsAllInOrder(
              <String>['format', '-o', 'none', '--set-exit-if-changed']));
      expect(out['ok'], isFalse);
    });

    // `readOnly` is the axis the read-only tool-policy profile admits on, so a
    // tool declaring it must write nothing. `--set-exit-if-changed` only sets
    // the exit code; `dart format` still writes unless told `-o none`. The case
    // above asserts the command and would pass either way, so this one runs
    // the REAL formatter and compares bytes.
    test('analyze.format reports drift and leaves the file byte-identical',
        () async {
      const unformatted = 'void main(){print( 1 );}\n';
      final file = File(p.join(root.path, 'lib.dart'))
        ..writeAsStringSync(unformatted);
      final ctx = _ctx(
          roots: <String>[root.path], process: const ProcessRunToolSurface());

      final out =
          await _run('analyze.format', {'path': 'lib.dart'}, ctx) as Map;

      expect(file.readAsStringSync(), unformatted,
          reason: 'a readOnly tool rewrote the file it was pointed at');
      expect(out['ok'], isFalse, reason: 'the drift must still be reported');
      expect(out['exitCode'], 1);
    });

    test('analyze.schema validates via the `tom` CLI', () async {
      File(p.join(root.path, 'doc.yaml')).writeAsStringSync('a: 1');
      final process = _FakeProcess();
      final ctx = _ctx(roots: <String>[root.path], process: process);

      await _run('analyze.schema', {'path': 'doc.yaml'}, ctx);

      expect(process.calls.single.exe, 'tom');
      expect(process.calls.single.args,
          containsAllInOrder(<String>['schema', 'validate']));
    });

    test('test.run runs `testkit :test` in the resolved directory', () async {
      final pkg = Directory(p.join(root.path, 'pkg'))..createSync();
      final process = _FakeProcess();
      final ctx = _ctx(roots: <String>[root.path], process: process);

      await _run('test.run', {'path': 'pkg'}, ctx);

      expect(process.calls.single.exe, 'testkit');
      expect(process.calls.single.args, <String>[':test']);
      expect(process.calls.single.cwd, _norm(pkg.path));
    });

    test('test.baseline runs `testkit :baseline`', () async {
      final process = _FakeProcess();
      final ctx = _ctx(roots: <String>[root.path], process: process);

      await _run('test.baseline', const {}, ctx);

      expect(process.calls.single.exe, 'testkit');
      expect(process.calls.single.args, <String>[':baseline']);
    });

    test('a process tool without a process surface fails loudly', () async {
      final ctx = _ctx(roots: <String>[root.path]); // no process surface
      await expectLater(
        _run('analyze.dart', {'path': '.'}, ctx),
        throwsA(isA<ToolSurfaceUnavailable>()
            .having((e) => e.surface, 'surface', 'process')),
      );
    });
  });

  group('F.9-4 file.delete is the reversible counterpart to file.write', () {
    test('removes an in-scope file and reports it existed', () async {
      final victim = File(p.join(root.path, 'draft.txt'))
        ..writeAsStringSync('rejected draft');
      final ctx = _ctx(roots: <String>[root.path]);

      final out = await _run('file.delete', {'path': 'draft.txt'}, ctx) as Map;

      expect(out['path'], 'draft.txt');
      expect(out['deleted'], isTrue);
      expect(victim.existsSync(), isFalse);
    });

    test('is idempotent: deleting a missing target is not an error', () async {
      final ctx = _ctx(roots: <String>[root.path]);

      final out = await _run('file.delete', {'path': 'gone.txt'}, ctx) as Map;

      expect(out['deleted'], isFalse);
    });

    test('a path escaping the root is rejected before any filesystem touch',
        () async {
      final sibling = File(p.join(root.parent.path, 'escape.txt'))
        ..writeAsStringSync('outside');
      addTearDown(() {
        if (sibling.existsSync()) sibling.deleteSync();
      });
      final ctx = _ctx(roots: <String>[root.path]);

      await expectLater(
        _run('file.delete', {'path': '../escape.txt'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
      // The out-of-scope file was never touched.
      expect(sibling.existsSync(), isTrue);
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

String _norm(String path) => p.normalize(p.absolute(path));

Future<Object?> _run(
  String name,
  Map<String, Object?> args,
  ToolContext ctx,
) {
  final registry = ToolRegistry();
  registerBasicTools(registry);
  final tool = registry.lookup(name);
  if (tool == null) throw StateError('no tool "$name"');
  return tool.run(args, ctx);
}

ToolContext _ctx({
  required List<String> roots,
  ToolProcessSurface? process,
}) =>
    ToolContext(
      budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
      memory: _NoMemory(),
      fileScope: FileScope.fromPriorityList(roots),
      process: process,
    );

/// A deterministic [ToolProcessSurface] fake: records each call and returns a
/// canned [ProcessRunResult]. No process is spawned.
class _FakeProcess implements ToolProcessSurface {
  _FakeProcess({
    this.result =
        const ProcessRunResult(exitCode: 0, stdout: 'ok', stderr: ''),
  });

  final ProcessRunResult result;
  final List<({String exe, List<String> args, String? cwd})> calls =
      <({String exe, List<String> args, String? cwd})>[];

  @override
  Future<ProcessRunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    calls.add((exe: executable, args: arguments, cwd: workingDirectory));
    return result;
  }
}

/// A memory client the file / process tools never touch (they reach only the
/// file-scope roots and the process surface).
class _NoMemory implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the creation tool families do not use memory');
}
