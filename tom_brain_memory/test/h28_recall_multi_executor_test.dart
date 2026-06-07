// H.28 — `RecallExecutor.recallMulti` (multi-seed weighted-RRF fusion).
//
// Plan step #28 (Extension H), *Test* clause:
//   "a seed array fuses with per-seed weights + provenance".
//
// This bench drives the executor directly through its callable seams
// (no SQLite, no vec0) — the same construction `a59_recall_executor_test`
// uses. It locks the multi-seed contract (`memory_specification.md`
// § 6.5):
//
//   * Each seed runs its single mode; the per-seed ranked lists fuse
//     with weighted RRF so a node surfaced by two seeds outranks one
//     surfaced by a single equally-weighted seed.
//   * A seed's `weight` shifts the fused ranking: a higher-weight seed
//     pulls its singly-surfaced node above a lower-weight seed's.
//   * `RecallResult.provenance` is index-aligned with `nodes`: each
//     entry names the surfacing seed indexes (ascending) and carries the
//     fused score.
//   * `MultiRecallCompleted` is emitted once, carrying the per-seed
//     candidate counts and the returned-node provenance — with no
//     substrate / LLM call (the executor never embeds here; seeds carry
//     their own text/ids).
//   * An empty seed array yields an empty result with a present report.

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock, NodeId, Vec;

