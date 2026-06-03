// A.69 — ShakingEvent emission, end-to-end across the four sub-kinds.
//
// Plan step A.69:
//   "Implement `ShakingEvent` emission for `ContradictionDetected`,
//    `CentroidDriftDetected`, `RetrievalConflict`, `CritiqueRejected`."
//
// Spec § 9.4 + § 16 name shaking events as the typed signals routed
// to `dream_reconsolidate_v1`. This test file locks the contract for
// every emission site:
//
//   1. `ContradictionDetected`  — `EdgeWriter.edge(..., contradicts)`
//   2. `CentroidDriftDetected`  — `CentroidStore.update(...)` when
//                                  cosine < threshold OR model-id changed
//   3. `RetrievalConflict`      — `RecallExecutor.recall(...)` when
//                                  ≥2 modes returned non-empty top-K
//                                  with empty intersection
//   4. `CritiqueRejected`       — agent-raised via `ShakingEventEmitter`
//
// The four sub-kinds share `ShakingEvent.kindPrefix = 'memory.shaking.'`;
// every emission asserts that prefix so a typo in any one leaf would
// fail this test.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BrainTime,
        BrainVersion,
        EdgeId,
        FixedClock,
        MutableTestClock,
        NodeId,
        Vec;

void main() {
  // ─────────────────────────────────────────────────────────────────
  // 1. ContradictionDetected
  // ─────────────────────────────────────────────────────────────────

  group('A.69 ContradictionDetected (EdgeWriter)', () {
    late Database db;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late List<MemoryEvent> events;
    late int idCounter;
    late int edgeIdCounter;
    late DateTime fakeNow;

    NodeId mintNodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter + i) & 31),
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
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      events = <MemoryEvent>[];
      idCounter = 0;
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
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      // Claim allows contradicts both ways → lets us exercise the
      // shaking-event emission without needing a Contradiction node.
      await registry.registerNodeType(_claimContradicts());
      // Plain Claim — allows only derivedFrom → lets us assert that a
      // non-contradicts edge does NOT emit the shaking event.
      await registry.registerNodeType(_sourceForDerived());

      persister = NodePersister(
        memoryDb: db,
        coordinator: TwoDbCoordinator(
          memoryDb: db,
          applier: _NoOpApplier(),
          clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
        ),
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
      );
    });

    tearDown(() => db.dispose());

    EdgeWriter buildWriter() => EdgeWriter(
          memoryDb: db,
          registry: registry,
          idMint: mintEdgeId,
          now: () => fakeNow,
          eventSink: events.add,
        );

    Future<NodeId> persistClaim(String text, {required String key}) =>
        persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: <String, Object?>{'text': text},
            embedding: _v768(seed: key.hashCode),
          ),
          scope: Scope(producer: 'test', idempotencyKey: key),
        );

    Future<NodeId> persistSource(String url, {required String key}) =>
        persister.persist(
          NodeDraft(
            typeName: 'Source',
            values: <String, Object?>{'url': url},
            embedding: _v768(seed: key.hashCode + 7),
          ),
          scope: Scope(producer: 'test', idempotencyKey: key),
        );

    test('contradicts edge emits EdgeCreated then ContradictionDetected',
        () async {
      final writer = buildWriter();
      final a = await persistClaim('a', key: 'a');
      final b = await persistClaim('b', key: 'b');

      final id = await writer.edge(
        a,
        EdgeType.contradicts,
        b,
        scope: const Scope(
          producer: 'reconsolidator:run-1',
          runId: 'r-77',
          causedBy: 'evt-3',
        ),
      );

      // EdgeCreated lands first, ContradictionDetected second — the
      // pairing the file header documents as "structural fact first,
      // cognitive signal second".
      expect(events, hasLength(2));
      expect(events[0], isA<EdgeCreated>());
      expect(events[1], isA<ContradictionDetected>());

      final ce = events[1] as ContradictionDetected;
      expect(ce.edgeId, equals(id));
      expect(ce.from, equals(a));
      expect(ce.to, equals(b));
      expect(ce.fromTypeName, equals('Claim'));
      expect(ce.toTypeName, equals('Claim'));
      expect(ce.runId, equals('r-77'));
      expect(ce.causedBy, equals('evt-3'));
      expect(ce.occurredAt, equals(fakeNow));
      expect(ce.kind, equals('memory.shaking.contradiction-detected'));
      expect(ce.kind, startsWith(ShakingEvent.kindPrefix));
      expect(
        ce.payloadJson(),
        equals(<String, Object?>{
          'edgeId': id.toString(),
          'from': a.toString(),
          'to': b.toString(),
          'type': 'contradicts',
          'fromTypeName': 'Claim',
          'toTypeName': 'Claim',
        }),
      );
    });

    test('non-contradicts edge does NOT emit ContradictionDetected',
        () async {
      final writer = buildWriter();
      final claim = await persistClaim('c', key: 'c');
      final source = await persistSource('https://example.org/', key: 's');

      await writer.edge(
        claim,
        EdgeType.derivedFrom,
        source,
        scope: const Scope.nonIdempotent(producer: 'test'),
      );

      expect(events.whereType<EdgeCreated>(), hasLength(1));
      expect(events.whereType<ContradictionDetected>(), isEmpty);
    });

    test('idempotency hit on a contradicts edge does NOT re-emit',
        () async {
      final writer = buildWriter();
      final a = await persistClaim('aa', key: 'aa');
      final b = await persistClaim('bb', key: 'bb');
      const scope = Scope(producer: 'test', idempotencyKey: 'idem-1');

      final id1 = await writer.edge(a, EdgeType.contradicts, b, scope: scope);
      final id2 = await writer.edge(a, EdgeType.contradicts, b, scope: scope);

      // First call emits both; second call (idempotency hit) emits
      // neither — a re-call is a silent no-op, not a re-signal.
      expect(id1, equals(id2));
      expect(events.whereType<EdgeCreated>(), hasLength(1));
      expect(events.whereType<ContradictionDetected>(), hasLength(1));
    });

    test('rejection path does NOT emit ContradictionDetected', () async {
      final writer = buildWriter();
      final claim = await persistClaim('only', key: 'only');
      final source = await persistSource('https://example.org/r', key: 'sr');

      // contradicts is not in Source's allowedIncoming → throws + emits
      // EdgeRejected. ContradictionDetected must NOT fire — the
      // contradiction never actually committed.
      expect(
        () => writer.edge(
          claim,
          EdgeType.contradicts,
          source,
          scope: const Scope.nonIdempotent(producer: 'test'),
        ),
        throwsA(isA<EdgeNotPermitted>()),
      );
      expect(events.whereType<EdgeRejected>(), hasLength(1));
      expect(events.whereType<ContradictionDetected>(), isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 2. CentroidDriftDetected
  // ─────────────────────────────────────────────────────────────────

  group('A.69 CentroidDriftDetected (CentroidStore)', () {
    late Database db;
    late MutableTestClock clock;
    late List<MemoryEvent> events;
    late CentroidStore store;

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));
      events = <MemoryEvent>[];
      store = CentroidStore(
        memoryDb: db,
        clock: clock,
        eventSink: events.add,
      );
    });

    tearDown(() => db.dispose());

    final key = CentroidStore.keyForNodeType('Question');

    test('first-ever update emits no drift (no prior to compare)', () {
      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _unit768(seed: 1),
        exampleCount: 20,
      );
      // No prior centroid → no `CentroidDriftDetected`. The
      // unconditional `CentroidUpdated` audit (spec § 16) does fire on
      // every write, so this asserts the absence of the *drift* signal
      // specifically rather than an empty stream.
      expect(events.whereType<CentroidDriftDetected>(), isEmpty);
    });

    test('cosine above threshold + same model emits nothing', () {
      final c = _unit768(seed: 42);
      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: c,
        exampleCount: 20,
      );
      // A near-duplicate centroid (cosine very close to 1.0) — well
      // above the 0.85 default. Should NOT emit.
      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: c,
        exampleCount: 21,
      );
      expect(events.whereType<CentroidDriftDetected>(), isEmpty);
    });

    test('cosine below threshold + enough prior examples emits with cosine',
        () {
      // Prior: a basis-aligned vector. New: an orthogonal one.
      // cosine(prior, new) = 0.0, far below the 0.85 default.
      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 0),
        exampleCount: 12,
      );
      events.clear(); // first update emits nothing anyway

      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 7),
        exampleCount: 13,
        scope: const Scope(
          producer: 'recentroid:r-9',
          runId: 'r-9',
          causedBy: 'sleep-9',
        ),
      );

      final drift = events.whereType<CentroidDriftDetected>().single;
      expect(drift.forKey, equals(key));
      expect(drift.embeddingModelId, equals('nomic-embed-text@v1.5'));
      expect(drift.previousEmbeddingModelId, equals('nomic-embed-text@v1.5'));
      expect(drift.previousExampleCount, equals(12));
      expect(drift.exampleCount, equals(13));
      expect(drift.cosineSimilarity, isNotNull);
      expect(drift.cosineSimilarity!, closeTo(0.0, 1e-6));
      expect(drift.driftCosineThreshold,
          equals(CentroidStore.defaultDriftCosineThreshold));
      expect(drift.isEmbeddingModelChange, isFalse);
      expect(drift.runId, equals('r-9'));
      expect(drift.causedBy, equals('sleep-9'));
      expect(drift.kind, equals('memory.shaking.centroid-drift-detected'));
      expect(drift.kind, startsWith(ShakingEvent.kindPrefix));
    });

    test('cosine below threshold but prior example count below floor → no emit',
        () {
      // Prior with only 4 examples — below the default floor of 8.
      // Even with an orthogonal change, the drift is treated as
      // cold-start jitter, not a real signal.
      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 0),
        exampleCount: 4,
      );
      events.clear();

      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 7),
        exampleCount: 5,
      );
      expect(events.whereType<CentroidDriftDetected>(), isEmpty);
    });

    test('model-id change emits unconditionally with cosineSimilarity=null',
        () {
      // Tiny example count would normally suppress drift, but a
      // model-id change is treated as incommensurable vectors and
      // bypasses both gates.
      store.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _unit768(seed: 1),
        exampleCount: 2,
      );
      events.clear();

      store.update(
        forKey: key,
        embeddingModelId: 'gemma3:embed@v1',
        centroid: _unit768(seed: 1), // identical bytes
        exampleCount: 3,
      );

      final drift = events.whereType<CentroidDriftDetected>().single;
      expect(drift.embeddingModelId, equals('gemma3:embed@v1'));
      expect(drift.previousEmbeddingModelId, equals('nomic-embed-text@v1.5'));
      expect(drift.cosineSimilarity, isNull);
      expect(drift.isEmbeddingModelChange, isTrue);
      expect(drift.payloadJson()['embeddingModelChange'], isTrue);
      // The null cosine must NOT be serialised — its presence would
      // mislead subscribers reading the JSON form.
      expect(drift.payloadJson().containsKey('cosineSimilarity'), isFalse);
    });

    test('custom thresholds are honoured + carried on the event', () {
      final stricter = CentroidStore(
        memoryDb: db,
        clock: clock,
        eventSink: events.add,
        driftCosineThreshold: 0.99,
        driftMinPreviousExamples: 2,
      );
      stricter.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 0),
        exampleCount: 5,
      );
      events.clear();

      // A small drift that would pass the 0.85 default but fails 0.99.
      // axis 0 vs a basis vector with slight tilt → cosine far below 0.99.
      stricter.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 1),
        exampleCount: 6,
      );
      final drift = events.whereType<CentroidDriftDetected>().single;
      expect(drift.driftCosineThreshold, equals(0.99));
    });

    test('constructor validates threshold + floor ranges', () {
      expect(
        () => CentroidStore(
          memoryDb: db,
          clock: clock,
          driftCosineThreshold: 1.5,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => CentroidStore(
          memoryDb: db,
          clock: clock,
          driftMinPreviousExamples: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('eventSink absent → drift detection short-circuits cleanly', () {
      // No sink wired: even a clearly-drifted update must not blow up
      // and must not allocate event objects we then drop.
      final silent = CentroidStore(memoryDb: db, clock: clock);
      silent.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 0),
        exampleCount: 20,
      );
      silent.update(
        forKey: key,
        embeddingModelId: 'nomic-embed-text@v1.5',
        centroid: _axis768(axis: 7),
        exampleCount: 21,
      );
      // No sink, so we can only assert "did not throw" — and that
      // the row was actually upserted.
      expect(silent.count(), equals(1));
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 3. RetrievalConflict
  // ─────────────────────────────────────────────────────────────────

  group('A.69 RetrievalConflict (RecallExecutor)', () {
    int seed = 0;
    NodeId mintId() {
      seed += 1;
      final at = DateTime.utc(2026, 1, 1).add(Duration(minutes: seed));
      final randomness =
          List<int>.generate(16, (i) => (seed * 31 + i * 7) & 0x1F);
      return NodeId.generate(at: at, randomness: randomness);
    }

    setUp(() => seed = 0);

    Node makeNode(NodeId id) => Node(
          id: id,
          typeName: 'Concept',
          values: const <String, Object?>{},
          createdAt: DateTime.utc(2026, 1, 1),
        );

    NodeBulkReader makeReader(List<Node> all) => (ids) async {
          final byId = <String, Node>{for (final n in all) n.id.value: n};
          return [for (final id in ids) byId[id.value]]
              .whereType<Node>()
              .toList();
        };

    Bm25ModeFn fakeBm25(List<NodeId> ids) => ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            [
              for (var i = 0; i < ids.length; i++)
                Bm25RecallCandidate(
                  nodeId: ids[i],
                  typeName: 'Concept',
                  bm25Score: -(ids.length - i).toDouble(),
                ),
            ];

    SymbolicModeFn fakeSymbolic(List<NodeId> ids) => ({
          required SymbolicFilter filter,
          int perModeK = 64,
        }) =>
            [
              for (final id in ids)
                SymbolicRecallCandidate(
                  nodeId: id,
                  typeName: 'Concept',
                  createdAtMs: 0,
                ),
            ];

    Bm25ModeFn emptyBm25() => ({
          required String text,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            const <Bm25RecallCandidate>[];

    SymbolicModeFn emptySymbolic() => ({
          required SymbolicFilter filter,
          int perModeK = 64,
        }) =>
            const <SymbolicRecallCandidate>[];

    VectorModeFn emptyVector() => ({
          required Vec query,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            const <VectorRecallCandidate>[];

    GraphWalkModeFn emptyGraphWalk() => ({
          required Set<NodeId> seeds,
          GraphWalkPolicy policy = GraphWalkPolicy.defaultPolicy,
          Set<String>? typeNames,
          int perModeK = 64,
        }) =>
            const <GraphWalkRecallCandidate>[];

    RecallExecutor build({
      Bm25ModeFn? bm25,
      SymbolicModeFn? symbolic,
      required NodeBulkReader nodeReader,
      required void Function(MemoryEvent) sink,
    }) =>
        RecallExecutor.fromCallables(
          bm25: bm25 ?? emptyBm25(),
          vector: emptyVector(),
          symbolic: symbolic ?? emptySymbolic(),
          graphWalk: emptyGraphWalk(),
          nodeReader: nodeReader,
          clock: MutableTestClock(BrainTime.utc(2026, 1, 1)),
          eventSink: sink,
        );

    test('two modes with disjoint top-K → RetrievalConflict emitted',
        () async {
      final a1 = mintId();
      final a2 = mintId();
      final a3 = mintId();
      final b1 = mintId();
      final b2 = mintId();
      final nodes = [a1, a2, a3, b1, b2].map(makeNode).toList();
      final events = <MemoryEvent>[];

      final exec = build(
        bm25: fakeBm25([a1, a2, a3]),
        symbolic: fakeSymbolic([b1, b2]),
        nodeReader: makeReader(nodes),
        sink: events.add,
      );

      await exec.recall(
        RecallQuery(
          modes: const {RecallMode.bm25, RecallMode.symbolic},
          text: 'q',
          filter: const SymbolicFilter(typeNames: {'Concept'}),
          k: 5,
        ),
        scope: const Scope(
          producer: 'recall:r-42',
          runId: 'r-42',
          causedBy: 'q-42',
        ),
      );

      final conflict = events.whereType<RetrievalConflict>().single;
      expect(conflict.conflictingModes,
          containsAll([RecallMode.bm25, RecallMode.symbolic]));
      expect(conflict.conflictingModes, hasLength(2));
      expect(conflict.topPerMode[RecallMode.bm25], equals([a1, a2, a3]));
      expect(conflict.topPerMode[RecallMode.symbolic], equals([b1, b2]));
      // perModeK defaults to a value >= 5 → topK clamped to 5.
      expect(conflict.topK, equals(5));
      expect(conflict.runId, equals('r-42'));
      expect(conflict.causedBy, equals('q-42'));
      expect(conflict.kind, equals('memory.shaking.retrieval-conflict'));
      expect(conflict.kind, startsWith(ShakingEvent.kindPrefix));
    });

    test('overlapping top-K → no RetrievalConflict emitted', () async {
      final shared = mintId();
      final a2 = mintId();
      final b2 = mintId();
      final nodes = [shared, a2, b2].map(makeNode).toList();
      final events = <MemoryEvent>[];

      final exec = build(
        bm25: fakeBm25([shared, a2]),
        symbolic: fakeSymbolic([shared, b2]),
        nodeReader: makeReader(nodes),
        sink: events.add,
      );

      await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25, RecallMode.symbolic},
        text: 'q',
        filter: const SymbolicFilter(typeNames: {'Concept'}),
        k: 5,
      ));

      expect(events.whereType<RetrievalConflict>(), isEmpty);
    });

    test('single contributing mode → no RetrievalConflict emitted',
        () async {
      final a1 = mintId();
      final a2 = mintId();
      final nodes = [a1, a2].map(makeNode).toList();
      final events = <MemoryEvent>[];

      // BM25 returns results; symbolic returns empty → only one
      // contributing mode; nothing to disagree with.
      final exec = build(
        bm25: fakeBm25([a1, a2]),
        symbolic: emptySymbolic(),
        nodeReader: makeReader(nodes),
        sink: events.add,
      );

      await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25, RecallMode.symbolic},
        text: 'q',
        filter: const SymbolicFilter(typeNames: {'Concept'}),
        k: 5,
      ));

      expect(events.whereType<RetrievalConflict>(), isEmpty);
    });

    test('all modes empty → no RetrievalConflict emitted', () async {
      final events = <MemoryEvent>[];
      final exec = build(
        nodeReader: makeReader(const []),
        sink: events.add,
      );
      await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25, RecallMode.symbolic},
        text: 'q',
        filter: const SymbolicFilter(typeNames: {'Concept'}),
        k: 5,
      ));
      expect(events.whereType<RetrievalConflict>(), isEmpty);
    });

    test('perModeK below 5 clamps the topK window', () async {
      final a1 = mintId();
      final a2 = mintId();
      final b1 = mintId();
      final nodes = [a1, a2, b1].map(makeNode).toList();
      final events = <MemoryEvent>[];

      final exec = build(
        bm25: fakeBm25([a1, a2]),
        symbolic: fakeSymbolic([b1]),
        nodeReader: makeReader(nodes),
        sink: events.add,
      );

      await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25, RecallMode.symbolic},
        text: 'q',
        filter: const SymbolicFilter(typeNames: {'Concept'}),
        k: 5,
        budget: const RecallBudget(perModeK: 2),
      ));

      final conflict = events.whereType<RetrievalConflict>().single;
      expect(conflict.topK, equals(2));
    });

    test('sink absent → no emission, no allocation', () async {
      final a1 = mintId();
      final b1 = mintId();
      final nodes = [a1, b1].map(makeNode).toList();

      // No sink wired — execute disjoint top-K and confirm the recall
      // pipeline still produces a result.
      final exec = RecallExecutor.fromCallables(
        bm25: fakeBm25([a1]),
        vector: emptyVector(),
        symbolic: fakeSymbolic([b1]),
        graphWalk: emptyGraphWalk(),
        nodeReader: makeReader(nodes),
        clock: MutableTestClock(BrainTime.utc(2026, 1, 1)),
      );
      final result = await exec.recall(RecallQuery(
        modes: const {RecallMode.bm25, RecallMode.symbolic},
        text: 'q',
        filter: const SymbolicFilter(typeNames: {'Concept'}),
        k: 5,
      ));
      expect(result.nodes, isNotEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 4. CritiqueRejected (agent-raised via ShakingEventEmitter)
  // ─────────────────────────────────────────────────────────────────

  group('A.69 CritiqueRejected (ShakingEventEmitter)', () {
    test('raise() dispatches to the wired sink', () {
      final events = <MemoryEvent>[];
      final emitter = ShakingEventEmitter(sink: events.add);

      final subject = NodeId.generate(
        at: DateTime.utc(2026, 5, 30),
        randomness: List<int>.generate(16, (i) => i),
      );

      final at = DateTime.utc(2026, 5, 30, 13);
      final ev = CritiqueRejected(
        subjectNodeId: subject,
        subjectTypeName: 'Conclusion',
        reason: 'evidence retracted',
        critic: 'dream_critique_v1:run-7',
        evidenceNodeIds: <NodeId>[subject],
        occurredAt: at,
        runId: 'r-7',
        causedBy: 'evt-1',
      );
      emitter.raise(ev);

      expect(events, hasLength(1));
      final out = events.single as CritiqueRejected;
      expect(out.subjectNodeId, equals(subject));
      expect(out.subjectTypeName, equals('Conclusion'));
      expect(out.reason, equals('evidence retracted'));
      expect(out.critic, equals('dream_critique_v1:run-7'));
      expect(out.evidenceNodeIds, hasLength(1));
      expect(out.runId, equals('r-7'));
      expect(out.causedBy, equals('evt-1'));
      expect(out.occurredAt, equals(at));
      expect(out.kind, equals('memory.shaking.critique-rejected'));
      expect(out.kind, startsWith(ShakingEvent.kindPrefix));

      final json = out.payloadJson();
      expect(json['subjectNodeId'], equals(subject.toString()));
      expect(json['subjectTypeName'], equals('Conclusion'));
      expect(json['reason'], equals('evidence retracted'));
      expect(json['critic'], equals('dream_critique_v1:run-7'));
      expect(json['evidenceNodeIds'], equals([subject.toString()]));
    });

    test('raise() with no sink is a silent no-op', () {
      // Construction without a sink (the bootstrap path before
      // SqliteTomBrainMemory lands) must not throw on raise. The
      // event is dropped on the floor; the emitter is a passthrough.
      const emitter = ShakingEventEmitter();
      final subject = NodeId.generate(
        at: DateTime.utc(2026, 5, 30),
        randomness: List<int>.generate(16, (i) => i + 1),
      );
      expect(
        () => emitter.raise(
          CritiqueRejected(
            subjectNodeId: subject,
            subjectTypeName: 'Claim',
            reason: 'no longer supported',
            occurredAt: DateTime.utc(2026, 5, 30, 13),
          ),
        ),
        returnsNormally,
      );
    });

    test('optional fields default to sensible values', () {
      final subject = NodeId.generate(
        at: DateTime.utc(2026, 5, 30),
        randomness: List<int>.generate(16, (i) => i + 2),
      );
      final ev = CritiqueRejected(
        subjectNodeId: subject,
        subjectTypeName: 'Claim',
        reason: 'r',
        occurredAt: DateTime.utc(2026, 5, 30, 13),
      );
      expect(ev.critic, isNull);
      expect(ev.evidenceNodeIds, isEmpty);
      expect(ev.runId, isNull);
      expect(ev.causedBy, isNull);

      final json = ev.payloadJson();
      expect(json.containsKey('critic'), isFalse);
      expect(json.containsKey('evidenceNodeIds'), isFalse);
    });
  });
}

// ─────────────────────────────────────────────────────────────────
// Test fixtures
// ─────────────────────────────────────────────────────────────────

/// Claim NodeTypeDecl that allows `contradicts` both outgoing and
/// incoming. The bootstrap YAML's Claim already does so; this is the
/// per-test fixture form so the test file does not depend on YAML
/// loader.
NodeTypeDecl _claimContradicts() => NodeTypeDecl(
      typeName: 'Claim',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'text': const FieldSpec(
          name: 'text',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['text'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'text'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 90 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{
        EdgeType.contradicts,
        EdgeType.derivedFrom,
      },
      allowedIncoming: const <EdgeType>{
        EdgeType.contradicts,
        EdgeType.derivedFrom,
      },
    );

/// Source NodeTypeDecl that accepts `derivedFrom` but NOT `contradicts`
/// — used in the negative test to assert that a rejected
/// `contradicts` edge does not emit `ContradictionDetected`.
NodeTypeDecl _sourceForDerived() => NodeTypeDecl(
      typeName: 'Source',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'url': const FieldSpec(
          name: 'url',
          type: FieldType.string,
          ftsEligible: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['url'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'url'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 365 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.evidenceFor},
      allowedIncoming: const <EdgeType>{EdgeType.derivedFrom},
    );

/// Deterministic 768-dim vector for persister fixtures (NodePersister
/// requires embeddings on types that declare them). Not used for the
/// drift maths.
Vec _v768({required int seed}) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Unit-ish 768-dim vector parameterised by seed. Used only where we
/// need *some* non-zero vector; the cosine-relevant tests use
/// [_axis768] which gives clean cosine values.
Vec _unit768({required int seed}) {
  final values = Float32List(768);
  values[seed % 768] = 1.0;
  values[(seed + 11) % 768] = 0.5;
  return Vec(values);
}

/// Basis vector along [axis] — `e_axis` in R^768. Two such vectors at
/// different axes are orthogonal, so `cosine(_axis768(0), _axis768(7))
/// = 0.0` — well below the 0.85 drift threshold and easy to assert
/// against without floating-point fuzz.
Vec _axis768({required int axis}) {
  final values = Float32List(768);
  values[axis % 768] = 1.0;
  return Vec(values);
}

/// VectorApplier that does nothing — used so NodePersister can persist
/// nodes that declare embedding policies without us caring about the
/// vector-side write.
final class _NoOpApplier implements VectorApplier {
  @override
  void apply(PendingVectorWrite write) {}
}
