// Todo 7 (G-PR4 / hard principle 6) — the procedure revision chain end-to-end
// against the concrete store (`procedure_specification.md` § 7.2).
//
// procedure_queries_test.dart pins the `ProcedureRevisionChain` *composition*
// against a recording fake (which edges it walks, the oldest→newest order). This
// suite proves the same walk over a *real* on-disk `SqliteTomBrainMemory`: that
// `superseded_by` edges persisted through `store.edge` are traversed by
// `edgesOf` both ways, and — the invariant the chain exists to guarantee — that
// a superseded predecessor is *never deleted*: every revision in the chain is
// still readable by id after newer revisions supersede it (HP6 — revision is
// structural, never destructive).
//
// Like p2_16 / p2_17 these cases open the real store, which refuses to boot
// without the packaged vec0 binary (P1.1), so the group is skipped — not failed
// — when no binary is present for the running platform.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeType, NodeDraft, NodeId, ProcedureStatus, Scope, Vec;

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector; the Procedure embedding source is
/// `[name, summary]` (non-`none`), so a seeded Procedure carries one.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 / p2_17.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  Future<SqliteTomBrainMemory> openStore() async {
    final root = Directory.systemTemp.createTempSync('tbm_prc_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final store = SqliteTomBrainMemory();
    addTearDown(store.close);
    await store.open(MemoryConfig.forTesting(
      root: root.path,
      binariesRoot: vecRoot!,
    ));
    return store;
  }

  /// Persists one Procedure revision (logical id [name], [revision]) and returns
  /// its stable node id. Each revision is a distinct node — a revision is a new
  /// node the predecessor points to, never an in-place edit.
  Future<NodeId> seedRevision(
    SqliteTomBrainMemory store, {
    required String name,
    required int revision,
    String status = 'active',
  }) =>
      store.persist(
        NodeDraft(
          typeName: 'Procedure',
          values: <String, Object?>{
            'name': name,
            'summary': 'Revision $revision of $name.',
            'code': '// $name r$revision body',
            'status': status,
            'revision': revision,
            'requires': const <String>[],
          },
          embedding: _v768(seed: name.length + revision),
        ),
        scope: Scope(producer: 'prc:seed', idempotencyKey: '$name-r$revision'),
      );

  group('ProcedureRevisionChain over the real store (needs vec0)', () {
    test('walks superseded_by both ways, returns oldest → newest, and never '
        'deletes a superseded predecessor (HP6)', () async {
      final store = await openStore();
      // Three revisions of one logical procedure, each a distinct node.
      final v1 = await seedRevision(store, name: 'chained_proc_v1', revision: 1);
      final v2 = await seedRevision(store, name: 'chained_proc_v1', revision: 2);
      final v3 = await seedRevision(store, name: 'chained_proc_v1', revision: 3);

      // superseded_by points old → new (predecessor → the revision replacing it).
      await store.edge(v1, EdgeType.supersededBy, v2,
          scope: const Scope(producer: 'prc:test', idempotencyKey: 'e1'));
      await store.edge(v2, EdgeType.supersededBy, v3,
          scope: const Scope(producer: 'prc:test', idempotencyKey: 'e2'));

      // The walk finds the whole chain from *any* anchor, oldest → newest.
      for (final anchor in <NodeId>[v1, v2, v3]) {
        final chain = await ProcedureRevisionChain(anchor).execute(store);
        expect(chain.map((v) => v.revision).toList(), <int>[1, 2, 3],
            reason: 'oldest → newest from anchor $anchor');
        expect(chain.map((v) => v.name).toSet(), <String>{'chained_proc_v1'});
      }

      // HP6 — revision is structural, never destructive: every superseded
      // predecessor is still a live, readable node after newer revisions exist.
      final older = await store.get(v1);
      final middle = await store.get(v2);
      expect(older, isNotNull, reason: 'the root revision is never deleted');
      expect(middle, isNotNull, reason: 'a superseded middle revision is kept');
      expect(older!.values['revision'], 1);
      expect(middle!.values['revision'], 2);
      expect(ProcedureStatus.fromToken(older.values['status'] as String),
          ProcedureStatus.active,
          reason: 'superseding does not mutate the predecessor');
    });

    test('a procedure with no superseded_by edges is a chain of one', () async {
      final store = await openStore();
      final only =
          await seedRevision(store, name: 'lonely_proc_v1', revision: 1);

      final chain = await ProcedureRevisionChain(only).execute(store);
      expect(chain, hasLength(1));
      expect(chain.single.name, 'lonely_proc_v1');
      expect(chain.single.revision, 1);
    });

    test('an anchor that resolves to no live node yields an empty chain',
        () async {
      final store = await openStore();
      final chain =
          await ProcedureRevisionChain(NodeId.generate()).execute(store);
      expect(chain, isEmpty);
    });
  }, skip: skipNoBinary);
}
