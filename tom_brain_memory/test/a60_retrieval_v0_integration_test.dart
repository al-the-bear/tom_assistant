// A.60 — Retrieval v0 integration capstone.
//
// Plan step A.60:
//   "Tests: per-mode recall correctness on a seeded corpus; RRF rank-
//    stability under permutation; MMR diversity floor."
//
// A.54–A.59 already cover the unit-level properties:
//   * A.54 — Bm25Recall unit/integration against FTS5.
//   * A.55 — VectorRecall unit/integration against sqlite-vec / blob
//            backend.
//   * A.56 — SymbolicRecall + compiler unit/integration.
//   * A.57 — `rrfFuse` pure-function rank-stability under input
//            permutation (RecallMode-map ordering, tied-candidate
//            ordering).
//   * A.58 — `mmrDiversify` pure-function diversity floor (two-cluster
//            similarity test).
//   * A.59 — RecallExecutor dispatch / fusion / diversity / re-rank /
//            budget — using fake mode executors injected via
//            `RecallExecutor.fromCallables`.
//
// A.60 is the **integration capstone**: it wires the production
// constructor (`RecallExecutor({bm25:, vector:, symbolic:,
// nodeReader:})`) over a real in-memory SQLite + vectors-DB +
// FTS5-catalog + persister stack, seeds a deterministic corpus, and
// asserts the same three properties end-to-end:
//
//   1. Per-mode recall correctness on a seeded corpus — each of BM25,
//      vector, and symbolic, exercised through the full executor
//      pipeline, returns the nodes the seeded corpus says it should.
//   2. RRF rank-stability under permutation — at the integration level,
//      the executor visits modes in the order of the input
//      `Set<RecallMode>` but `rrfFuse` re-sorts modes by enum index
//      before scoring. The property: two semantically equivalent
//      queries that differ only in the iteration order of `modes`
//      produce identical fused node orderings. Re-running the same
//      query against the same DB also produces identical results
//      (deterministic execution).
//   3. MMR diversity floor — `DiversityStrategy.mmr` is a reordering
//      of the fused set, never a deletion: when `k >= |fused|`, the
//      MMR-on output and the MMR-off output cover the same node set.
//      MMR may reorder; it must not silently lose information.
//
// Conventions inherited from A.54 – A.59:
//   * In-memory SQLite for `memoryDb` + `vectorsDb`.
//   * `PlainBlobTableBackend` for the vector index (no native vec0
//     extension needed in test).
//   * `NodeId.generate(at:, randomness:)` for deterministic id mint.
//   * `FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0))` everywhere —
//     elapsed time is 0 and the budget check never trips (the
//     executor's budget compare is strict `>`; 0 > 0 is false).
//   * `Fts5Catalog` + `Fts5Writer` for FTS5 provisioning + row writes.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, FixedClock, NodeId, Vec;

