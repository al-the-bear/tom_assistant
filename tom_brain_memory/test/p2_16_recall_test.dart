// P2.16 — recall() over the concrete store: four modes + fusion.
//
// prototype_implementation_plan_2.md #16:
//   "Memory: implement `recall()` (four modes + fusion).
//    `recall(RecallQuery)` over `RecallExecutor` combining BM25, vector,
//    graph-walk, symbolic with RRF + MMR; honour the optional
//    caller-supplied `reRank` LLM hook (memory never instantiates an LLM
//    — it invokes the supplied callback). Test: each mode independently;
//    fused ranking deterministic on a fixture; re-rank hook invoked and
//    reorders. Verify: a vector recall returns the nearest persisted node
//    on a real embedding."
//
// open() now threads a shared Fts5Catalog into the registry (so the
// per-type FTS5 virtual tables exist) and an Fts5Writer into the
// persister (so persisted nodes land FTS rows), then wires a
// RecallExecutor over the four mode executors. recall() delegates to it.
//
// Like p2_13 / p2_14 / p2_15 these cases need the packaged vec0 binary
// (open() refuses to boot without it — P1.1) and are skipped, not
// failed, when the running platform has no binary under
// tom_binaries/sqlite_vec/<platform>/.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, NodeId, RecallMode, RecallQuery, SymbolicFilter, Vec;

