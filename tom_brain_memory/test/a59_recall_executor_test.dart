// A.59 — RecallExecutor (pipeline orchestrator, integration-style with
// callable seams).
//
// Plan step A.59:
//   "Implement `RecallReport` and wire it into the `RecallResult`."
//
// Per the executor's header doc this is the full recall-pipeline
// orchestrator (memory_specification.md §§ 6.1–6.4): four-mode dispatch
// → RRF fusion → MMR diversification → optional re-rank hook →
// materialised node list → `RecallReport`.
//
// Coverage map (one `test(...)` per row):
//
//   Surface
//   -------
//   * Empty `query.modes` → empty nodes, report with empty
//     candidatesPerMode, no degraded flag, k=anything.
//   * Single-mode (BM25) returns the executor's ranked ids,
//     materialised via the bulk reader, in fused order.
//   * Two-mode (BM25 + symbolic) fuses with RRF and reports the
//     per-mode candidate counts correctly.
//   * `query.k` truncates the final nodes list.
//
//   Per-mode dispatch
//   -----------------
//   * BM25 without text → 0 candidates, not degraded.
//   * Symbolic without filter → 0 candidates, not degraded.
//   * Vector without embedding → 0 candidates, degraded = true.
//   * Vector with null executor (boot-degraded) → 0 candidates,
//     degraded = true.
//   * graphWalk without seeds → 0 candidates, not degraded.
//   * graphWalk with seeds → ranked via the executor, not degraded.
//   * graphWalk executor throws → 0 candidates, degraded = true.
//   * Mode executor throws → 0 candidates, degraded = true.
//
//   Fusion gates
//   ------------
//   * `FusionStrategy.weighted` throws `UnimplementedError`.
//   * `FusionStrategy.rrf` runs and the resulting ranks reflect RRF
//     math (verifiable via `RrfFusedCandidate` ordering through the
//     pipeline).
//
//   Diversity gates
//   ---------------
//   * `DiversityStrategy.off` passes the fused list through (truncated
//     to k).
//   * `DiversityStrategy.mmr` reorders the fused list by MMR with the
//     BM25-derived similarity fallback.
//
//   Re-rank hook
//   ------------
//   * `reRank == null` → `report.reRankInvoked == false`.
//   * `reRank` returning the same list in a different order →
//     `report.reRankInvoked == true`, nodes reordered.
//   * `reRank` returning a subset → executor appends the missing
//     originals at end (no silent delete).
//   * `reRank` returning unknown ids → unknown ids dropped silently;
//     remaining originals appended at end.
//
//   Budget
//   ------
//   * `wallClockMs == 0` disables the budget check.
//   * `wallClockMs` exceeded between modes → short-circuit, degraded
//     = true.
//
//   Report fields
//   -------------
//   * `elapsedMs` matches the clock delta (MutableTestClock).
//   * `embeddingsCallouts` is always 0 at A.59.
//   * `diversityLambda` populated only when strategy is MMR.
//   * `candidatesPerMode` is unmodifiable.
//
//   Materialisation
//   ---------------
//   * Bulk reader receives the post-MMR id list in order.
//   * Bulk reader returning a shorter list (missing ids) → final nodes
//     reflect the reader's output exactly.

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock, NodeId, Vec;

