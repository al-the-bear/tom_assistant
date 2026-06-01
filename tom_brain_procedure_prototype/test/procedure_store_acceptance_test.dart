// C.26 — Procedure store + loader + resolver acceptance suite.
//
// This is the dedicated test step for the "C.6 — Procedure store + loader"
// subphase. C.23/C.24/C.25 each seeded one of the three acceptance pillars
// at the *unit* level; C.26 consolidates them and *raises* each to the
// integrated `store → loader → resolver` pipeline level:
//
//   1. disk and memory backends behave identically through the store
//      interface — and now identically all the way up to a *resolved
//      version*, not just at the raw `read` layer the C.23 seed checked;
//   2. the header parser rejects malformed headers — both directly via the
//      loader and when the malformation reaches it through
//      `ProcedureResolver.fromStore`, so the rejection propagates across the
//      whole pipeline;
//   3. the resolver picks the right version — latest by default, exact on
//      request, with the correct `[v_latest, …, v1]` fallback chain — over a
//      composite store that mixes both backends, proving version-merging
//      (resolver) and backend-merging (composite) compose correctly.
//
// The fixtures use real, parseable § 4.4 headers so the loader's parse path
// runs end-to-end on every assertion. Disk fixtures use
// `Directory.systemTemp.createTempSync` (the sibling `tom_brain_memory`
// convention); memory fixtures use a `_FakeMemoryClient implements
// TomBrainMemoryClient` exposing only the `stream` + `get` calls
// `MemoryProcedureStore` makes — the same fake style as
// `procedure_store_test.dart`.

import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;
import 'package:test/test.dart';

/// A real, parseable § 4.4 procedure header (plus a trivial body) for
/// [id]/[version]. The summary embeds the id so equivalence checks can
/// confirm the *same* logical procedure resolved through either backend.
String _source(String id, int version) => '''
/// @procedure
/// id: $id
/// version: $version
/// summary: summary of $id v$version
/// successCriterion: $id v$version succeeds
/// budget: { wallClockMs: 1000, toolCalls: 4 }
/// requires: [ recall, llm ]
Future<ProcedureResult> run(ProcedureInputs inputs) async {
  return ProcedureResult.ok();
}
''';

/// Builds a `Procedure` memory node carrying [source] under [id]'s node id.
Node _procNode(String nodeId, String source) => Node(
      id: NodeId.fromString(nodeId),
      typeName: 'Procedure',
      values: <String, Object?>{'source': source, 'revision': 1},
      createdAt: DateTime.utc(2026),
    );