void main() {
  group('A.60 retrieval v0 integration capstone', () {
    late Database memoryDb;
    late Database vectorsDb;
    late VectorTable vectorTable;
    late VectorTableApplier vectorApplier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late Bm25Recall bm25;
    late VectorRecall vector;
    late SymbolicRecall symbolic;
    late NodeReader nodeReader;
    late RecallExecutor executor;
    late int idCounter;
    late DateTime fakeNow;

    NodeId mintId() {
      idCounter += 1;
      final randomness = List<int>.generate(16, (i) => (idCounter + i) & 31);
      return NodeId.generate(at: fakeNow, randomness: randomness);
    }

    setUp(() async {
      memoryDb = sqlite3.openInMemory();
      vectorsDb = sqlite3.openInMemory();
      applySchemaV1(memoryDb);

      final fixedClock = FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0));
      vectorTable = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: fixedClock,
      );
      vectorTable.installIndex(modelId: 'nomic-embed-text@v1.5', dims: 768);
      vectorApplier = VectorTableApplier(vectorTable: vectorTable);
      coordinator = TwoDbCoordinator(
        memoryDb: memoryDb,
        applier: vectorApplier,
        clock: fixedClock,
      );

      idCounter = 0;
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

      const catalog = Fts5Catalog();
      registry = NodeTypeRegistry(
        memoryDb: memoryDb,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
        ftsCatalog: catalog,
      );
      await registry.registerNodeType(_claimType());
      await registry.registerNodeType(_questionType());

      persister = NodePersister(
        memoryDb: memoryDb,
        coordinator: coordinator,
        registry: registry,
        idMint: mintId,
        now: () => fakeNow,
        ftsWriter: const Fts5Writer(catalog: catalog),
      );

      bm25 = Bm25Recall(
        memoryDb: memoryDb,
        registry: registry,
        catalog: catalog,
      );
      vector = VectorRecall(
        memoryDb: memoryDb,
        registry: registry,
        vectorTable: vectorTable,
      );
      symbolic = SymbolicRecall(memoryDb: memoryDb);
      nodeReader = NodeReader(memoryDb: memoryDb);

      executor = RecallExecutor(
        bm25: bm25,
        vector: vector,
        symbolic: symbolic,
        nodeReader: nodeReader,
        clock: fixedClock,
      );
    });

    tearDown(() {
      memoryDb.dispose();
      vectorsDb.dispose();
    });

    // ─── Property 1: per-mode recall correctness ────────────────────

    group('per-mode recall correctness on a seeded corpus', () {
      test('BM25 mode returns the matching node through the executor',
          () async {
        final alpha = await _persistClaim(
          persister: persister,
          text: 'alpha bravo charlie distinctive',
          confidence: 0.9,
          key: 'k-alpha',
        );
        await _persistClaim(
          persister: persister,
          text: 'completely unrelated content',
          confidence: 0.1,
          key: 'k-unrelated',
        );

        final result = await executor.recall(RecallQuery(
          modes: const {RecallMode.bm25},
          text: 'distinctive',
          k: 10,
        ));
        expect(result.nodes, isNotEmpty);
        expect(result.nodes.first.id, equals(alpha));
        expect(result.report.degraded, isFalse);
        expect(result.report.candidatesPerMode[RecallMode.bm25], 1);
      });

      test('vector mode returns the embedded match through the executor',
          () async {
        final queryVec = _v768(seed: 7);
        final exact = await persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: const <String, Object?>{
              'text': 'exact embedding match',
              'confidence': 0.5,
            },
            embedding: queryVec,
          ),
          scope: const Scope(producer: 'p', idempotencyKey: 'k-exact'),
        );
        await persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: const <String, Object?>{
              'text': 'far embedding',
              'confidence': 0.5,
            },
            embedding: _v768(seed: 800),
          ),
          scope: const Scope(producer: 'p', idempotencyKey: 'k-far'),
        );

        final result = await executor.recall(RecallQuery(
          modes: const {RecallMode.vector},
          embedding: queryVec,
          k: 10,
        ));
        expect(result.nodes, isNotEmpty);
        expect(result.nodes.first.id, equals(exact));
        expect(result.report.degraded, isFalse);
      });

      test('symbolic mode returns the attribute-matching node through the '
          'executor', () async {
        final target = await _persistClaim(
          persister: persister,
          text: 'attribute match here',
          confidence: 0.95,
          key: 'k-target',
        );
        await _persistClaim(
          persister: persister,
          text: 'attribute miss here',
          confidence: 0.42,
          key: 'k-miss',
        );

        final result = await executor.recall(RecallQuery(
          modes: const {RecallMode.symbolic},
          filter: const SymbolicFilter(
            attributes: <AttrClause>[
              AttrClause('confidence', SymbolicOp.eq, 0.95),
            ],
          ),
          k: 10,
        ));
        final ids = result.nodes.map((n) => n.id).toSet();
        expect(ids, contains(target));
        expect(result.report.degraded, isFalse);
      });

      test('multi-mode (bm25 + vector + symbolic) merges all three '
          'sources', () async {
        // A single claim that should be hit by every mode at once.
        final allThree = await persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: const <String, Object?>{
              'text': 'tripleword anchor here',
              'confidence': 0.77,
            },
            embedding: _v768(seed: 33),
          ),
          scope: const Scope(producer: 'p', idempotencyKey: 'k-triple'),
        );
        // A noise row that only BM25 should pick up.
        await persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: const <String, Object?>{
              'text': 'tripleword noise',
              'confidence': 0.1,
            },
            embedding: _v768(seed: 500),
          ),
          scope: const Scope(producer: 'p', idempotencyKey: 'k-noise'),
        );

        final result = await executor.recall(RecallQuery(
          modes: const {
            RecallMode.bm25,
            RecallMode.vector,
            RecallMode.symbolic,
          },
          text: 'tripleword',
          embedding: _v768(seed: 33),
          filter: const SymbolicFilter(
            attributes: <AttrClause>[
              AttrClause('confidence', SymbolicOp.eq, 0.77),
            ],
          ),
          k: 10,
        ));
        // The triple-hit row appears in every per-mode list and so must
        // dominate the RRF fusion → top of the final node list.
        expect(result.nodes, isNotEmpty);
        expect(result.nodes.first.id, equals(allThree));
        expect(
          result.report.candidatesPerMode.keys.toSet(),
          {RecallMode.bm25, RecallMode.vector, RecallMode.symbolic},
        );
        expect(result.report.degraded, isFalse);
      });
    });

    // ─── Property 2: RRF rank-stability under permutation ───────────

    group('RRF rank-stability under permutation', () {
      test('the same query against the same DB returns identical results',
          () async {
        await _seedSmallMixedCorpus(persister);

        final query = RecallQuery(
          modes: const {RecallMode.bm25, RecallMode.symbolic},
          text: 'stableword',
          filter: const SymbolicFilter(typeNames: <String>{'Claim'}),
          k: 10,
        );
        final first = await executor.recall(query);
        final second = await executor.recall(query);
        final third = await executor.recall(query);
        final firstIds = first.nodes.map((n) => n.id.value).toList();
        final secondIds = second.nodes.map((n) => n.id.value).toList();
        final thirdIds = third.nodes.map((n) => n.id.value).toList();
        expect(secondIds, equals(firstIds));
        expect(thirdIds, equals(firstIds));
      });

      test('permuting the mode-Set iteration order yields the same fused '
          'ranking', () async {
        await _seedSmallMixedCorpus(persister);

        final queryVec = _v768(seed: 13);
        // Two literally distinct sets with the same members in different
        // iteration order. The executor visits modes in the set's
        // iteration order, but `rrfFuse` re-sorts modes by enum index
        // before scoring (rrf.dart sort: `modes..sort((a,b) =>
        // a.index.compareTo(b.index))`) — so the final fused ranking is
        // invariant under any permutation of the input mode set.
        final ordered = await executor.recall(RecallQuery(
          modes: const {
            RecallMode.bm25,
            RecallMode.vector,
            RecallMode.symbolic,
          },
          text: 'stableword',
          embedding: queryVec,
          filter: const SymbolicFilter(typeNames: <String>{'Claim'}),
          k: 10,
        ));
        final permuted = await executor.recall(RecallQuery(
          modes: const {
            RecallMode.symbolic,
            RecallMode.bm25,
            RecallMode.vector,
          },
          text: 'stableword',
          embedding: queryVec,
          filter: const SymbolicFilter(typeNames: <String>{'Claim'}),
          k: 10,
        ));
        final orderedIds =
            ordered.nodes.map((n) => n.id.value).toList();
        final permutedIds =
            permuted.nodes.map((n) => n.id.value).toList();
        expect(permutedIds, equals(orderedIds));
      });

      test('per-mode candidate counts are independent of mode-Set '
          'iteration order', () async {
        await _seedSmallMixedCorpus(persister);

        final queryVec = _v768(seed: 13);
        final ordered = await executor.recall(RecallQuery(
          modes: const {RecallMode.bm25, RecallMode.symbolic},
          text: 'stableword',
          filter: const SymbolicFilter(typeNames: <String>{'Claim'}),
          embedding: queryVec,
          k: 10,
        ));
        final permuted = await executor.recall(RecallQuery(
          modes: const {RecallMode.symbolic, RecallMode.bm25},
          text: 'stableword',
          filter: const SymbolicFilter(typeNames: <String>{'Claim'}),
          embedding: queryVec,
          k: 10,
        ));
        expect(
          permuted.report.candidatesPerMode,
          equals(ordered.report.candidatesPerMode),
        );
      });
    });

    // ─── Property 3: MMR diversity floor ────────────────────────────

    group('MMR diversity floor', () {
      test('MMR is a reordering of the fused set when k >= |fused| — '
          'never a silent deletion', () async {
        // Seed a redundant corpus: five Claim rows that all match a
        // shared token. RRF returns all five; MMR-on must select the
        // same five (in some order), MMR-off returns them in fused
        // relevance order.
        final seededIds = <NodeId>[];
        for (var i = 0; i < 5; i++) {
          seededIds.add(
            await _persistClaim(
              persister: persister,
              text: 'redundantword anchor row-$i',
              confidence: 0.5,
              key: 'k-red-$i',
            ),
          );
        }

        Future<List<NodeId>> runWith(DiversityStrategy strat) async {
          final result = await executor.recall(RecallQuery(
            modes: const {RecallMode.bm25},
            text: 'redundantword',
            diversity: DiversityPolicy(strategy: strat),
            k: 10,
          ));
          return result.nodes.map((n) => n.id).toList();
        }

        final off = await runWith(DiversityStrategy.off);
        final mmr = await runWith(DiversityStrategy.mmr);
        // Diversity floor: MMR and off cover the same node set when
        // k >= |fused|. The order may differ; the membership must not.
        expect(mmr.toSet(), equals(off.toSet()));
        expect(mmr.toSet(), equals(seededIds.toSet()));
        // And MMR must not silently produce duplicates.
        expect(mmr.length, equals(mmr.toSet().length));
      });

      test('MMR truncation at k <= |fused| preserves the diversity-first '
          'pick semantics', () async {
        // Seed five hits with monotonically increasing BM25 scores
        // (more repetitions of the shared token → lower bm25 raw score
        // → more relevant under FTS5). With `k = 2`, MMR's first pick
        // is the highest-relevance row (lambda=0.7 dominates when
        // selected is empty), the second pick balances relevance with
        // (1 - lambda) * max-sim-to-selected. The non-floor property
        // we check here is the minimal one: the result is a non-empty
        // subset of the seeded ids, in deterministic order.
        final seededIds = <NodeId>[];
        for (var i = 0; i < 5; i++) {
          final text = ('floorword ' * (i + 1)).trim();
          seededIds.add(
            await _persistClaim(
              persister: persister,
              text: text,
              confidence: 0.5,
              key: 'k-floor-$i',
            ),
          );
        }

        final result = await executor.recall(RecallQuery(
          modes: const {RecallMode.bm25},
          text: 'floorword',
          diversity: const DiversityPolicy(strategy: DiversityStrategy.mmr),
          k: 2,
        ));
        expect(result.nodes, hasLength(2));
        // Every returned node is one of the seeded ids (no leakage).
        final returnedSet = result.nodes.map((n) => n.id).toSet();
        expect(returnedSet.difference(seededIds.toSet()), isEmpty);
        // And the result is deterministic across re-runs.
        final again = await executor.recall(RecallQuery(
          modes: const {RecallMode.bm25},
          text: 'floorword',
          diversity: const DiversityPolicy(strategy: DiversityStrategy.mmr),
          k: 2,
        ));
        expect(
          again.nodes.map((n) => n.id.value).toList(),
          equals(result.nodes.map((n) => n.id.value).toList()),
        );
      });

      test('MMR report carries the lambda; off does not', () async {
        await _persistClaim(
          persister: persister,
          text: 'lambdaword anchor',
          confidence: 0.5,
          key: 'k-lambda',
        );

        final mmrResult = await executor.recall(RecallQuery(
          modes: const {RecallMode.bm25},
          text: 'lambdaword',
          diversity: const DiversityPolicy(lambda: 0.42),
          k: 5,
        ));
        expect(mmrResult.report.diversityStrategy, DiversityStrategy.mmr);
        expect(mmrResult.report.diversityLambda, 0.42);

        final offResult = await executor.recall(RecallQuery(
          modes: const {RecallMode.bm25},
          text: 'lambdaword',
          diversity: const DiversityPolicy(strategy: DiversityStrategy.off),
          k: 5,
        ));
        expect(offResult.report.diversityStrategy, DiversityStrategy.off);
        expect(offResult.report.diversityLambda, isNull);
      });
    });
  });
}