void main() {
  group('H.28 RecallExecutor.recallMulti', () {
    int seed = 0;
    NodeId mintId() {
      seed += 1;
      final at = DateTime.utc(2026, 1, 1).add(Duration(minutes: seed));
      final randomness =
          List<int>.generate(16, (i) => (seed * 31 + i * 7) & 0x1F);
      return NodeId.generate(at: at, randomness: randomness);
    }

    setUp(() => seed = 0);

    Node makeNode(NodeId id, {String typeName = 'Concept'}) => Node(
          id: id,
          typeName: typeName,
          values: const <String, Object?>{},
          createdAt: DateTime.utc(2026, 1, 1),
        );

    NodeBulkReader makeBulkReader(List<Node> all) => (ids) async {
          final byId = <String, Node>{for (final n in all) n.id.value: n};
          return [for (final id in ids) byId[id.value]]
              .whereType<Node>()
              .toList();
        };

    VectorModeFn noVector() => ({
          required Vec query,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            const <VectorRecallCandidate>[];

    SymbolicModeFn noSymbolic() => ({
          required SymbolicFilter filter,
          int perModeK = 64,
        }) =>
            const <SymbolicRecallCandidate>[];

    GraphWalkModeFn noGraphWalk() => ({
          required Set<NodeId> seeds,
          GraphWalkPolicy policy = GraphWalkPolicy.defaultPolicy,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            const <GraphWalkRecallCandidate>[];

    RecallExecutor newExecutor({
      required Bm25ModeFn bm25,
      required NodeBulkReader nodeReader,
      void Function(MemoryEvent)? eventSink,
    }) =>
        RecallExecutor.fromCallables(
          bm25: bm25,
          vector: noVector(),
          symbolic: noSymbolic(),
          graphWalk: noGraphWalk(),
          nodeReader: nodeReader,
          clock: MutableTestClock(BrainTime.utc(2026, 1, 1)),
          eventSink: eventSink,
        );

    test('seed array fuses with per-seed weights and carries provenance',
        () async {
      final id1 = mintId(); // surfaced by both seeds
      final id2 = mintId(); // surfaced by the heavy seed only
      final id3 = mintId(); // surfaced by the light seed only
      final nodes = [makeNode(id1), makeNode(id2), makeNode(id3)];

      // The single BM25 mode fn is shared across seeds; it varies its
      // output by the seed's `text` so two BM25 seeds return different
      // ranked lists.
      List<Bm25RecallCandidate> bm25({
        required String text,
        Set<String>? typeNames,
        int perModeK = 64,
      }) {
        switch (text) {
          case 'alpha':
            return [
              Bm25RecallCandidate(
                  nodeId: id1, typeName: 'Concept', bm25Score: -2.0),
              Bm25RecallCandidate(
                  nodeId: id2, typeName: 'Concept', bm25Score: -1.0),
            ];
          case 'beta':
            return [
              Bm25RecallCandidate(
                  nodeId: id1, typeName: 'Concept', bm25Score: -2.0),
              Bm25RecallCandidate(
                  nodeId: id3, typeName: 'Concept', bm25Score: -1.0),
            ];
        }
        return const <Bm25RecallCandidate>[];
      }

      final exec = newExecutor(bm25: bm25, nodeReader: makeBulkReader(nodes));

      final result = await exec.recallMulti(MultiRecallQuery(
        seeds: const [
          RecallSeed(mode: RecallMode.bm25, text: 'alpha', weight: 2.0),
          RecallSeed(mode: RecallMode.bm25, text: 'beta', weight: 1.0),
        ],
        k: 10,
        // Pass-through so the fused order is asserted directly, not the
        // MMR re-ordering (covered by a58).
        diversity: const DiversityPolicy(strategy: DiversityStrategy.off),
      ));

      // id1 (both seeds, rank-0 in each) outranks the singly-surfaced
      // nodes; among those, the heavy seed's id2 outranks the light
      // seed's id3.
      expect(result.nodes.map((n) => n.id), [id1, id2, id3]);

      // Provenance is present and index-aligned with the node list.
      final prov = result.provenance;
      expect(prov, isNotNull);
      expect(prov!.length, result.nodes.length);
      for (var i = 0; i < prov.length; i++) {
        expect(prov[i].nodeId, result.nodes[i].id,
            reason: 'provenance must align index-for-index with nodes');
      }
      expect(prov[0].seedIndexes, [0, 1],
          reason: 'id1 is surfaced by both seeds');
      expect(prov[1].seedIndexes, [0],
          reason: 'id2 is surfaced by the heavy seed only');
      expect(prov[2].seedIndexes, [1],
          reason: 'id3 is surfaced by the light seed only');
      // The doubly-surfaced node carries the highest fused score.
      expect(prov[0].fusedScore, greaterThan(prov[1].fusedScore));
      expect(prov[1].fusedScore, greaterThan(prov[2].fusedScore));

      // Report tallies both BM25 seeds (2 + 2 candidates).
      expect(result.report.candidatesPerMode, {RecallMode.bm25: 4});
      expect(result.report.degraded, isFalse);
    });

    test('emits one MultiRecallCompleted with per-seed counts + provenance',
        () async {
      final id1 = mintId();
      final id2 = mintId();
      final nodes = [makeNode(id1), makeNode(id2)];

      List<Bm25RecallCandidate> bm25({
        required String text,
        Set<String>? typeNames,
        int perModeK = 64,
      }) =>
          [
            Bm25RecallCandidate(
                nodeId: id1, typeName: 'Concept', bm25Score: -2.0),
            Bm25RecallCandidate(
                nodeId: id2, typeName: 'Concept', bm25Score: -1.0),
          ];

      final events = <MemoryEvent>[];
      final exec = newExecutor(
        bm25: bm25,
        nodeReader: makeBulkReader(nodes),
        eventSink: events.add,
      );

      await exec.recallMulti(const MultiRecallQuery(
        seeds: [RecallSeed(mode: RecallMode.bm25, text: 'x')],
        k: 10,
        diversity: DiversityPolicy(strategy: DiversityStrategy.off),
      ));

      final completed = events.whereType<MultiRecallCompleted>().toList();
      expect(completed, hasLength(1));
      expect(completed.single.seedCandidateCounts, [2]);
      expect(completed.single.returnedCount, 2);
      expect(completed.single.provenance, hasLength(2));
    });

    test('empty seed array yields an empty result with a present report',
        () async {
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            const <Bm25RecallCandidate>[],
        nodeReader: makeBulkReader(const []),
      );

      final result =
          await exec.recallMulti(const MultiRecallQuery(seeds: []));
      expect(result.nodes, isEmpty);
      expect(result.provenance, isEmpty);
      expect(result.report.candidatesPerMode, isEmpty);
      expect(result.report.degraded, isFalse);
    });
  });
}