void main() {
  group('A.59 RecallExecutor', () {
    // ─── Deterministic NodeId mint ──────────────────────────────────
    int seed = 0;
    NodeId mintId() {
      seed += 1;
      final at = DateTime.utc(2026, 1, 1).add(Duration(minutes: seed));
      final randomness =
          List<int>.generate(16, (i) => (seed * 31 + i * 7) & 0x1F);
      return NodeId.generate(at: at, randomness: randomness);
    }

    setUp(() {
      seed = 0;
    });

    // ─── Helpers ───────────────────────────────────────────────────
    Node makeNode(NodeId id, {String typeName = 'Concept'}) => Node(
          id: id,
          typeName: typeName,
          values: const <String, Object?>{},
          createdAt: DateTime.utc(2026, 1, 1),
        );

    /// Builds a bulk reader from a list of nodes — returns them in the
    /// order of the requested ids, eliding unknowns.
    NodeBulkReader makeBulkReader(List<Node> all) =>
        (ids) async {
          final byId = <String, Node>{for (final n in all) n.id.value: n};
          return [for (final id in ids) byId[id.value]].whereType<Node>().toList();
        };

    // Default mode executors — all empty, all "fine". Tests override
    // the ones they care about.
    Bm25ModeFn noBm25() => ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            const <Bm25RecallCandidate>[];

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
      Bm25ModeFn? bm25,
      VectorModeFn? vector,
      bool vectorNullExecutor = false,
      SymbolicModeFn? symbolic,
      GraphWalkModeFn? graphWalk,
      required NodeBulkReader nodeReader,
      MutableTestClock? clock,
    }) =>
        RecallExecutor.fromCallables(
          bm25: bm25 ?? noBm25(),
          vector: vectorNullExecutor ? null : (vector ?? noVector()),
          symbolic: symbolic ?? noSymbolic(),
          graphWalk: graphWalk ?? noGraphWalk(),
          nodeReader: nodeReader,
          clock: clock ?? MutableTestClock(BrainTime.utc(2026, 1, 1)),
        );

    // ─── Surface ───────────────────────────────────────────────────

    test('empty modes set returns empty nodes + empty per-mode map',
        () async {
      final exec = newExecutor(nodeReader: makeBulkReader(const []));
      final result = await exec.recall(RecallQuery(modes: const {}, k: 5));
      expect(result.nodes, isEmpty);
      expect(result.report.candidatesPerMode, isEmpty);
      expect(result.report.degraded, isFalse);
      expect(result.report.reRankInvoked, isFalse);
      expect(result.report.embeddingsCallouts, 0);
    });

    test('single-mode BM25 returns ranked + materialised nodes', () async {
      final id1 = mintId();
      final id2 = mintId();
      final id3 = mintId();
      final nodes = [makeNode(id1), makeNode(id2), makeNode(id3)];
      List<Bm25RecallCandidate> fakeBm25({
        required String text,
        Set<String>? typeNames,
        int perModeK = 64,
      }) =>
          [
            Bm25RecallCandidate(
                nodeId: id1, typeName: 'Concept', bm25Score: -3.0),
            Bm25RecallCandidate(
                nodeId: id2, typeName: 'Concept', bm25Score: -2.0),
            Bm25RecallCandidate(
                nodeId: id3, typeName: 'Concept', bm25Score: -1.0),
          ];

      final exec = newExecutor(
        bm25: fakeBm25,
        nodeReader: makeBulkReader(nodes),
      );
      // DiversityStrategy.off keeps fused order — the point of this
      // test is the pipeline shape (dispatch → fuse → materialise),
      // not MMR's reordering math, which a58 covers separately.
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'cat',
        k: 5,
        diversity: const DiversityPolicy(strategy: DiversityStrategy.off),
      ));
      expect(result.nodes.map((n) => n.id), [id1, id2, id3]);
      expect(result.report.candidatesPerMode, {RecallMode.bm25: 3});
      expect(result.report.degraded, isFalse);
    });

    test('two-mode (bm25 + symbolic) fuses with RRF and tracks counts',
        () async {
      final id1 = mintId();
      final id2 = mintId();
      final id3 = mintId();
      final nodes = [makeNode(id1), makeNode(id2), makeNode(id3)];

      List<Bm25RecallCandidate> bm25({
        required String text,
        Set<String>? typeNames,
        int perModeK = 64,
      }) =>
          [
            Bm25RecallCandidate(
                nodeId: id1, typeName: 'Concept', bm25Score: -3.0),
            Bm25RecallCandidate(
                nodeId: id2, typeName: 'Concept', bm25Score: -2.0),
          ];

      List<SymbolicRecallCandidate> symbolic({
        required SymbolicFilter filter,
        int perModeK = 64,
      }) =>
          [
            SymbolicRecallCandidate(
                nodeId: id3, typeName: 'Concept', createdAtMs: 0),
            SymbolicRecallCandidate(
                nodeId: id1, typeName: 'Concept', createdAtMs: 0),
          ];

      final exec = newExecutor(
        bm25: bm25,
        symbolic: symbolic,
        nodeReader: makeBulkReader(nodes),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25, RecallMode.symbolic},
        text: 'cat',
        filter: const SymbolicFilter(typeNames: {'Concept'}),
        k: 10,
      ));
      expect(result.report.candidatesPerMode,
          {RecallMode.bm25: 2, RecallMode.symbolic: 2});
      // id1 appears in both lists → highest RRF score → must be first
      // (relevance dominates with default lambda=0.7).
      expect(result.nodes.first.id, id1);
      expect(result.report.degraded, isFalse);
    });

    test('k truncates the final node list', () async {
      final ids = List.generate(5, (_) => mintId());
      final nodes = ids.map(makeNode).toList();
      List<Bm25RecallCandidate> bm25({
        required String text,
        Set<String>? typeNames,
        int perModeK = 64,
      }) =>
          [
            for (var i = 0; i < ids.length; i++)
              Bm25RecallCandidate(
                  nodeId: ids[i],
                  typeName: 'Concept',
                  bm25Score: -(ids.length - i).toDouble()),
          ];
      final exec = newExecutor(
        bm25: bm25,
        nodeReader: makeBulkReader(nodes),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        k: 2,
      ));
      expect(result.nodes.length, 2);
    });

    // ─── Per-mode dispatch ─────────────────────────────────────────

    test('BM25 without text yields 0 candidates, not degraded', () async {
      var called = false;
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) {
          called = true;
          return const [];
        },
        nodeReader: makeBulkReader(const []),
      );
      final result = await exec.recall(
        RecallQuery(modes: const {RecallMode.bm25}, k: 5),
      );
      expect(called, isFalse);
      expect(result.report.candidatesPerMode, {RecallMode.bm25: 0});
      expect(result.report.degraded, isFalse);
    });

    test('symbolic without filter yields 0 candidates, not degraded',
        () async {
      var called = false;
      final exec = newExecutor(
        symbolic: ({
          required SymbolicFilter filter,
          int perModeK = 64,
        }) {
          called = true;
          return const [];
        },
        nodeReader: makeBulkReader(const []),
      );
      final result = await exec.recall(
        RecallQuery(modes: const {RecallMode.symbolic}, k: 5),
      );
      expect(called, isFalse);
      expect(result.report.candidatesPerMode, {RecallMode.symbolic: 0});
      expect(result.report.degraded, isFalse);
    });

    test('vector without embedding → degraded', () async {
      var called = false;
      final exec = newExecutor(
        vector: ({
          required Vec query,
          Set<String>? typeNames,
          int perModeK = 64,
        }) {
          called = true;
          return const [];
        },
        nodeReader: makeBulkReader(const []),
      );
      final result = await exec.recall(
        RecallQuery(modes: const {RecallMode.vector}, k: 5),
      );
      expect(called, isFalse);
      expect(result.report.candidatesPerMode, {RecallMode.vector: 0});
      expect(result.report.degraded, isTrue);
    });

    test('vector with null executor (boot-degraded) → degraded', () async {
      final exec = newExecutor(
        vectorNullExecutor: true,
        nodeReader: makeBulkReader(const []),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.vector},
        embedding: Vec.fromList(const [1.0, 0.0]),
        k: 5,
      ));
      expect(result.report.candidatesPerMode, {RecallMode.vector: 0});
      expect(result.report.degraded, isTrue);
    });

    test('graphWalk without seeds yields 0 candidates, not degraded',
        () async {
      var called = false;
      final exec = newExecutor(
        graphWalk: ({
          required Set<NodeId> seeds,
          GraphWalkPolicy policy = GraphWalkPolicy.defaultPolicy,
          Set<String>? typeNames,
          int perModeK = 64,
        }) {
          called = true;
          return const [];
        },
        nodeReader: makeBulkReader(const []),
      );
      final result = await exec.recall(
        RecallQuery(modes: const {RecallMode.graphWalk}, k: 5),
      );
      expect(called, isFalse);
      expect(result.report.candidatesPerMode, {RecallMode.graphWalk: 0});
      expect(result.report.degraded, isFalse);
    });

    test('graphWalk with seeds dispatches to the executor', () async {
      final seed = mintId();
      final neighbour = mintId();
      List<GraphWalkRecallCandidate> graphWalk({
        required Set<NodeId> seeds,
        GraphWalkPolicy policy = GraphWalkPolicy.defaultPolicy,
        Set<String>? typeNames,
        int perModeK = 64,
      }) =>
          [
            GraphWalkRecallCandidate(
                nodeId: neighbour, typeName: 'Concept', score: 0.5),
          ];
      final exec = newExecutor(
        graphWalk: graphWalk,
        nodeReader: makeBulkReader([makeNode(neighbour)]),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.graphWalk},
        seeds: {seed},
        k: 5,
      ));
      expect(result.nodes.map((n) => n.id), [neighbour]);
      expect(result.report.candidatesPerMode, {RecallMode.graphWalk: 1});
      expect(result.report.degraded, isFalse);
    });

    test('graphWalk executor throwing → degraded, count = 0', () async {
      final seed = mintId();
      final exec = newExecutor(
        graphWalk: ({
          required Set<NodeId> seeds,
          GraphWalkPolicy policy = GraphWalkPolicy.defaultPolicy,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            throw StateError('boom'),
        nodeReader: makeBulkReader(const []),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.graphWalk},
        seeds: {seed},
        k: 5,
      ));
      expect(result.report.candidatesPerMode, {RecallMode.graphWalk: 0});
      expect(result.report.degraded, isTrue);
    });

    test('mode executor throwing → degraded, count = 0', () async {
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            throw StateError('boom'),
        nodeReader: makeBulkReader(const []),
      );
      final result = await exec.recall(
        RecallQuery(modes: const {RecallMode.bm25}, text: 'x', k: 5),
      );
      expect(result.report.candidatesPerMode, {RecallMode.bm25: 0});
      expect(result.report.degraded, isTrue);
    });

    // ─── Fusion gates ──────────────────────────────────────────────

    test('FusionStrategy.weighted throws UnimplementedError', () async {
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: mintId(), typeName: 'X', bm25Score: -1.0),
            ],
        nodeReader: makeBulkReader(const []),
      );
      expect(
        exec.recall(RecallQuery(
          modes: const {RecallMode.bm25},
          text: 'x',
          fusion: const FusionPolicy(strategy: FusionStrategy.weighted),
        )),
        throwsA(isA<UnimplementedError>()),
      );
    });

    // ─── Diversity gates ───────────────────────────────────────────

    test('DiversityStrategy.off passes fused list through', () async {
      final ids = List.generate(3, (_) => mintId());
      final nodes = ids.map(makeNode).toList();
      List<Bm25RecallCandidate> bm25({
        required String text,
        Set<String>? typeNames,
        int perModeK = 64,
      }) =>
          [
            for (var i = 0; i < ids.length; i++)
              Bm25RecallCandidate(
                  nodeId: ids[i],
                  typeName: 'Concept',
                  bm25Score: -(ids.length - i).toDouble()),
          ];
      final exec = newExecutor(
        bm25: bm25,
        nodeReader: makeBulkReader(nodes),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        diversity: const DiversityPolicy(strategy: DiversityStrategy.off),
        k: 10,
      ));
      expect(result.nodes.map((n) => n.id), ids);
      // off path → no lambda in report
      expect(result.report.diversityLambda, isNull);
      expect(result.report.diversityStrategy, DiversityStrategy.off);
    });

    test('DiversityStrategy.mmr reports the lambda used', () async {
      final id = mintId();
      List<Bm25RecallCandidate> bm25({
        required String text,
        Set<String>? typeNames,
        int perModeK = 64,
      }) =>
          [
            Bm25RecallCandidate(
                nodeId: id, typeName: 'X', bm25Score: -1.0),
          ];
      final exec = newExecutor(
        bm25: bm25,
        nodeReader: makeBulkReader([makeNode(id, typeName: 'X')]),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        diversity: const DiversityPolicy(lambda: 0.42),
      ));
      expect(result.report.diversityStrategy, DiversityStrategy.mmr);
      expect(result.report.diversityLambda, 0.42);
    });

    // ─── Re-rank hook ──────────────────────────────────────────────

    test('reRank null → reRankInvoked == false', () async {
      final id = mintId();
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: id, typeName: 'X', bm25Score: -1.0),
            ],
        nodeReader: makeBulkReader([makeNode(id, typeName: 'X')]),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
      ));
      expect(result.report.reRankInvoked, isFalse);
    });

    test('reRank reorder → reRankInvoked + node order changes', () async {
      final id1 = mintId();
      final id2 = mintId();
      final nodes = [makeNode(id1), makeNode(id2)];
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: id1, typeName: 'X', bm25Score: -2.0),
              Bm25RecallCandidate(
                  nodeId: id2, typeName: 'X', bm25Score: -1.0),
            ],
        nodeReader: makeBulkReader(nodes),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        reRank: (input) async => [input[1].id, input[0].id],
      ));
      expect(result.report.reRankInvoked, isTrue);
      expect(result.nodes.map((n) => n.id), [id2, id1]);
    });

    test('reRank subset → executor appends missing originals at end',
        () async {
      final id1 = mintId();
      final id2 = mintId();
      final id3 = mintId();
      final nodes = [makeNode(id1), makeNode(id2), makeNode(id3)];
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: id1, typeName: 'X', bm25Score: -3.0),
              Bm25RecallCandidate(
                  nodeId: id2, typeName: 'X', bm25Score: -2.0),
              Bm25RecallCandidate(
                  nodeId: id3, typeName: 'X', bm25Score: -1.0),
            ],
        nodeReader: makeBulkReader(nodes),
      );
      // Re-rank returns only id3 — the other two should be appended.
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        k: 10,
        reRank: (input) async => [id3],
      ));
      expect(result.report.reRankInvoked, isTrue);
      expect(result.nodes.map((n) => n.id), [id3, id1, id2]);
    });

    test('reRank unknown ids dropped, originals appended', () async {
      final id1 = mintId();
      final id2 = mintId();
      final unknown = mintId();
      final nodes = [makeNode(id1), makeNode(id2)];
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: id1, typeName: 'X', bm25Score: -2.0),
              Bm25RecallCandidate(
                  nodeId: id2, typeName: 'X', bm25Score: -1.0),
            ],
        nodeReader: makeBulkReader(nodes),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        reRank: (input) async => [unknown, id2],
      ));
      // unknown dropped silently; id2 first; id1 appended.
      expect(result.nodes.map((n) => n.id), [id2, id1]);
    });

    // ─── Budget ────────────────────────────────────────────────────

    test('wallClockMs == 0 disables the budget check', () async {
      final id = mintId();
      final clock = MutableTestClock(BrainTime.utc(2026, 1, 1));
      // Advance the clock inside the mode executor — even an arbitrary
      // jump must not trip the budget when it is disabled.
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) {
          clock.advance(const Duration(seconds: 10));
          return [
            Bm25RecallCandidate(
                nodeId: id, typeName: 'X', bm25Score: -1.0),
          ];
        },
        nodeReader: makeBulkReader([makeNode(id, typeName: 'X')]),
        clock: clock,
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        budget: const RecallBudget(wallClockMs: 0),
      ));
      expect(result.report.degraded, isFalse);
    });

    test('budget exceeded between modes → short-circuit + degraded',
        () async {
      final id1 = mintId();
      final id2 = mintId();
      final clock = MutableTestClock(BrainTime.utc(2026, 1, 1));
      var bm25Called = false;
      var symbolicCalled = false;
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) {
          bm25Called = true;
          clock.advance(const Duration(milliseconds: 500));
          return [
            Bm25RecallCandidate(
                nodeId: id1, typeName: 'X', bm25Score: -1.0),
          ];
        },
        symbolic: ({
          required SymbolicFilter filter,
          int perModeK = 64,
        }) {
          symbolicCalled = true;
          return [
            SymbolicRecallCandidate(
                nodeId: id2, typeName: 'X', createdAtMs: 0),
          ];
        },
        nodeReader: makeBulkReader(
            [makeNode(id1, typeName: 'X'), makeNode(id2, typeName: 'X')]),
        clock: clock,
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25, RecallMode.symbolic},
        text: 'x',
        filter: const SymbolicFilter(typeNames: {'X'}),
        budget: const RecallBudget(wallClockMs: 100),
      ));
      expect(bm25Called, isTrue);
      expect(symbolicCalled, isFalse);
      expect(result.report.degraded, isTrue);
      // bm25 ran; symbolic was skipped before it could contribute.
      expect(result.report.candidatesPerMode, {RecallMode.bm25: 1});
    });

    // ─── Report fields ─────────────────────────────────────────────

    test('elapsedMs reflects clock delta (MutableTestClock)', () async {
      final id = mintId();
      final clock = MutableTestClock(BrainTime.utc(2026, 1, 1));
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) {
          clock.advance(const Duration(milliseconds: 73));
          return [
            Bm25RecallCandidate(
                nodeId: id, typeName: 'X', bm25Score: -1.0),
          ];
        },
        nodeReader: makeBulkReader([makeNode(id, typeName: 'X')]),
        clock: clock,
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
      ));
      expect(result.report.elapsedMs, 73);
    });

    test('embeddingsCallouts is 0 at A.59', () async {
      final id = mintId();
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: id, typeName: 'X', bm25Score: -1.0),
            ],
        nodeReader: makeBulkReader([makeNode(id, typeName: 'X')]),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
        embedding: Vec.fromList(const [1.0, 0.0]),
      ));
      expect(result.report.embeddingsCallouts, 0);
    });

    test('candidatesPerMode is unmodifiable', () async {
      final exec = newExecutor(nodeReader: makeBulkReader(const []));
      final result = await exec.recall(
        RecallQuery(modes: const {RecallMode.bm25}, text: 'x'),
      );
      expect(
        () => result.report.candidatesPerMode[RecallMode.symbolic] = 1,
        throwsUnsupportedError,
      );
    });

    // ─── Materialisation ───────────────────────────────────────────

    test('bulk reader sees the post-MMR id list in order', () async {
      final id1 = mintId();
      final id2 = mintId();
      List<NodeId>? sawIds;
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: id1, typeName: 'X', bm25Score: -2.0),
              Bm25RecallCandidate(
                  nodeId: id2, typeName: 'X', bm25Score: -1.0),
            ],
        nodeReader: (ids) async {
          sawIds = ids;
          return [
            makeNode(id1, typeName: 'X'),
            makeNode(id2, typeName: 'X'),
          ];
        },
      );
      await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
      ));
      expect(sawIds, isNotNull);
      // MMR with default lambda preserves relevance order for two
      // non-similar items.
      expect(sawIds!.first, id1);
    });

    test('bulk reader returning a short list → final nodes reflect it',
        () async {
      final id1 = mintId();
      final id2 = mintId();
      final exec = newExecutor(
        bm25: ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              Bm25RecallCandidate(
                  nodeId: id1, typeName: 'X', bm25Score: -2.0),
              Bm25RecallCandidate(
                  nodeId: id2, typeName: 'X', bm25Score: -1.0),
            ],
        // Only id2 actually exists in the underlying store.
        nodeReader: makeBulkReader([makeNode(id2, typeName: 'X')]),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25},
        text: 'x',
      ));
      expect(result.nodes.map((n) => n.id), [id2]);
    });
  });
}
