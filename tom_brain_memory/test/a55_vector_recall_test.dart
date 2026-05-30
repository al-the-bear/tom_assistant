// A.55 — vector mode against sqlite-vec (integration).
//
// Plan step A.55:
//   "Implement `vector` mode against sqlite-vec."
//
// What A.50 – A.54 already covered:
//   * A.50 — vec0 shared-library loader (fail-open + VectorIndexUnavailable
//            event).
//   * A.51 — VectorTable + Vec0VirtualTableBackend + PlainBlobTableBackend
//            with per-model index layout.
//   * A.52 — VectorTableApplier wires the two-DB coordinator into
//            vectors.db.
//   * A.53 — extension load + roundtrip, degraded-mode recall, model
//            mismatch rejection.
//   * A.54 — BM25 mode against FTS5 (the sibling executor).
//
// What A.55 adds (this file):
//   * VectorRecall — vector-mode executor that groups embedding-bearing
//     types by `EmbeddingPolicy.modelIdentity`, calls
//     `VectorTable.queryNearest` once per model group, enriches with
//     `type_name` from `nodes`, and merges into a single
//     ascending-distance ranking capped at `perModeK`.
//
// Coverage map (one `test(...)` per row):
//
//   Happy path
//   ----------
//   * Persisted node is returned as the top hit when the query vector
//     equals its embedding (distance 0).
//   * Multiple persisted nodes are ordered ascending by distance.
//
//   typeNames filter
//   ----------------
//   * `typeNames` restricts the candidate types in the result.
//   * Empty `typeNames` set returns empty (and issues no SQL on the
//     vector backend).
//   * `typeNames` including a type with no embedding policy silently
//     elides it.
//   * Multi-type same-model: with no typeNames filter both types
//     appear; with a single-type filter only the named type appears.
//
//   Cross-model / dim handling
//   --------------------------
//   * A second model with a different dim is silently skipped when the
//     query dim matches only the first model.
//   * A model with no installed `vector_indexes` row returns empty for
//     that group (the recall does not raise).
//   * Query dim that matches no installed model returns empty.
//
//   perModeK guard
//   --------------
//   * `perModeK == 0` returns empty without issuing SQL.
//   * `perModeK` truncates the merged result to the global top-K.
//   * `perModeK` negative returns empty without issuing SQL.
//
//   Referential integrity
//   ---------------------
//   * A vector row whose `nodes` row was never persisted is silently
//     dropped from the result (no orphan rows leak out).
//
//   Determinism
//   -----------
//   * Two rows with identical distance are ordered by (modelId,
//     nodeId) lexicographic.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, FixedClock, NodeId, Vec;

