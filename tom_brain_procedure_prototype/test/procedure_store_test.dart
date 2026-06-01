// C.23 — ProcedureStore unit tests.
//
// Covers the procedure store interface and its two backends + composite:
//
//   - value semantics of `ProcedureOrigin` / `ProcedureRef` /
//     `ProcedureSource`;
//   - `DiskProcedureStore` over real temp directories (system + user),
//     including the missing-user-dir branch, extension filtering,
//     deterministic ordering, read of a present/absent file, and the
//     wrong-origin guard;
//   - `MemoryProcedureStore` over a fake `TomBrainMemoryClient`,
//     including streaming `Procedure` nodes, reading the `source` field,
//     and the missing/wrong-type/non-string-source `null` branches;
//   - `CompositeProcedureStore` fanning `list` and routing `read`;
//   - a backend-equivalence check proving disk and memory behave
//     identically *through the `ProcedureStore` interface* (the C.26
//     contract, exercised here at the store layer).
//
// Temp directories use `Directory.systemTemp.createTempSync`, matching
// the sibling `tom_brain_memory` test convention.

import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;
import 'package:test/test.dart';

void main() {
  group('C.23 ProcedureOrigin', () {
    test('isDisk / isMemory partition the origins', () {
      expect(ProcedureOrigin.system.isDisk, isTrue);
      expect(ProcedureOrigin.user.isDisk, isTrue);
      expect(ProcedureOrigin.brain.isDisk, isFalse);

      expect(ProcedureOrigin.brain.isMemory, isTrue);
      expect(ProcedureOrigin.system.isMemory, isFalse);
      expect(ProcedureOrigin.user.isMemory, isFalse);
    });
  });

  group('C.23 ProcedureRef', () {
    test('value equality + hashCode on (origin, locator)', () {
      const a = ProcedureRef(origin: ProcedureOrigin.system, locator: '/x.dart');
      const b = ProcedureRef.system('/x.dart');
      const c = ProcedureRef.system('/y.dart');
      const d = ProcedureRef.user('/x.dart');

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('named constructors set origin', () {
      expect(const ProcedureRef.system('/s').origin, ProcedureOrigin.system);
      expect(const ProcedureRef.user('/u').origin, ProcedureOrigin.user);
      expect(const ProcedureRef.brain('n_1').origin, ProcedureOrigin.brain);
      expect(const ProcedureRef.brain('n_1').locator, 'n_1');
    });
  });

  group('C.23 ProcedureSource', () {
    test('value equality on (ref, source)', () {
      const ref = ProcedureRef.system('/x.dart');
      const s1 = ProcedureSource(ref: ref, source: 'abc');
      const s2 = ProcedureSource(ref: ref, source: 'abc');
      const s3 = ProcedureSource(ref: ref, source: 'def');
      expect(s1, equals(s2));
      expect(s1.hashCode, equals(s2.hashCode));
      expect(s1, isNot(equals(s3)));
    });
  });

  group('C.23 DiskProcedureStore', () {
    late Directory root;
    late Directory systemDir;
    late Directory userDir;

    setUp(() {
      root = Directory.systemTemp.createTempSync('c23_disk_store_');
      systemDir = Directory('${root.path}/system')..createSync();
      userDir = Directory('${root.path}/user')..createSync();
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('handles only disk origins', () {
      final store = DiskProcedureStore(systemDir: systemDir, userDir: userDir);
      expect(store.handles(const ProcedureRef.system('/a')), isTrue);
      expect(store.handles(const ProcedureRef.user('/a')), isTrue);
      expect(store.handles(const ProcedureRef.brain('n_1')), isFalse);
    });

    test('list enumerates .dart files, tags origin, sorts deterministically',
        () async {
      File('${systemDir.path}/answer_with_memory_v1.dart')
          .writeAsStringSync('// sys a');
      File('${systemDir.path}/think_v1.dart').writeAsStringSync('// sys b');
      File('${userDir.path}/custom_v1.dart').writeAsStringSync('// usr');
      // Non-procedure file ignored.
      File('${systemDir.path}/README.md').writeAsStringSync('notes');

      final store = DiskProcedureStore(systemDir: systemDir, userDir: userDir);
      final refs = await store.list();

      expect(refs.length, 3);
      // System origins come before user origins (enum order), each
      // sorted by path.
      expect(refs[0].origin, ProcedureOrigin.system);
      expect(refs[1].origin, ProcedureOrigin.system);
      expect(refs[2].origin, ProcedureOrigin.user);
      expect(
        refs[0].locator,
        endsWith('answer_with_memory_v1.dart'),
      );
      expect(refs[1].locator, endsWith('think_v1.dart'));
      expect(refs[2].locator, endsWith('custom_v1.dart'));
    });

    test('matches a custom extension', () async {
      File('${systemDir.path}/proc_v1.d4rt').writeAsStringSync('// d4rt');
      File('${systemDir.path}/skip.dart').writeAsStringSync('// dart');

      final store = DiskProcedureStore(
        systemDir: systemDir,
        userDir: userDir,
        extension: '.d4rt',
      );
      final refs = await store.list();
      expect(refs.length, 1);
      expect(refs.single.locator, endsWith('proc_v1.d4rt'));
    });

    test('tolerates a missing user directory', () async {
      File('${systemDir.path}/a_v1.dart').writeAsStringSync('// sys');
      final store = DiskProcedureStore(
        systemDir: systemDir,
        userDir: Directory('${root.path}/does_not_exist'),
      );
      final refs = await store.list();
      expect(refs.length, 1);
      expect(refs.single.origin, ProcedureOrigin.system);
    });

    test('a missing system directory yields an empty list', () async {
      systemDir.deleteSync(recursive: true);
      final store = DiskProcedureStore(systemDir: systemDir, userDir: null);
      expect(await store.list(), isEmpty);
    });

    test('read returns the verbatim source for a present ref', () async {
      const body = '/// @procedure\n/// id: a_v1\nFuture run() async {}';
      final file = File('${systemDir.path}/a_v1.dart')..writeAsStringSync(body);
      final store = DiskProcedureStore(systemDir: systemDir, userDir: userDir);

      final ref = ProcedureRef.system(file.path);
      final src = await store.read(ref);
      expect(src, isNotNull);
      expect(src!.source, body);
      expect(src.ref, ref);
    });

    test('read returns null for a deleted file', () async {
      final ref = ProcedureRef.system('${systemDir.path}/ghost.dart');
      final store = DiskProcedureStore(systemDir: systemDir, userDir: userDir);
      expect(await store.read(ref), isNull);
    });

    test('read of a brain ref throws ArgumentError', () async {
      final store = DiskProcedureStore(systemDir: systemDir, userDir: userDir);
      expect(
        () => store.read(const ProcedureRef.brain('n_1')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('C.23 MemoryProcedureStore', () {
    test('handles only the brain origin', () {
      final store = MemoryProcedureStore(_FakeMemoryClient());
      expect(store.handles(const ProcedureRef.brain('n_1')), isTrue);
      expect(store.handles(const ProcedureRef.system('/a')), isFalse);
      expect(store.handles(const ProcedureRef.user('/a')), isFalse);
    });

    test('list streams Procedure nodes, sorted by node id', () async {
      final client = _FakeMemoryClient()
        ..nodes.addAll([
          _procNode('n_00000000000000000000000002', 'src2'),
          _procNode('n_00000000000000000000000001', 'src1'),
          // A non-procedure node must not appear.
          Node(
            id: NodeId.fromString('n_00000000000000000000000009'),
            typeName: 'Conclusion',
            values: const <String, Object?>{'text': 'x'},
            createdAt: DateTime.utc(2026),
          ),
        ]);
      final store = MemoryProcedureStore(client);

      final refs = await store.list();
      expect(refs.map((r) => r.locator), [
        'n_00000000000000000000000001',
        'n_00000000000000000000000002',
      ]);
      expect(refs.every((r) => r.origin == ProcedureOrigin.brain), isTrue);
      // The stream filter targets the Procedure type only.
      expect(client.lastStreamQuery!.filter.typeNames, {'Procedure'});
    });

    test('read fetches the node and extracts the source field', () async {
      final client = _FakeMemoryClient()
        ..nodes.add(_procNode('n_00000000000000000000000001', '// the source'));
      final store = MemoryProcedureStore(client);

      final src = await store.read(
        const ProcedureRef.brain('n_00000000000000000000000001'),
      );
      expect(src, isNotNull);
      expect(src!.source, '// the source');
    });

    test('read returns null when the node is gone', () async {
      final store = MemoryProcedureStore(_FakeMemoryClient());
      expect(
        await store.read(const ProcedureRef.brain('n_00000000000000000000000001')),
        isNull,
      );
    });

    test('read returns null when the node is the wrong type', () async {
      final client = _FakeMemoryClient()
        ..nodes.add(Node(
          id: NodeId.fromString('n_00000000000000000000000001'),
          typeName: 'Conclusion',
          values: const <String, Object?>{'source': '// not a procedure'},
          createdAt: DateTime.utc(2026),
        ));
      final store = MemoryProcedureStore(client);
      expect(
        await store.read(const ProcedureRef.brain('n_00000000000000000000000001')),
        isNull,
      );
    });

    test('read returns null when the source field is missing/non-string',
        () async {
      final client = _FakeMemoryClient()
        ..nodes.add(Node(
          id: NodeId.fromString('n_00000000000000000000000001'),
          typeName: 'Procedure',
          values: const <String, Object?>{'revision': 1},
          createdAt: DateTime.utc(2026),
        ));
      final store = MemoryProcedureStore(client);
      expect(
        await store.read(const ProcedureRef.brain('n_00000000000000000000000001')),
        isNull,
      );
    });

    test('honours a custom type name + source field', () async {
      final client = _FakeMemoryClient()
        ..nodes.add(Node(
          id: NodeId.fromString('n_00000000000000000000000001'),
          typeName: 'BrainProc',
          values: const <String, Object?>{'body': '// custom'},
          createdAt: DateTime.utc(2026),
        ));
      final store = MemoryProcedureStore(
        client,
        procedureTypeName: 'BrainProc',
        sourceField: 'body',
      );
      final refs = await store.list();
      expect(refs.single.locator, 'n_00000000000000000000000001');
      final src = await store.read(refs.single);
      expect(src!.source, '// custom');
    });

    test('read of a disk ref throws ArgumentError', () async {
      final store = MemoryProcedureStore(_FakeMemoryClient());
      expect(
        () => store.read(const ProcedureRef.system('/a.dart')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('C.23 CompositeProcedureStore', () {
    late Directory root;
    late Directory systemDir;
    late DiskProcedureStore disk;
    late _FakeMemoryClient client;
    late MemoryProcedureStore memory;
    late CompositeProcedureStore composite;

    setUp(() {
      root = Directory.systemTemp.createTempSync('c23_composite_');
      systemDir = Directory('${root.path}/system')..createSync();
      File('${systemDir.path}/sys_v1.dart').writeAsStringSync('// sys');
      disk = DiskProcedureStore(systemDir: systemDir, userDir: null);

      client = _FakeMemoryClient()
        ..nodes.add(_procNode('n_00000000000000000000000001', '// brain'));
      memory = MemoryProcedureStore(client);

      composite = CompositeProcedureStore([disk, memory]);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('list fans across backends in order', () async {
      final refs = await composite.list();
      expect(refs.length, 2);
      expect(refs[0].origin, ProcedureOrigin.system); // disk first
      expect(refs[1].origin, ProcedureOrigin.brain); // memory second
    });

    test('handles is the union of backends', () {
      // Full composite covers all three origins.
      expect(composite.handles(const ProcedureRef.system('/a')), isTrue);
      expect(composite.handles(const ProcedureRef.user('/u')), isTrue);
      expect(composite.handles(const ProcedureRef.brain('n_1')), isTrue);

      // A memory-only composite does not handle disk origins, proving
      // `handles` is the union of its backends' ownership, not a blanket
      // "true".
      final memoryOnly = CompositeProcedureStore([memory]);
      expect(memoryOnly.handles(const ProcedureRef.brain('n_1')), isTrue);
      expect(memoryOnly.handles(const ProcedureRef.system('/a')), isFalse);
      expect(memoryOnly.handles(const ProcedureRef.user('/u')), isFalse);
    });

    test('read routes to the owning backend', () async {
      final refs = await composite.list();
      final diskSrc = await composite.read(refs[0]);
      final brainSrc = await composite.read(refs[1]);
      expect(diskSrc!.source, '// sys');
      expect(brainSrc!.source, '// brain');
    });

    test('read of an unhandled ref throws ArgumentError', () async {
      // A memory-only composite owns no disk origin, so a system-ref
      // read finds no backend and throws.
      final memoryOnly = CompositeProcedureStore([memory]);
      expect(
        () => memoryOnly.read(const ProcedureRef.system('/nope.dart')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('C.23 backend equivalence through the ProcedureStore interface', () {
    test('disk and memory backends both satisfy list+read identically',
        () async {
      const body = '/// @procedure\n/// id: equiv_v1\nFuture run() async {}';

      // Disk store seeded with one procedure.
      final root = Directory.systemTemp.createTempSync('c23_equiv_');
      addTearDown(() => root.deleteSync(recursive: true));
      final systemDir = Directory('${root.path}/system')..createSync();
      File('${systemDir.path}/equiv_v1.dart').writeAsStringSync(body);
      final ProcedureStore diskStore =
          DiskProcedureStore(systemDir: systemDir, userDir: null);

      // Memory store seeded with one procedure carrying the same source.
      final client = _FakeMemoryClient()
        ..nodes.add(_procNode('n_00000000000000000000000001', body));
      final ProcedureStore memoryStore = MemoryProcedureStore(client);

      for (final store in <ProcedureStore>[diskStore, memoryStore]) {
        final refs = await store.list();
        expect(refs, hasLength(1),
            reason: '${store.runtimeType} should list exactly one ref');
        final ref = refs.single;
        expect(store.handles(ref), isTrue);
        final src = await store.read(ref);
        expect(src, isNotNull);
        expect(src!.source, body,
            reason: '${store.runtimeType} should read the same source');
        expect(src.ref, ref);
      }
    });
  });
}

Node _procNode(String id, String source) => Node(
      id: NodeId.fromString(id),
      typeName: 'Procedure',
      values: <String, Object?>{'source': source, 'revision': 1},
      createdAt: DateTime.utc(2026),
    );

/// Fake `TomBrainMemoryClient` exposing only the `stream` + `get` calls
/// `MemoryProcedureStore` makes. Everything else falls through to
/// `noSuchMethod`.
class _FakeMemoryClient implements TomBrainMemoryClient {
  final List<Node> nodes = <Node>[];
  StreamQuery? lastStreamQuery;

  @override
  Stream<Node> stream(StreamQuery query) {
    lastStreamQuery = query;
    final types = query.filter.typeNames;
    return Stream<Node>.fromIterable(
      nodes.where((n) => types.isEmpty || types.contains(n.typeName)),
    );
  }

  @override
  Future<Node?> get(NodeId id) async {
    for (final node in nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
