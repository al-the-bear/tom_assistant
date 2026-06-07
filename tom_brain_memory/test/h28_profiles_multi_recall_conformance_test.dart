// H.28 — § 17.4 profiles + multi-recall conformance (concrete store).
//
// Plan step #28 (Extension H), *Verify* clause:
//   "analyze + § 17.4 profiles+multi-recall conformance test green".
//
// memory_specification.md § 17.4 spells the conformance scenario out:
//
//   createProfile → seedProfile → recallMulti → dropProfile → recreate →
//   recallMulti returns identical results on the recreated profile
//   (reset-to-zero); two profiles queried concurrently never cross-talk;
//   recallMulti over a seed array fuses per-seed lists with per-seed
//   weights and emits provenance; classify(target: concept) returns the
//   nearest Concept centroid; all of the above run with NO substrate/LLM
//   instantiation.
//
// Unlike the executor-level h28 (`h28_recall_multi_executor_test`, which
// drives the callable seams with no SQLite) and the focused concept
// classify (`h28_concept_classify_test`), this suite drives the *real*
// `SqliteTomBrainMemory` end to end through `recallMulti` and the
// profile registry — the integration proof § 17.4 asks for.
//
// The "no substrate / LLM" facet is structural: `SqliteTomBrainMemory`
// never constructs a substrate client. The seeds carry their own text
// and are matched through the on-disk FTS / vec0 indexes, not embedded
// by an LLM. There is nothing to stub out — the absence is by
// construction.
//
// Like p2_16 / h27 these recall scenarios need the packaged vec0 binary
// (open() refuses to boot without it — P1.1) and are skipped, not
// failed, when the running platform has no binary under
// tom_binaries/sqlite_vec.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        ClassificationDecision,
        ClassificationTarget,
        DiversityPolicy,
        DiversityStrategy,
        MultiRecallQuery,
        NodeDraft,
        RecallMode,
        RecallSeed,
        Scope,
        Vec;

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector keyed by [seed] (mirrors p2_16 `_v768`).
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Builds an Event draft carrying [text] as its `summary` and a [seed]-keyed
/// embedding. A fresh draft per call so a re-seed after `dropProfile` mints
/// brand-new nodes (reset-to-zero).
NodeDraft _eventDraft(String text, {required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': text,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-07T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 / h27.
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

/// A two-BM25-seed multi-recall query, the heavy seed weighted 2×. Both
/// seeds are pass-through (no MMR re-order) so the fused order is asserted
/// directly. The seeds carry their own text — no LLM embeds them.
MultiRecallQuery _twoSeedQuery() => const MultiRecallQuery(
      seeds: [
        RecallSeed(mode: RecallMode.bm25, text: 'sharedword', weight: 2.0),
        RecallSeed(mode: RecallMode.bm25, text: 'onlyword', weight: 1.0),
      ],
      k: 20,
      diversity: DiversityPolicy(strategy: DiversityStrategy.off),
    );

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

  String freshRoot() {
    final root = Directory.systemTemp.createTempSync('tbm_h28_conf_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return root.path;
  }

  Future<SqliteTomBrainMemory> openParent(String root) async {
    final store = SqliteTomBrainMemory();
    addTearDown(store.close);
    await store
        .open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!));
    return store;
  }

  Future<SqliteTomBrainMemory> openProfile(String root, String profile) async {
    final store = SqliteTomBrainMemory();
    addTearDown(store.close);
    await store.open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!)
        .withProfile(profile));
    return store;
  }

  /// Opens [profile], runs `_twoSeedQuery()`, returns the matched node
  /// summaries (sorted for order-independent comparison), and closes.
  Future<List<String>> multiRecallSummaries(String root, String profile) async {
    final store = await openProfile(root, profile);
    final result = await store.recallMulti(_twoSeedQuery());
    final summaries = result.nodes
        .map((n) => n.values['summary'] as String)
        .toList()
      ..sort();
    await store.close();
    return summaries;
  }

  const scope = Scope(producer: 'h28:conformance');

  // Three Events: one matched by the heavy seed's term, two matched by the
  // light seed's term. The drafts are rebuilt per call so a re-seed mints
  // brand-new nodes.
  List<NodeDraft> seedDrafts() => [
        _eventDraft('alpha sharedword zeta', seed: 1),
        _eventDraft('beta onlyword one', seed: 2),
        _eventDraft('gamma onlyword two', seed: 3),
      ];

  group('H.28 § 17.4 — profiles + multi-recall conformance (needs vec0)', () {
    test('createProfile → seed → recallMulti → drop → recreate → recallMulti '
        'is identical (reset-to-zero)', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      await reg.createProfile('eval_a');
      await reg.seedProfile('eval_a', seedDrafts(), scope: scope);
      final first = await multiRecallSummaries(root, 'eval_a');
      expect(first, isNotEmpty);

      await reg.dropProfile('eval_a');
      expect(await reg.exists('eval_a'), isFalse);

      await reg.createProfile('eval_a');
      await reg.seedProfile('eval_a', seedDrafts(), scope: scope);
      final second = await multiRecallSummaries(root, 'eval_a');

      expect(second, equals(first),
          reason: 'a recreated profile is reset-to-zero and reproduces the '
              'same multi-recall content');
    }, skip: skipNoBinary);

    test('two profiles recalled concurrently never cross-talk', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      await reg.createProfile('p1');
      await reg.createProfile('p2');
      await reg.seedProfile(
        'p1',
        [_eventDraft('p1 sharedword distinct', seed: 10)],
        scope: scope,
      );
      await reg.seedProfile(
        'p2',
        [_eventDraft('p2 sharedword distinct', seed: 20)],
        scope: scope,
      );

      final results = await Future.wait(<Future<List<String>>>[
        multiRecallSummaries(root, 'p1'),
        multiRecallSummaries(root, 'p2'),
      ]);

      expect(results[0], contains('p1 sharedword distinct'));
      expect(results[0], isNot(contains('p2 sharedword distinct')));
      expect(results[1], contains('p2 sharedword distinct'));
      expect(results[1], isNot(contains('p1 sharedword distinct')));
    }, skip: skipNoBinary);

    test('recallMulti fuses per-seed lists with per-seed weights and emits '
        'provenance', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      await reg.createProfile('fuse');
      await reg.seedProfile('fuse', seedDrafts(), scope: scope);

      final store = await openProfile(root, 'fuse');
      final result = await store.recallMulti(_twoSeedQuery());

      // All three seeded nodes surface across the two seeds.
      expect(result.nodes, hasLength(3));

      // Provenance is present and index-aligned with the node list.
      final prov = result.provenance;
      expect(prov, isNotNull);
      expect(prov!.length, result.nodes.length);
      for (var i = 0; i < prov.length; i++) {
        expect(prov[i].nodeId, result.nodes[i].id,
            reason: 'provenance must align index-for-index with nodes');
      }

      // Every entry names at least one surfacing seed; the heavy-seed
      // node (matched by 'sharedword', seed 0) is the top-ranked node and
      // carries the highest fused score.
      for (final entry in prov) {
        expect(entry.seedIndexes, isNotEmpty);
      }
      final topSummary = result.nodes.first.values['summary'] as String;
      expect(topSummary, equals('alpha sharedword zeta'),
          reason: 'the heavy-weighted seed pulls its node to the top');
      expect(prov.first.seedIndexes, contains(0));
      // Fused scores are non-increasing down the ranked list.
      for (var i = 1; i < prov.length; i++) {
        expect(prov[i - 1].fusedScore,
            greaterThanOrEqualTo(prov[i].fusedScore));
      }
    }, skip: skipNoBinary);

    test('classify(target: concept) returns the nearest Concept centroid',
        () async {
      final root = freshRoot();
      final store = await openParent(root);

      // Cold-start gate is 8 examples and counts live Concept rows.
      for (var i = 0; i < 8; i++) {
        await store.persist(
          NodeDraft(
            typeName: 'Concept',
            values: <String, Object?>{
              'name': 'concept_$i',
              'description': 'concept $i',
            },
            embedding: _v768(seed: 5),
          ),
          scope: Scope(producer: 'h28:conformance', idempotencyKey: 'k$i'),
        );
      }
      await store.updateCentroid(
        'deep_learning',
        _v768(seed: 5),
        target: ClassificationTarget.concept,
      );

      final result = await store.classify(
        _v768(seed: 5),
        target: ClassificationTarget.concept,
      );
      expect(result.bestMatch, equals('deep_learning'));
      expect(result.decision, equals(ClassificationDecision.confident));
    }, skip: skipNoBinary);
  });
}