/// The bootstrap embedding model (bootstrap_node_types.yaml
/// `embedding_defaults`). Event embeds under it. Mirrors p2_15.
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. Mirrors a39/a60/p2_15 `_v768`.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec` by walking up from the
/// test runner's CWD. Mirrors p2_13 / p2_14 / p2_15.
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

  /// Opens a fresh store rooted in a unique temp dir, registers teardown
  /// for both the store and the directory, and returns the open store.
  Future<SqliteTomBrainMemory> openStore() async {
    final root = Directory.systemTemp.createTempSync('tbm_recall_');
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

  /// Persists an Event whose `summary` carries [text] and whose
  /// embedding is `_v768(seed:)`. Returns the assigned node id.
  Future<NodeId> persistEvent(
    SqliteTomBrainMemory store, {
    required String text,
    required int seed,
    required String key,
  }) {
    return store.persist(
      NodeDraft(
        typeName: 'Event',
        values: <String, Object?>{
          'summary': text,
          'payload': const <String, Object?>{},
          'occurred_at': '2026-06-05T10:00:00.000Z',
        },
        embedding: _v768(seed: seed),
      ),
      scope: Scope(producer: 'p2.16:test', idempotencyKey: key),
    );
  }

  group('SqliteTomBrainMemory — recall four modes (needs vec0)', () {
    test('BM25 mode returns the matching persisted node', () async {
      final store = await openStore();
      final hit = await persistEvent(store,
          text: 'alpha bravo charlie distinctive', seed: 1, key: 'ev-hit');
      await persistEvent(store,
          text: 'completely unrelated content', seed: 2, key: 'ev-miss');

      final result = await store.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.bm25},
        text: 'distinctive',
        k: 10,
      ));

      expect(result.nodes, isNotEmpty);
      expect(result.nodes.first.id, equals(hit));
      expect(result.report.candidatesPerMode[RecallMode.bm25], equals(1));
      expect(result.report.degraded, isFalse);
    });

    test('vector mode returns the nearest persisted node on a real '
        'embedding', () async {
      final store = await openStore();
      final exact =
          await persistEvent(store, text: 'exact match', seed: 7, key: 'ev-exact');
      await persistEvent(store, text: 'far away', seed: 800, key: 'ev-far');

      final result = await store.recall(RecallQuery(
        modes: const <RecallMode>{RecallMode.vector},
        embedding: _v768(seed: 7),
        k: 10,
      ));

      expect(result.nodes, isNotEmpty);
      expect(result.nodes.first.id, equals(exact),
          reason: 'nearest vector is the node persisted with that embedding');
      expect(result.report.degraded, isFalse);
    });

    test('symbolic mode returns only the type-matching persisted node',
        () async {
      final store = await openStore();
      final conclusionId = await store.persist(
        NodeDraft(
          typeName: 'Conclusion',
          values: const <String, Object?>{
            'statement': 'persistence works',
            'rationale': 'the row round-trips',
          },
          embedding: _v768(seed: 5),
        ),
        scope: const Scope(producer: 'p2.16:test', idempotencyKey: 'co-1'),
      );
      await persistEvent(store, text: 'an event', seed: 9, key: 'ev-1');

      final result = await store.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.symbolic},
        filter: SymbolicFilter(typeNames: <String>{'Conclusion'}),
        k: 10,
      ));

      final ids = result.nodes.map((n) => n.id).toSet();
      expect(ids, contains(conclusionId));
      expect(result.nodes.every((n) => n.typeName == 'Conclusion'), isTrue);
      expect(result.report.degraded, isFalse);
    });

    test('graph-walk mode runs without edges and yields no candidates '
        '(not degraded)', () async {
      final store = await openStore();
      final seed = await persistEvent(store,
          text: 'lonely node', seed: 3, key: 'ev-seed');

      final result = await store.recall(RecallQuery(
        modes: const <RecallMode>{RecallMode.graphWalk},
        seeds: <NodeId>{seed},
        k: 10,
      ));

      // No edges are wired yet (#17), so a walk from the seed reaches
      // nothing — and the seed itself is excluded from graph-walk
      // results. A mode that produced no opinion is not degraded.
      expect(result.nodes, isEmpty);
      expect(result.report.candidatesPerMode[RecallMode.graphWalk], equals(0));
      expect(result.report.degraded, isFalse);
    });

    test('fused ranking is deterministic across repeated recalls on a '
        'fixture', () async {
      final store = await openStore();
      await persistEvent(store,
          text: 'stableword anchor primary', seed: 11, key: 'ev-a');
      await persistEvent(store, text: 'stableword secondary', seed: 12, key: 'ev-b');
      await persistEvent(store, text: 'unrelated noise', seed: 13, key: 'ev-c');

      final query = RecallQuery(
        modes: const <RecallMode>{RecallMode.bm25, RecallMode.vector},
        text: 'stableword',
        embedding: _v768(seed: 11),
        k: 10,
      );
      final first = await store.recall(query);
      final second = await store.recall(query);
      final third = await store.recall(query);

      final firstIds = first.nodes.map((n) => n.id.value).toList();
      expect(second.nodes.map((n) => n.id.value).toList(), equals(firstIds));
      expect(third.nodes.map((n) => n.id.value).toList(), equals(firstIds));
      expect(firstIds, isNotEmpty);
    });

    test('the caller-supplied re-rank hook is invoked and reorders the '
        'result', () async {
      final store = await openStore();
      await persistEvent(store,
          text: 'rankword anchor first', seed: 21, key: 'ev-1');
      await persistEvent(store,
          text: 'rankword anchor second', seed: 22, key: 'ev-2');

      // Baseline order without a hook.
      final baseline = await store.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.bm25},
        text: 'rankword',
        k: 10,
      ));
      expect(baseline.nodes.length, greaterThanOrEqualTo(2));
      expect(baseline.report.reRankInvoked, isFalse);
      final baselineIds = baseline.nodes.map((n) => n.id).toList();

      // A hook that reverses the materialised order. Memory never makes
      // an LLM — it invokes whatever callback the caller supplied.
      var hookCalls = 0;
      final reranked = await store.recall(RecallQuery(
        modes: const <RecallMode>{RecallMode.bm25},
        text: 'rankword',
        k: 10,
        reRank: (candidates) async {
          hookCalls += 1;
          return candidates.reversed.map((n) => n.id).toList();
        },
      ));

      expect(hookCalls, equals(1));
      expect(reranked.report.reRankInvoked, isTrue);
      expect(reranked.nodes.map((n) => n.id).toList(),
          equals(baselineIds.reversed.toList()));
    });
  }, skip: skipNoBinary);
}