void main() {
  group('C.26 pillar 1 — backends behave identically through the pipeline',
      () {
    // The same logical procedure set, seeded into both backends. Disk keys
    // are filenames; memory keys are node ids. Resolution must not be able
    // to tell which backend a procedure came from.
    final procedures = <(String id, int version)>[
      ('answer_with_memory_v1', 1),
      ('think_v1', 1),
      ('multi', 1),
      ('multi', 2),
    ];

    late ProcedureStore diskStore;
    late ProcedureStore memoryStore;

    setUp(() {
      // Disk backend — one .dart file per procedure.
      final root = Directory.systemTemp.createTempSync('c26_equiv_disk_');
      addTearDown(() => root.deleteSync(recursive: true));
      final systemDir = Directory('${root.path}/system')..createSync();
      for (final (id, version) in procedures) {
        File('${systemDir.path}/${id}_$version.dart')
            .writeAsStringSync(_source(id, version));
      }
      diskStore = DiskProcedureStore(systemDir: systemDir, userDir: null);

      // Memory backend — one Procedure node per procedure, same sources.
      final client = _FakeMemoryClient();
      var i = 0;
      for (final (id, version) in procedures) {
        // Zero-padded node ids keep MemoryProcedureStore's id-sorted listing
        // deterministic; the value is irrelevant to resolution.
        final nodeId = 'n_${(++i).toString().padLeft(26, '0')}';
        client.nodes.add(_procNode(nodeId, _source(id, version)));
      }
      memoryStore = MemoryProcedureStore(client);
    });

    test('fromStore yields the same ids and versions from either backend',
        () async {
      final fromDisk = await ProcedureResolver.fromStore(diskStore);
      final fromMemory = await ProcedureResolver.fromStore(memoryStore);

      expect(fromDisk.ids, equals(fromMemory.ids));
      expect(fromDisk.ids, equals(['answer_with_memory_v1', 'multi', 'think_v1']));
      for (final id in fromDisk.ids) {
        expect(fromDisk.versions(id), equals(fromMemory.versions(id)),
            reason: 'versions of "$id" must match across backends');
        expect(fromDisk.latestVersion(id), equals(fromMemory.latestVersion(id)));
      }
    });

    test('resolve returns headers identical across backends (ref aside)',
        () async {
      final fromDisk = await ProcedureResolver.fromStore(diskStore);
      final fromMemory = await ProcedureResolver.fromStore(memoryStore);

      for (final id in fromDisk.ids) {
        final d = fromDisk.resolve(id).header;
        final m = fromMemory.resolve(id).header;
        // Header identity (id, version, summary, successCriterion, budget,
        // requires) is backend-independent — only the physical `ref` differs
        // (disk path vs node id), which is exactly what C.23 keyed on.
        expect(d, equals(m),
            reason: 'resolved header of "$id" must be backend-independent');
      }
    });

    test('the multi-version procedure resolves to v2 in either backend',
        () async {
      final fromDisk = await ProcedureResolver.fromStore(diskStore);
      final fromMemory = await ProcedureResolver.fromStore(memoryStore);

      expect(fromDisk.resolve('multi').header.version, 2);
      expect(fromMemory.resolve('multi').header.version, 2);
      expect(fromDisk.fallbackChain('multi').map((p) => p.header.version),
          equals([2, 1]));
      expect(fromMemory.fallbackChain('multi').map((p) => p.header.version),
          equals([2, 1]));
    });
  });

  group('C.26 pillar 2 — the header parser rejects malformed headers', () {
    const loader = ProcedureLoader.shared;

    // Each entry is a distinct malformation. The acceptance contract is one
    // rejection class — `ProcedureHeaderInvalid` (wire code
    // `procedure.header.invalid`) — for every malformed shape.
    final malformed = <String, String>{
      'no @procedure marker': 'Future<void> run() async {}',
      'empty header block': '/// @procedure\nFuture run() async {}',
      'missing id': '''
/// @procedure
/// version: 1
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''',
      'missing version': '''
/// @procedure
/// id: x_v1
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''',
      'missing summary': '''
/// @procedure
/// id: x_v1
/// version: 1
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''',
      'missing successCriterion': '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// budget: { wallClockMs: 1 }
''',
      'missing budget': '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// successCriterion: C.
''',
      'non-integer version': '''
/// @procedure
/// id: x_v1
/// version: one
/// summary: S.
/// successCriterion: C.
/// budget: { wallClockMs: 1 }
''',
      'empty budget block': '''
/// @procedure
/// id: x_v1
/// version: 1
/// summary: S.
/// successCriterion: C.
/// budget: {}
''',
      'non-mapping body': '''
/// @procedure
/// just a bare string
''',
    };

    malformed.forEach((label, source) {
      test('loader rejects: $label', () {
        expect(
          () => loader.parse(source),
          throwsA(
            isA<ProcedureHeaderInvalid>()
                .having((e) => e.code, 'code', 'procedure.header.invalid'),
          ),
          reason: 'malformed header "$label" must be rejected',
        );
      });
    });

    test('a malformed header reaching fromStore propagates the rejection',
        () async {
      // One good procedure + one malformed one in the same store: the whole
      // build fails loudly rather than silently dropping the broken script
      // (C.25 fromStore contract, re-asserted at the acceptance level).
      final store = _FakeStore({
        const ProcedureRef.system('/good.dart'): _source('good', 1),
        const ProcedureRef.system('/bad.dart'): malformed['missing id']!,
      });
      expect(
        () => ProcedureResolver.fromStore(store),
        throwsA(isA<ProcedureHeaderInvalid>()
            .having((e) => e.code, 'code', 'procedure.header.invalid')),
      );
    });
  });

  group('C.26 pillar 3 — the resolver picks the right version', () {
    test('latest by default, exact on request, across a composite of backends',
        () async {
      // answer_with_memory ships v1 on disk and a brain-authored v2 in
      // memory: the composite presents both backends as one store, and the
      // resolver merges their *versions* — proving "which backend" (composite)
      // and "which version" (resolver) compose to pick the right procedure.
      final root = Directory.systemTemp.createTempSync('c26_pick_disk_');
      addTearDown(() => root.deleteSync(recursive: true));
      final systemDir = Directory('${root.path}/system')..createSync();
      File('${systemDir.path}/answer_with_memory_1.dart')
          .writeAsStringSync(_source('answer_with_memory', 1));
      final disk = DiskProcedureStore(systemDir: systemDir, userDir: null);

      final client = _FakeMemoryClient()
        ..nodes.add(_procNode(
          'n_${'2'.padLeft(26, '0')}',
          _source('answer_with_memory', 2),
        ));
      final memory = MemoryProcedureStore(client);

      final composite = CompositeProcedureStore([disk, memory]);
      final resolver = await ProcedureResolver.fromStore(composite);

      // Latest wins regardless of which backend it lives in.
      expect(resolver.resolve('answer_with_memory').header.version, 2);
      // Exact request reaches the disk-backed v1.
      expect(
        resolver.resolve('answer_with_memory', version: 1).header.version,
        1,
      );
      // The fallback chain spans both backends, newest-first.
      expect(
        resolver.fallbackChain('answer_with_memory').map((p) => p.header.version),
        equals([2, 1]),
      );
    });

    test('an unknown id resolves to ProcedureNotFound', () async {
      final resolver = await ProcedureResolver.fromStore(
        _FakeStore({
          const ProcedureRef.system('/only.dart'): _source('only', 1),
        }),
      );
      expect(
        () => resolver.resolve('absent'),
        throwsA(isA<ProcedureNotFound>()
            .having((e) => e.id, 'id', 'absent')
            .having((e) => e.version, 'version', isNull)
            .having((e) => e.code, 'code', procedureNotFoundCode)),
      );
    });

    test('a known id at an unknown version resolves to ProcedureNotFound',
        () async {
      final resolver = await ProcedureResolver.fromStore(
        _FakeStore({
          const ProcedureRef.system('/p1.dart'): _source('p', 1),
          const ProcedureRef.brain('node_p2'): _source('p', 2),
        }),
      );
      expect(resolver.resolve('p').header.version, 2);
      expect(
        () => resolver.resolve('p', version: 5),
        throwsA(isA<ProcedureNotFound>()
            .having((e) => e.id, 'id', 'p')
            .having((e) => e.version, 'version', 5)),
      );
    });
  });
}

/// A minimal in-memory [ProcedureStore] holding a fixed `ref → source` map,
/// reused from the C.25 resolver tests' fake-store shape. A `null` source
/// would model a vanished ref; C.26 only seeds present sources.
final class _FakeStore implements ProcedureStore {
  _FakeStore(this._sources);

  final Map<ProcedureRef, String?> _sources;

  @override
  Future<List<ProcedureRef>> list() async => _sources.keys.toList();

  @override
  bool handles(ProcedureRef ref) => _sources.containsKey(ref);

  @override
  Future<ProcedureSource?> read(ProcedureRef ref) async {
    final src = _sources[ref];
    if (src == null) return null;
    return ProcedureSource(ref: ref, source: src);
  }
}

/// Fake `TomBrainMemoryClient` exposing only the `stream` + `get` calls
/// `MemoryProcedureStore` makes; everything else falls through to
/// `noSuchMethod`. Matches `procedure_store_test.dart`'s fake.
class _FakeMemoryClient implements TomBrainMemoryClient {
  final List<Node> nodes = <Node>[];

  @override
  Stream<Node> stream(StreamQuery query) {
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
