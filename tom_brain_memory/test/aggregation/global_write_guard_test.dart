// GA-8 live-path guard — the reserved `global` profile is writable only by the
// `aggregator` agent (memory_specification.md § 2.6, GA-8). I-3 Phase 2 Done-when.
//
// The structural guarantee: a node / edge write that lands on a store bound to
// the reserved `global` profile is rejected with `GlobalProfileWriteForbidden`
// unless it carries `Scope.agentName == 'aggregator'`. Because a d4rt procedure
// cannot set `Scope.agentName`, this makes it impossible for an ordinary
// answer/dream write — even one that happens to run with `global` bound — to
// mutate the global tier. Only the in-engine aggregation pass (which issues its
// writes under the registered `aggregator` agent) reaches `global`.
//
// Real-store, vec0-binary-gated `skip` (same gate as
// `profile_aggregator_test.dart`): the guard sits on the concrete
// `SqliteTomBrainMemory` write path, so it can only be exercised against a real
// open store.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeType,
        MemoryConfig,
        NodeDraft,
        NodeId,
        Scope,
        Vec,
        reservedGlobalProfile;

const _dims = 768;

Vec _v({required int seed}) {
  final values = Float32List(_dims);
  for (var i = 0; i < _dims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

NodeDraft _concept(String name, {required int seed}) => NodeDraft(
      typeName: 'Concept',
      values: <String, Object?>{'name': name, 'description': 'd'},
      embedding: _v(seed: seed),
    );

String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate = Directory('${dir.path}${Platform.pathSeparator}'
        'tom_binaries${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  group('GA-8 global-profile write guard — real SqliteTomBrainMemory', () {
    final vecRoot = _findSqliteVecRoot();
    final resolver = SqliteVecBinaryResolver();
    String? resolvedPath;
    if (vecRoot != null && resolver.isSupported) {
      final path = resolver.resolve(vecRoot);
      if (File(path).existsSync()) resolvedPath = path;
    }
    final skipNoBinary = resolvedPath == null
        ? 'No packaged vec0 binary for this platform under '
            'tom_binaries/sqlite_vec.'
        : null;

    test(
        'a non-aggregator node write against the global profile is rejected; '
        'an edge write too', () async {
      final root =
          Directory.systemTemp.createTempSync('tbm_ga8_').path;
      addTearDown(() {
        final dir = Directory(root);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final store = SqliteTomBrainMemory();
      // Bind the store to the reserved `global` profile directly — the live
      // write path is what GA-8 guards, regardless of how `global` got bound.
      await store.open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!)
          .withProfile(reservedGlobalProfile));
      addTearDown(store.close);

      // An anonymous write (no agentName) — the shape a procedure or channel
      // would ever produce — is refused before any row lands.
      expect(
        () => store.persist(_concept('k', seed: 1),
            scope: const Scope(producer: 'answer_v1')),
        throwsA(isA<GlobalProfileWriteForbidden>()),
      );

      // A write stamped with a *different* agent identity is also refused —
      // only `aggregator` may write `global`.
      expect(
        () => store.persist(_concept('k', seed: 1),
            scope: const Scope(producer: 'x', agentName: 'extractor')),
        throwsA(isA<GlobalProfileWriteForbidden>()),
      );

      // The edge path carries the same guard. The endpoint ids are
      // syntactically valid (the guard, not id-parsing, must be what rejects).
      expect(
        () => store.edge(
          NodeId.generate(),
          EdgeType.fromWireName('derived_from'),
          NodeId.generate(),
          scope: const Scope(producer: 'answer_v1'),
        ),
        throwsA(isA<GlobalProfileWriteForbidden>()),
      );
    }, skip: skipNoBinary);

    test('a non-global profile is unaffected by the guard', () async {
      final root =
          Directory.systemTemp.createTempSync('tbm_ga8_ok_').path;
      addTearDown(() {
        final dir = Directory(root);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final store = SqliteTomBrainMemory();
      await store.open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!)
          .withProfile('work'));
      addTearDown(store.close);

      // An ordinary anonymous write into a normal profile succeeds — the guard
      // only fires on the reserved `global` profile.
      final id = await store.persist(_concept('kubernetes', seed: 1),
          scope: const Scope(producer: 'answer_v1'));
      expect(id.value, isNotEmpty);
    }, skip: skipNoBinary);
  });
}