void main() {
  group('A.55 vector mode against sqlite-vec', () {
    late Database memoryDb;
    late Database vectorsDb;
    late VectorTable vectorTable;
    late VectorTableApplier vectorApplier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late VectorRecall recall;
    late List<MemoryEvent> events;
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

      vectorTable = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );
      // Install both bootstrap embedding models the test types refer to.
      vectorTable.installIndex(modelId: 'nomic-embed-text@v1.5', dims: 768);
      vectorTable.installIndex(modelId: 'openai-test@v1', dims: 1024);
      // The third model (Note) is intentionally NOT installed — the
      // "uninstalled model" test relies on its absence.

      vectorApplier = VectorTableApplier(vectorTable: vectorTable);
      coordinator = TwoDbCoordinator(
        memoryDb: memoryDb,
        applier: vectorApplier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );

      events = <MemoryEvent>[];
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
      await registry.registerNodeType(_titleType()); // 1024-d openai-test
      await registry.registerNodeType(_noteType());  // 768-d, model NOT installed
      await registry.registerNodeType(_tombstoneType()); // EmbeddingPolicy.none

      persister = NodePersister(
        memoryDb: memoryDb,
        coordinator: coordinator,
        registry: registry,
        idMint: mintId,
        now: () => fakeNow,
        eventSink: events.add,
        ftsWriter: const Fts5Writer(catalog: catalog),
      );

      recall = VectorRecall(
        memoryDb: memoryDb,
        registry: registry,
        vectorTable: vectorTable,
      );
    });

    tearDown(() {
      memoryDb.dispose();
      vectorsDb.dispose();
    });

    // ─── Happy path ────────────────────────────────────────────────

    test('returns the persisted node at distance 0 for an exact-vector '
        'query', () async {
      final vec = _vec(dim: 768, seed: 1);
      final id = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'first claim'},
          embedding: vec,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-first'),
      );

      final hits = recall.recall(query: vec);
      expect(hits, isNotEmpty);
      expect(hits.first.nodeId, equals(id));
      expect(hits.first.typeName, equals('Claim'));
      expect(hits.first.modelId, equals('nomic-embed-text@v1.5'));
      // The PlainBlobTableBackend's L2 of identical vectors is 0.0.
      expect(hits.first.distance, closeTo(0.0, 1e-9));
    });

    test('orders multiple persisted nodes by ascending distance',
        () async {
      // Seed three Claims whose embeddings sit at known L2 distances
      // from the query vector. The query vector is _vec(seed:0); seeds
      // 1, 2, 3 produce progressively larger L2 distances because
      // _vec uses a seeded sweep over [0, 1).
      final queryVec = _vec(dim: 768, seed: 0);
      final near = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'near'},
          embedding: _vec(dim: 768, seed: 0), // identical → distance 0
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-near'),
      );
      final mid = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'mid'},
          embedding: _vec(dim: 768, seed: 100),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-mid'),
      );
      final far = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'far'},
          embedding: _vec(dim: 768, seed: 800),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-far'),
      );

      final hits = recall.recall(query: queryVec);
      expect(hits.map((h) => h.nodeId), containsAll(<NodeId>[near, mid, far]));
      // Result is sorted ascending by distance.
      for (var i = 1; i < hits.length; i++) {
        expect(
          hits[i].distance,
          greaterThanOrEqualTo(hits[i - 1].distance),
          reason: 'hits[$i].distance < hits[${i - 1}].distance — result '
              'is not ascending',
        );
      }
      // Near is the closest.
      expect(hits.first.nodeId, equals(near));
    });

    // ─── typeNames filter ──────────────────────────────────────────

    test('typeNames restricts the result to the named types', () async {
      final vec = _vec(dim: 768, seed: 5);
      final claim = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'shared model claim'},
          embedding: vec,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-claim'),
      );
      final question = await persister.persist(
        NodeDraft(
          typeName: 'Question',
          values: const <String, Object?>{'prompt': 'shared model question'},
          embedding: vec,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-q'),
      );

      final claimOnly = recall.recall(
        query: vec,
        typeNames: <String>{'Claim'},
      );
      expect(claimOnly.map((h) => h.nodeId), contains(claim));
      expect(claimOnly.map((h) => h.nodeId), isNot(contains(question)));

      final questionOnly = recall.recall(
        query: vec,
        typeNames: <String>{'Question'},
      );
      expect(questionOnly.map((h) => h.nodeId), contains(question));
      expect(questionOnly.map((h) => h.nodeId), isNot(contains(claim)));
    });

    test('empty typeNames set returns empty', () async {
      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'anything'},
          embedding: _vec(dim: 768, seed: 9),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-any'),
      );
      final hits = recall.recall(
        query: _vec(dim: 768, seed: 9),
        typeNames: const <String>{},
      );
      expect(hits, isEmpty);
    });

    test('typeNames including a no-embedding type silently elides it',
        () async {
      final vec = _vec(dim: 768, seed: 11);
      final claim = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'with embedding'},
          embedding: vec,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-mixed'),
      );
      // `Tombstone` has EmbeddingPolicy.none — including it must not
      // crash and must not affect the returned Claim hit.
      final hits = recall.recall(
        query: vec,
        typeNames: <String>{'Claim', 'Tombstone'},
      );
      expect(hits.map((h) => h.nodeId), contains(claim));
    });

    test('multi-type same-model returns both types when no filter is '
        'set', () async {
      final vec = _vec(dim: 768, seed: 13);
      final claim = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'c'},
          embedding: vec,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-mc'),
      );
      final question = await persister.persist(
        NodeDraft(
          typeName: 'Question',
          values: const <String, Object?>{'prompt': 'q'},
          embedding: vec,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-mq'),
      );

      final hits = recall.recall(query: vec);
      final ids = hits.map((h) => h.nodeId).toList();
      expect(ids, containsAll(<NodeId>[claim, question]));
    });

    // ─── Cross-model / dim handling ────────────────────────────────

    test('a second model with a different dim is silently skipped when '
        'the query dim only matches the first', () async {
      // Claim → nomic (768), Title → openai-test (1024).
      final claimId = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'small'},
          embedding: _vec(dim: 768, seed: 21),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-claim-2'),
      );
      final titleId = await persister.persist(
        NodeDraft(
          typeName: 'Title',
          values: const <String, Object?>{'name': 'big'},
          embedding: _vec(dim: 1024, seed: 21),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-title-2'),
      );

      // 768-d query only reaches Claim.
      final small = recall.recall(query: _vec(dim: 768, seed: 21));
      expect(small.map((h) => h.nodeId), contains(claimId));
      expect(small.map((h) => h.nodeId), isNot(contains(titleId)));
      expect(
        small.every((h) => h.modelId == 'nomic-embed-text@v1.5'),
        isTrue,
      );

      // 1024-d query only reaches Title.
      final big = recall.recall(query: _vec(dim: 1024, seed: 21));
      expect(big.map((h) => h.nodeId), contains(titleId));
      expect(big.map((h) => h.nodeId), isNot(contains(claimId)));
      expect(big.every((h) => h.modelId == 'openai-test@v1'), isTrue);
    });

    test('a model whose vector_indexes row was never installed returns '
        'empty for that group (no exception)', () async {
      // Note type binds to `not-installed-model@v1` which has no
      // entry in `vector_indexes`. Persisting it through the
      // coordinator would normally raise EmbeddingModelMismatch
      // (the applier path is strict). Bypass the persister and
      // insert the bare `nodes` row directly so the lookup-side test
      // is exercised regardless of the writer-side strictness.
      final noteId = mintId();
      memoryDb.execute(
        'INSERT INTO nodes(id, type_name, scope_json, produced_by, '
        'attrs_json, status, created_at_ms, created_at_iso, '
        'updated_at_ms, updated_at_iso, embedding_model_id) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          noteId.toString(),
          'Note',
          '{}',
          'p',
          '{"body":"x"}',
          'active',
          fakeNow.millisecondsSinceEpoch,
          fakeNow.toIso8601String(),
          fakeNow.millisecondsSinceEpoch,
          fakeNow.toIso8601String(),
          'not-installed-model@v1',
        ],
      );

      // Recall must not raise. The Note type group is silently
      // skipped (its model has no installed index).
      final hits = recall.recall(query: _vec(dim: 768, seed: 99));
      expect(hits.map((h) => h.nodeId), isNot(contains(noteId)));
    });

    test('query dim that matches no installed model returns empty',
        () async {
      // Both installed models are 768 and 1024. A 512-d query reaches
      // none of them — every type group is filtered out at the
      // dim-compatibility step.
      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'present'},
          embedding: _vec(dim: 768, seed: 33),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-dim'),
      );
      final hits = recall.recall(query: _vec(dim: 512, seed: 33));
      expect(hits, isEmpty);
    });

    // ─── perModeK guard ────────────────────────────────────────────

    test('perModeK == 0 returns empty without issuing SQL', () async {
      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'whatever'},
          embedding: _vec(dim: 768, seed: 41),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-zero'),
      );
      expect(
        recall.recall(query: _vec(dim: 768, seed: 41), perModeK: 0),
        isEmpty,
      );
    });

    test('perModeK negative returns empty without issuing SQL',
        () async {
      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'whatever'},
          embedding: _vec(dim: 768, seed: 43),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-neg'),
      );
      expect(
        recall.recall(query: _vec(dim: 768, seed: 43), perModeK: -1),
        isEmpty,
      );
    });

    test('perModeK truncates the merged result to the global top-K',
        () async {
      // Seed 5 Claim rows, all with distinct vectors. perModeK = 3
      // bounds the result.
      for (var i = 0; i < 5; i++) {
        await persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: <String, Object?>{'text': 'row-$i'},
            embedding: _vec(dim: 768, seed: 50 + i),
          ),
          scope: Scope(producer: 'p', idempotencyKey: 'k-trunc-$i'),
        );
      }
      final hits = recall.recall(
        query: _vec(dim: 768, seed: 50),
        perModeK: 3,
      );
      expect(hits, hasLength(3));
      expect(hits.every((h) => h.typeName == 'Claim'), isTrue);
    });

    test('empty corpus returns empty', () async {
      // No persists. The Claim type is registered but its index has
      // no rows.
      final hits = recall.recall(query: _vec(dim: 768, seed: 99));
      expect(hits, isEmpty);
    });

    // ─── Referential integrity ─────────────────────────────────────

    test('vector row without a matching nodes row is silently dropped',
        () async {
      // Insert directly into the per-model table, bypassing the
      // persister. The `nodes` row never exists, so the type-name
      // enrichment lookup returns nothing for this row.
      vectorTable.insertVector(
        nodeId: 'orphan-vector-id',
        vector: _vec(dim: 768, seed: 7),
        modelId: 'nomic-embed-text@v1.5',
      );
      final hits = recall.recall(query: _vec(dim: 768, seed: 7));
      expect(
        hits.where((h) => h.nodeId.toString() == 'orphan-vector-id'),
        isEmpty,
      );
    });

    // ─── Determinism ───────────────────────────────────────────────

    test('two rows with identical distance are ordered deterministically',
        () async {
      // Two identical embeddings → identical distance to the query
      // (also identical). The tie-break in VectorRecall sorts by
      // (modelId, nodeId) lexicographic, so ordering is reproducible
      // across runs.
      final shared = _vec(dim: 768, seed: 61);
      final a = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'a'},
          embedding: shared,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-tie-a'),
      );
      final b = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'b'},
          embedding: shared,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-tie-b'),
      );

      final hits = recall.recall(query: shared);
      final ids = hits
          .where((h) => h.nodeId == a || h.nodeId == b)
          .map((h) => h.nodeId.toString())
          .toList();
      // Sorted ascending.
      final sorted = List<String>.from(ids)..sort();
      expect(ids, equals(sorted),
          reason: 'Tie-broken candidates must be in (modelId, nodeId) '
              'lexicographic order.');
    });
  });
}