// ─── Helpers ────────────────────────────────────────────────────

/// Seeds a small mixed corpus used by the rank-stability group. Two
/// Claims share the `stableword` token; a third Claim is noise; one
/// Question (different type) shares the token but is excluded by the
/// `typeNames: {Claim}` filter so the symbolic + bm25 lists do not
/// agree perfectly and RRF has to actually fuse non-trivial inputs.
Future<void> _seedSmallMixedCorpus(NodePersister persister) async {
  await _persistClaim(
    persister: persister,
    text: 'stableword anchor primary',
    confidence: 0.9,
    key: 'k-stable-a',
  );
  await _persistClaim(
    persister: persister,
    text: 'stableword secondary',
    confidence: 0.5,
    key: 'k-stable-b',
  );
  await _persistClaim(
    persister: persister,
    text: 'unrelated noise',
    confidence: 0.1,
    key: 'k-noise',
  );
  await _persistQuestion(
    persister: persister,
    prompt: 'stableword tangent question',
    priority: 1,
    key: 'k-stable-q',
  );
}

Future<NodeId> _persistClaim({
  required NodePersister persister,
  required String text,
  required double confidence,
  required String key,
}) {
  return persister.persist(
    NodeDraft(
      typeName: 'Claim',
      values: <String, Object?>{'text': text, 'confidence': confidence},
      embedding: _v768(seed: key.hashCode & 0xff),
    ),
    scope: Scope(producer: 'test', idempotencyKey: key),
  );
}

