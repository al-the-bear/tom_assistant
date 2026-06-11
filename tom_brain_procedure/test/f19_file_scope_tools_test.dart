// Extension F — the two-tier file sandbox at the tool level, plus the three
// file-scope discovery tools (`tom_brain_procedure_specification.md` § 21.4).
//
// What this suite locks:
//
//   F.19-1 — the read/write tier split: a read tool reaches a read-only root,
//            but a write tool may not target it (the write tier excludes the
//            read-only roots; a read-only scope refuses every write).
//   F.19-2 — `file.readableRoots` / `file.writeableRoots` report the two
//            configured tiers (readable = write ∪ read-only, deduplicated).
//   F.19-3 — `file.list` enumerates the immediate (non-recursive) entries of a
//            directory under the readable roots, spans every readable root, and
//            de-duplicates by scope-relative path.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('F.19-1 read/write tier split', () {
    late Directory writeDir;
    late Directory readDir;

    setUp(() {
      writeDir = Directory.systemTemp.createTempSync('f19_write_');
      readDir = Directory.systemTemp.createTempSync('f19_read_');
    });
    tearDown(() {
      writeDir.deleteSync(recursive: true);
      readDir.deleteSync(recursive: true);
    });

    test('a read-only root is readable but not writeable', () async {
      File(p.join(readDir.path, 'fact.txt')).writeAsStringSync('remembered');
      final ctx = _ctx(FileScope(
        writeRoots: <String>[writeDir.path],
        readRoots: <String>[readDir.path],
      ));

      // The read tier spans both roots, so the read-only file is reachable…
      final read = await _run('file.read', {'path': 'fact.txt'}, ctx);
      expect((read! as Map)['content'], 'remembered');

      // …but a write of the same relative path lands in the writeable root, NOT
      // the read-only one — the read-only tree is never mutated.
      await _run('file.write', {'path': 'fact.txt', 'content': 'changed'}, ctx);
      expect(File(p.join(writeDir.path, 'fact.txt')).readAsStringSync(),
          'changed');
      expect(File(p.join(readDir.path, 'fact.txt')).readAsStringSync(),
          'remembered');
    });

    test('a read-only scope (no write roots) refuses every write', () async {
      File(p.join(readDir.path, 'note.txt')).writeAsStringSync('hi');
      final ctx = _ctx(FileScope(
        writeRoots: const <String>[],
        readRoots: <String>[readDir.path],
      ));

      // Reads work — the scope grants read-only reach.
      final read = await _run('file.read', {'path': 'note.txt'}, ctx);
      expect((read! as Map)['content'], 'hi');

      // Every write tool has an empty writeable tier, so it cannot act.
      await expectLater(
        _run('file.write', {'path': 'x.txt', 'content': 'no'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
      await expectLater(
        _run('file.delete', {'path': 'note.txt'}, ctx),
        throwsA(isA<FileScopeViolation>()),
      );
    });
  });

  group('F.19-2 root-introspection tools', () {
    test('file.readableRoots returns the deduplicated readable union', () async {
      final ctx = _ctx(FileScope(
        writeRoots: <String>['/w/one', '/shared'],
        readRoots: <String>['/shared', '/r/only'],
      ));

      final roots = await _run('file.readableRoots', const {}, ctx);
      expect((roots! as Map)['roots'],
          <String>['/w/one', '/shared', '/r/only']);
    });

    test('file.writeableRoots returns the write tier verbatim', () async {
      final ctx = _ctx(FileScope(
        writeRoots: <String>['/w/one', '/w/two'],
        readRoots: <String>['/r/only'],
      ));

      final roots = await _run('file.writeableRoots', const {}, ctx);
      expect((roots! as Map)['roots'], <String>['/w/one', '/w/two']);
    });
  });

  group('F.19-3 file.list discovery', () {
    late Directory writeDir;
    late Directory readDir;

    setUp(() {
      writeDir = Directory.systemTemp.createTempSync('f19_list_w_');
      readDir = Directory.systemTemp.createTempSync('f19_list_r_');
    });
    tearDown(() {
      writeDir.deleteSync(recursive: true);
      readDir.deleteSync(recursive: true);
    });

    test('lists the immediate entries of the root, non-recursively', () async {
      File(p.join(writeDir.path, 'a.txt')).writeAsStringSync('a');
      final sub = Directory(p.join(writeDir.path, 'nested'))..createSync();
      File(p.join(sub.path, 'deep.txt')).writeAsStringSync('d');
      final ctx = _ctx(FileScope(writeRoots: <String>[writeDir.path]));

      final listed = await _run('file.list', const {}, ctx);
      final entries = (listed! as Map)['entries'] as List;
      final byName = <String, String>{
        for (final e in entries.cast<Map>())
          e['name'] as String: e['type'] as String,
      };

      expect(byName, <String, String>{'a.txt': 'file', 'nested': 'dir'});
    });

    test('lists a named sub-directory under the readable roots', () async {
      final docs = Directory(p.join(readDir.path, 'docs'))..createSync();
      File(p.join(docs.path, 'one.md')).writeAsStringSync('1');
      final ctx = _ctx(FileScope(
        writeRoots: <String>[writeDir.path],
        readRoots: <String>[readDir.path],
      ));

      final listed = await _run('file.list', {'path': 'docs'}, ctx);
      final entries = ((listed! as Map)['entries'] as List).cast<Map>();

      expect(entries, hasLength(1));
      expect(entries.single['path'], p.join('docs', 'one.md'));
    });

    test('spans every readable root and dedups by scope-relative path',
        () async {
      File(p.join(writeDir.path, 'shared.txt')).writeAsStringSync('w');
      File(p.join(readDir.path, 'shared.txt')).writeAsStringSync('r');
      File(p.join(readDir.path, 'only_read.txt')).writeAsStringSync('r');
      final ctx = _ctx(FileScope(
        writeRoots: <String>[writeDir.path],
        readRoots: <String>[readDir.path],
      ));

      final listed = await _run('file.list', const {}, ctx);
      final names = ((listed! as Map)['entries'] as List)
          .cast<Map>()
          .map((e) => e['name'] as String)
          .toList();

      // `shared.txt` is reachable through both roots but reported once; the
      // read-only-root's `only_read.txt` is discovered too.
      expect(names, <String>['only_read.txt', 'shared.txt']);
    });

    test('a missing sub-directory contributes no entries', () async {
      final ctx = _ctx(FileScope(writeRoots: <String>[writeDir.path]));
      final listed = await _run('file.list', {'path': 'absent'}, ctx);
      expect((listed! as Map)['entries'], isEmpty);
    });
  });
}

/// Runs a registered basic tool by [name] against [ctx].
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

/// Builds a tool context over an explicit two-tier [scope], with uncapped
/// budget and a no-op memory stub (the file tools touch neither).
ToolContext _ctx(FileScope scope) => ToolContext(
      budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
      memory: _NoMemory(),
      fileScope: scope,
    );

/// A memory client the file tools never reach: every method throws.
class _NoMemory implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('file tools must not touch memory');
}
