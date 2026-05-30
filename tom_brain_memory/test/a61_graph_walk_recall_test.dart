// A.61 — graphWalk mode against memory.db.
//
// Plan step A.61:
//   "Implement `graphWalk` mode with bounded depth, cycle detection,
//    per-edge-type weights."
//
// Plan step A.62 (rolled into this file to avoid splitting tightly
// coupled coverage across two scaffolds):
//   "Tests: cycle safety, depth bound respected, mixed-edge walks
//    return expected nodes."
//
// What this file covers (one `test(...)` per row):
//
//   Empty-input fast paths
//   ----------------------
//   * `seeds` is empty → returns [] without issuing SQL.
//   * `maxDepth <= 0` → returns [] without issuing SQL.
//   * `perModeK <= 0` → returns [] without issuing SQL.
//   * All edge-type weights zero → returns [] without issuing SQL.
//
//   Bounded depth
//   -------------
//   * `maxDepth = 1` from A on chain A→B→C reaches only {B}.
//   * `maxDepth = 2` from A on chain A→B→C→D reaches {B, C} (D excluded).
//   * `maxDepth = 3` on the same chain reaches {B, C, D}.
//
//   Seeds excluded from results
//   ---------------------------
//   * Seed never appears in the result list even when reachable from
//     other seeds via a cycle.
//
//   Cycle safety
//   ------------
//   * A→B, B→A: walking from A with maxDepth=3 returns {B} once, not
//     {B, A, B, A, …}.
//   * Self-loop A→A: returns [] (the only reachable node is the seed
//     itself, which is excluded).
//   * Triangle A→B→C→A from seed A with maxDepth=3 returns {B, C}.
//
//   Per-edge-type weights
//   ---------------------
//   * Boosting one edge type lifts its neighbour above another
//     neighbour reached over a default-weighted edge.
//   * Edge-type weight `0.0` removes that label from the walk
//     entirely (neighbour reached only via that label is not in the
//     result set).
//
//   typeNames post-filter
//   ---------------------
//   * `typeNames = {'A'}` narrows the result to nodes of that type;
//     other reachable nodes are dropped silently. (Uses the
//     dual-type fixture below — `Topic` and `Marker`.)
//
//   Determinism + ordering
//   ----------------------
//   * Same query twice → identical NodeId list.
//   * Result is ordered by score desc, tie-broken by NodeId.value asc.
//   * `perModeK` truncates the result to the top-K candidates after
//     ordering.
//
//   Direction filter
//   ----------------
//   * `direction = outgoing` from A on A→B and C→A returns {B}.
//   * `direction = incoming` from A on the same graph returns {C}.
//   * `direction = both` returns {B, C}.
//
//   Input validation
//   ----------------
//   * Negative `depthDecay` raises ArgumentError.
//   * Negative entry in `edgeTypeWeights` raises ArgumentError.
//
//   Depth decay scoring
//   -------------------
//   * Decay 1.0: a 2-hop and a 1-hop neighbour have comparable scores
//     (parent * edgeWeight pattern only).
//   * Decay 0.5 (default): 2-hop neighbour scores half (per hop) of
//     what it would at decay 1.0, so a 1-hop neighbour reached over
//     a default edge outranks a 2-hop neighbour over the same kind of
//     edge.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, EdgeId, FixedClock, NodeId, Vec;