Future<NodeId> _persistQuestion({
  required NodePersister persister,
  required String prompt,
  required int priority,
  required String key,
}) {
  return persister.persist(
    NodeDraft(
      typeName: 'Question',
      values: <String, Object?>{'prompt': prompt, 'priority': priority},
      embedding: _v768(seed: key.hashCode & 0xff),
    ),
    scope: Scope(producer: 'test', idempotencyKey: key),
  );
}

NodeTypeDecl _claimType() => NodeTypeDecl(
      typeName: 'Claim',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'text': const FieldSpec(
          name: 'text',
          type: FieldType.string,
          ftsEligible: true,
        ),
        'confidence': const FieldSpec(
          name: 'confidence',
          type: FieldType.json,
          nullable: true,
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
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{EdgeType.evidenceFor},
    );

NodeTypeDecl _questionType() => NodeTypeDecl(
      typeName: 'Question',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'prompt': const FieldSpec(
          name: 'prompt',
          type: FieldType.string,
          ftsEligible: true,
        ),
        'priority': const FieldSpec(
          name: 'priority',
          type: FieldType.integer,
          nullable: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['prompt'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'prompt'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 365 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.motivates},
      allowedIncoming: const <EdgeType>{EdgeType.satisfiedBy},
    );

Vec _v768({required int seed}) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}
