// H.28 — `classify(target: concept)` over the concrete store.
//
// Plan step #28 (Extension H), *Test* clause:
//   "classify(target: concept) returns the nearest Concept centroid".
//
// Spec memory § 7.1 (per-`Concept` centroids): a Concept centroid is
// keyed by the concept *name* (not the `Concept` node type), its
// example count is the live count of `Concept` rows feeding the
// cold-start gate, and its embedding model is the one the `Concept`
// node type declares. `updateCentroid(name, vec, target: concept)`
// writes such a centroid through the same surface a `dream_recentroid_v1`
// concept pass would use; `classify(vec, target: concept)` reads it back
// and returns the nearest concept name (namespace stripped).
//
// Like p2_16 / p2_17 this case needs the packaged vec0 binary (open()
// refuses to boot without it — P1.1) and is skipped, not failed, when
// the running platform has no binary under tom_binaries/sqlite_vec.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ClassificationDecision, ClassificationTarget, NodeDraft, NodeId, Vec;

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. Mirrors p2_16 / p2_17 `_v768`.
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
    final root = Directory.systemTemp.createTempSync('tbm_h28_concept_');
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

  /// Persists a `Concept` carrying [name] / `_v768(seed:)`.
  Future<NodeId> persistConcept(
    SqliteTomBrainMemory store, {
    required String name,
    required int seed,
    required String key,
  }) {
    return store.persist(
      NodeDraft(
        typeName: 'Concept',
        values: <String, Object?>{
          'name': name,
          'description': 'concept $name',
        },
        embedding: _v768(seed: seed),
      ),
      scope: Scope(producer: 'h28:test', idempotencyKey: key),
    );
  }

  group('SqliteTomBrainMemory — classify(target: concept) (needs vec0)', () {
    test('returns the nearest Concept centroid by name', () async {
      final store = await openStore();
      // Cold-start gate is 8 examples and counts live `Concept` rows
      // (memory § 7.1, reconciled at H.28): persist 8 Concept nodes so
      // the per-Concept centroid clears the gate once written.
      for (var i = 0; i < 8; i++) {
        await persistConcept(store, name: 'concept_$i', seed: 7, key: 'c$i');
      }

      // Write a per-Concept centroid keyed by the concept *name*.
      await store.updateCentroid(
        'machine_learning',
        _v768(seed: 7),
        target: ClassificationTarget.concept,
      );

      final result = await store.classify(
        _v768(seed: 7),
        target: ClassificationTarget.concept,
      );

      // The nearest centroid is returned with its namespace stripped:
      // the bare concept name, not `Concept:machine_learning`.
      expect(result.bestMatch, equals('machine_learning'));
      expect(result.decision, equals(ClassificationDecision.confident));
    });

    test('concept centroids do not leak into the nodeType target',
        () async {
      final store = await openStore();
      for (var i = 0; i < 8; i++) {
        await persistConcept(store, name: 'concept_$i', seed: 3, key: 'n$i');
      }
      await store.updateCentroid(
        'robotics',
        _v768(seed: 3),
        target: ClassificationTarget.concept,
      );

      // Classifying against the default (nodeType) target must not see
      // the Concept-keyed centroid — the namespaces are disjoint.
      final asNodeType = await store.classify(_v768(seed: 3));
      expect(asNodeType.bestMatch, isNot(equals('robotics')));
    });
  }, skip: skipNoBinary);
}