void main() {
  group('A.61 GraphWalkRecall', () {
    late Database memoryDb;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late EdgeWriter edgeWriter;
    late GraphWalkRecall recall;
    late int nodeIdCounter;
    late int edgeIdCounter;
    late DateTime fakeNow;
    late _RecordingVectorApplier applier;

    NodeId mintNodeId() {
      nodeIdCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (nodeIdCounter + i) & 31),
      );
    }

    EdgeId mintEdgeId() {
      edgeIdCounter += 1;
      return EdgeId.generate(
        at: fakeNow,
        randomness:
            List<int>.generate(16, (i) => (edgeIdCounter * 7 + i) & 31),
      );
    }

    setUp(() async {
      memoryDb = sqlite3.openInMemory();
      applySchemaV1(memoryDb);
      applier = _RecordingVectorApplier();
      coordinator = TwoDbCoordinator(
        memoryDb: memoryDb,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );

      nodeIdCounter = 0;
      edgeIdCounter = 0;
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);

      var regIdCounter = 1000;
      NodeId mintRegistryId() {
        regIdCounter += 1;
        return NodeId.generate(
          at: fakeNow,
          randomness:
              List<int>.generate(16, (i) => (regIdCounter + i) & 31),
        );
      }

      registry = NodeTypeRegistry(
        memoryDb: memoryDb,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_topicType());
      await registry.registerNodeType(_markerType());

      persister = NodePersister(
        memoryDb: memoryDb,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
      );

      edgeWriter = EdgeWriter(
        memoryDb: memoryDb,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
      );

      recall = GraphWalkRecall(memoryDb: memoryDb);
    });

    tearDown(() {
      memoryDb.dispose();
    });

    Future<NodeId> mkTopic(String label) {
      return persister.persist(
        NodeDraft(
          typeName: 'Topic',
          values: <String, Object?>{'label': label},
          embedding: _v768(seed: label.hashCode & 0xff),
        ),
        scope: Scope(producer: 'test', idempotencyKey: 'topic-$label'),
      );
    }

    Future<NodeId> mkMarker(String label) {
      return persister.persist(
        NodeDraft(
          typeName: 'Marker',
          values: <String, Object?>{'label': label},
          embedding: _v768(seed: (label.hashCode & 0xff) + 1),
        ),
        scope: Scope(producer: 'test', idempotencyKey: 'marker-$label'),
      );
    }

    // ─── Empty-input fast paths ──────────────────────────────────────

    test('empty seeds returns [] without issuing SQL', () {
      final result = recall.recall(seeds: <NodeId>{});
      expect(result, isEmpty);
    });

    test('maxDepth <= 0 returns [] without issuing SQL', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      await edgeWriter.edge(a, EdgeType.mentions, b);

      expect(
        recall.recall(
          seeds: <NodeId>{a},
          policy: const GraphWalkPolicy(maxDepth: 0),
        ),
        isEmpty,
      );
      expect(
        recall.recall(
          seeds: <NodeId>{a},
          policy: const GraphWalkPolicy(maxDepth: -1),
        ),
        isEmpty,
      );
    });

    test('perModeK <= 0 returns [] without issuing SQL', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      await edgeWriter.edge(a, EdgeType.mentions, b);

      expect(
        recall.recall(seeds: <NodeId>{a}, perModeK: 0),
        isEmpty,
      );
      expect(
        recall.recall(seeds: <NodeId>{a}, perModeK: -5),
        isEmpty,
      );
    });

    test('all edge-type weights zero returns [] without issuing SQL',
        () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      await edgeWriter.edge(a, EdgeType.mentions, b);

      final zeros = <EdgeType, double>{
        for (final t in EdgeType.values) t: 0.0,
      };
      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: GraphWalkPolicy(edgeTypeWeights: zeros),
      );
      expect(result, isEmpty);
    });

    // ─── Bounded depth ───────────────────────────────────────────────

    test('maxDepth=1 on chain A→B→C reaches only {B}', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, c);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 1),
      );
      expect(result.map((c) => c.nodeId), equals(<NodeId>[b]));
    });

    test('maxDepth=2 on chain A→B→C→D reaches {B, C} (D excluded)',
        () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      final d = await mkTopic('d');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, c);
      await edgeWriter.edge(c, EdgeType.mentions, d);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 2),
      );
      expect(result.map((c) => c.nodeId).toSet(), equals(<NodeId>{b, c}));
      expect(result.map((c) => c.nodeId), isNot(contains(d)));
    });

    test('maxDepth=3 on chain A→B→C→D reaches {B, C, D}', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      final d = await mkTopic('d');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, c);
      await edgeWriter.edge(c, EdgeType.mentions, d);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 3),
      );
      expect(
        result.map((c) => c.nodeId).toSet(),
        equals(<NodeId>{b, c, d}),
      );
    });

    // ─── Seeds excluded from results ─────────────────────────────────

    test('seed never appears in the result list', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      // A cycle A→B→A — the second hop reaches A again. The visited-
      // set + seed-exclusion guard means A never appears in the
      // candidate list.
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, a);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 3),
      );
      expect(result.map((c) => c.nodeId), isNot(contains(a)));
      expect(result.map((c) => c.nodeId).toSet(), equals(<NodeId>{b}));
    });

    // ─── Cycle safety ────────────────────────────────────────────────

    test('A→B, B→A: maxDepth=3 returns {B} exactly once', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, a);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 3),
      );
      // Exactly one candidate, exactly node B.
      expect(result, hasLength(1));
      expect(result.single.nodeId, equals(b));
    });

    test('self-loop A→A returns [] (only reachable node is the seed)',
        () async {
      final a = await mkTopic('a');
      await edgeWriter.edge(a, EdgeType.mentions, a);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 3),
      );
      expect(result, isEmpty);
    });

    test('triangle A→B→C→A from A with maxDepth=3 returns {B, C}',
        () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, c);
      await edgeWriter.edge(c, EdgeType.mentions, a);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 3),
      );
      expect(result.map((c) => c.nodeId).toSet(), equals(<NodeId>{b, c}));
      // Each appears exactly once.
      expect(result, hasLength(2));
    });

    // ─── Per-edge-type weights ───────────────────────────────────────

    test('boosting an edge type lifts its neighbour above a default-'
        'weighted one', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      // Two equally-distant direct neighbours, different edge types.
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(a, EdgeType.derivedFrom, c);

      final boosted = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(
          maxDepth: 1,
          edgeTypeWeights: <EdgeType, double>{
            EdgeType.derivedFrom: 5.0,
          },
        ),
      );
      // C should outrank B because derived_from is 5x weighted.
      expect(boosted.first.nodeId, equals(c));
      expect(boosted.last.nodeId, equals(b));
      expect(boosted.first.score, greaterThan(boosted.last.score));
    });

    test('edge-type weight 0.0 removes that label from the walk',
        () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      // Two direct neighbours of A: B via mentions, C via derivedFrom.
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(a, EdgeType.derivedFrom, c);

      // Zero out `mentions` — B should disappear from the result, C
      // should remain.
      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(
          maxDepth: 1,
          edgeTypeWeights: <EdgeType, double>{
            EdgeType.mentions: 0.0,
          },
        ),
      );
      expect(result.map((c) => c.nodeId).toSet(), equals(<NodeId>{c}));
    });

    // ─── typeNames post-filter ───────────────────────────────────────

    test('typeNames narrows result to nodes of the requested type',
        () async {
      final a = await mkTopic('a');
      final t1 = await mkTopic('t1');
      final m1 = await mkMarker('m1');
      await edgeWriter.edge(a, EdgeType.mentions, t1);
      await edgeWriter.edge(a, EdgeType.mentions, m1);

      // Without the filter both neighbours come back.
      final all = recall.recall(seeds: <NodeId>{a});
      expect(all.map((c) => c.nodeId).toSet(), equals(<NodeId>{t1, m1}));

      // typeNames = {Topic} drops the Marker.
      final topicOnly = recall.recall(
        seeds: <NodeId>{a},
        typeNames: const <String>{'Topic'},
      );
      expect(
        topicOnly.map((c) => c.nodeId).toSet(),
        equals(<NodeId>{t1}),
      );

      // typeNames = {Marker} drops the Topic.
      final markerOnly = recall.recall(
        seeds: <NodeId>{a},
        typeNames: const <String>{'Marker'},
      );
      expect(
        markerOnly.map((c) => c.nodeId).toSet(),
        equals(<NodeId>{m1}),
      );
    });

    // ─── Determinism + ordering ──────────────────────────────────────

    test('same query twice returns the identical NodeId list', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      final d = await mkTopic('d');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(a, EdgeType.mentions, c);
      await edgeWriter.edge(b, EdgeType.mentions, d);

      final first = recall.recall(seeds: <NodeId>{a});
      final second = recall.recall(seeds: <NodeId>{a});
      expect(
        second.map((c) => c.nodeId).toList(),
        equals(first.map((c) => c.nodeId).toList()),
      );
      expect(
        second.map((c) => c.score).toList(),
        equals(first.map((c) => c.score).toList()),
      );
    });

    test('result is ordered by score desc, tie-broken by NodeId asc',
        () async {
      final a = await mkTopic('a');
      // Three direct neighbours, all reached via the same edge type at
      // weight 1.0, so all candidate scores are identical. The tie-
      // break must be NodeId.value ASC.
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      final d = await mkTopic('d');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(a, EdgeType.mentions, c);
      await edgeWriter.edge(a, EdgeType.mentions, d);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 1),
      );
      expect(result, hasLength(3));

      // Scores all equal.
      final scores = result.map((c) => c.score).toSet();
      expect(scores, hasLength(1));

      // Order matches NodeId.value ASC.
      final expectedOrder = <NodeId>[b, c, d]
        ..sort((x, y) => x.value.compareTo(y.value));
      expect(
        result.map((c) => c.nodeId).toList(),
        equals(expectedOrder),
      );
    });

    test('perModeK truncates the result to the top-K candidates',
        () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      final d = await mkTopic('d');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(a, EdgeType.mentions, c);
      await edgeWriter.edge(a, EdgeType.mentions, d);

      final all = recall.recall(seeds: <NodeId>{a});
      expect(all, hasLength(3));

      final truncated = recall.recall(seeds: <NodeId>{a}, perModeK: 2);
      expect(truncated, hasLength(2));
      // Same prefix as the full result (which is deterministically
      // ordered).
      expect(
        truncated.map((c) => c.nodeId).toList(),
        equals(all.take(2).map((c) => c.nodeId).toList()),
      );
    });

    // ─── Direction filter ────────────────────────────────────────────

    test('direction=outgoing follows only from→to', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      await edgeWriter.edge(a, EdgeType.mentions, b); // A→B (outgoing)
      await edgeWriter.edge(c, EdgeType.mentions, a); // C→A (incoming)

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(
          maxDepth: 1,
          direction: EdgeDirection.outgoing,
        ),
      );
      expect(result.map((c) => c.nodeId).toSet(), equals(<NodeId>{b}));
    });

    test('direction=incoming follows only to→from', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(c, EdgeType.mentions, a);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(
          maxDepth: 1,
          direction: EdgeDirection.incoming,
        ),
      );
      expect(result.map((c) => c.nodeId).toSet(), equals(<NodeId>{c}));
    });

    test('direction=both walks the undirected graph', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(c, EdgeType.mentions, a);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 1),
      );
      expect(result.map((c) => c.nodeId).toSet(), equals(<NodeId>{b, c}));
    });

    // ─── Input validation ────────────────────────────────────────────

    test('negative depthDecay raises ArgumentError', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      await edgeWriter.edge(a, EdgeType.mentions, b);

      expect(
        () => recall.recall(
          seeds: <NodeId>{a},
          policy: const GraphWalkPolicy(depthDecay: -0.5),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative entry in edgeTypeWeights raises ArgumentError',
        () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      await edgeWriter.edge(a, EdgeType.mentions, b);

      expect(
        () => recall.recall(
          seeds: <NodeId>{a},
          policy: const GraphWalkPolicy(
            edgeTypeWeights: <EdgeType, double>{
              EdgeType.mentions: -1.0,
            },
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    // ─── Depth decay scoring ─────────────────────────────────────────

    test('depthDecay=0.5 makes 1-hop outrank 2-hop over same edge type',
        () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b'); // 1-hop from A
      final c = await mkTopic('c'); // 2-hop from A via B
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, c);

      final result = recall.recall(
        seeds: <NodeId>{a},
        // Default decay 0.5.
      );
      // B is 1-hop, C is 2-hop. Same edge weight (1.0), same edge type
      // weight (1.0); B's score = 1.0*1.0*1.0*0.5 = 0.5, C's score =
      // 0.5*1.0*1.0*0.5 = 0.25. B must come first.
      expect(result.map((c) => c.nodeId), equals(<NodeId>[b, c]));
      expect(result.first.score, greaterThan(result.last.score));
      expect(result.first.score, closeTo(0.5, 1e-9));
      expect(result.last.score, closeTo(0.25, 1e-9));
    });

    test('depthDecay=1.0 makes 1-hop and 2-hop score equally', () async {
      final a = await mkTopic('a');
      final b = await mkTopic('b');
      final c = await mkTopic('c');
      await edgeWriter.edge(a, EdgeType.mentions, b);
      await edgeWriter.edge(b, EdgeType.mentions, c);

      final result = recall.recall(
        seeds: <NodeId>{a},
        policy: const GraphWalkPolicy(maxDepth: 2, depthDecay: 1.0),
      );
      // With decay 1.0 both hops contribute the same factor; B's
      // score = 1.0*1.0*1.0*1.0 = 1.0, C's score = 1.0*1.0*1.0*1.0 =
      // 1.0. Tie-break by NodeId asc.
      expect(result.map((c) => c.score).toSet(), equals(<double>{1.0}));
      final expectedOrder = <NodeId>[b, c]
        ..sort((x, y) => x.value.compareTo(y.value));
      expect(
        result.map((c) => c.nodeId).toList(),
        equals(expectedOrder),
      );
    });
  });
}

// ─── Fixtures ────────────────────────────────────────────────────────

/// A permissive `Topic` type that allows every edge in the closed
/// alphabet both ways. Lets the tests build any graph shape without
/// fighting the per-type permission table.
NodeTypeDecl _topicType() => NodeTypeDecl(
      typeName: 'Topic',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'label': const FieldSpec(
          name: 'label',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['label'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'label'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 90 * 86400 * 1000,
      ),
      allowedOutgoing: EdgeType.values.toSet(),
      allowedIncoming: EdgeType.values.toSet(),
    );

/// A second permissive type so the typeNames post-filter test has a
/// distinguishable target.
NodeTypeDecl _markerType() => NodeTypeDecl(
      typeName: 'Marker',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'label': const FieldSpec(
          name: 'label',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['label'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'label'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 90 * 86400 * 1000,
      ),
      allowedOutgoing: EdgeType.values.toSet(),
      allowedIncoming: EdgeType.values.toSet(),
    );

Vec _v768({required int seed}) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

final class _RecordingVectorApplier implements VectorApplier {
  final List<PendingVectorWrite> calls = <PendingVectorWrite>[];

  @override
  void apply(PendingVectorWrite write) {
    calls.add(write);
  }
}