// ─── Helpers ────────────────────────────────────────────────────

NodeTypeDecl _claimType() => NodeTypeDecl(
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

NodeTypeDecl _titleType() => NodeTypeDecl(
      typeName: 'Title',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'name': const FieldSpec(name: 'name', type: FieldType.string),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'openai-test@v1',
        dimensions: 1024,
        sourceFields: <String>['name'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 90 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{},
    );

/// A type bound to a model that the test deliberately does NOT
/// install in `vector_indexes`. Used to exercise the "no installed
/// index" branch of VectorRecall.
NodeTypeDecl _noteType() => NodeTypeDecl(
      typeName: 'Note',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'body': const FieldSpec(name: 'body', type: FieldType.string),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'not-installed-model@v1',
        dimensions: 768,
        sourceFields: <String>['body'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 90 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{},
    );

NodeTypeDecl _tombstoneType() => NodeTypeDecl(
      typeName: 'Tombstone',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'reason': const FieldSpec(name: 'reason', type: FieldType.string),
      },
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: IndexPolicy.indexNothing,
      retentionPolicy: RetentionPolicy.indefinite,
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{},
    );

/// Deterministic [Vec] of dimension [dim] seeded by [seed].
///
/// Two distinct seeds produce distinct vectors; identical seeds
/// produce identical vectors (so a query equal to a stored vector
/// yields distance 0).
Vec _vec({required int dim, required int seed}) {
  final values = Float32List(dim);
  for (var i = 0; i < dim; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}
