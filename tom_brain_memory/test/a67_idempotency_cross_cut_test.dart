// A.67 — `Scope.idempotencyKey` enforcement across `persist` and
// `edge`.
//
// The persist side already grew idempotency at A.34
// (`NodePersister._lookupByIdempotencyKey`); the edge side picks up
// the same contract here (closes Q-A.36.2 producer-attribution while
// it's at it).
//
// The agent-infrastructure step makes the property cross-cutting:
// dreaming agents (Extractor, Connector, Synthesizer, …) commit
// their findings as `persist` + `edge` pairs under a *single shared*
// idempotency key prefix (`<agent>:<scope>:<source-id>`). When an
// agent run is interrupted and resumed, the second run must end up
// with exactly the same nodes and exactly the same edges as the
// first — no duplicates, no orphans, no events emitted twice.
//
// What this test exercises (one `test(...)` per row):
//
//   Persist idempotency (smoke; full coverage lives in
//   `node_persister_test.dart`)
//   --------------------------------------------------
//   * Repeat persist with the same key returns the same NodeId,
//     emits no second event, leaves a single row.
//
//   Edge idempotency (the A.67 addition)
//   ------------------------------------
//   * Repeat edge with the same key returns the same EdgeId, emits
//     no second `EdgeCreated`, leaves a single row in `edges`.
//   * Different idempotency keys produce distinct EdgeIds even when
//     endpoints and label match (multi-graph still allowed).
//   * Null idempotency key never collides — two edges with null
//     keys produce two rows (mirrors the partial-unique index).
//   * The second call's `weight` and `attrs` are NOT re-applied —
//     idempotency keys deduplicate by key alone, not by payload.
//   * `produced_by` records `scope.producer` on the first call;
//     the column survives the dedup of a second call.
//
//   Combined replay (the real cross-cut)
//   ------------------------------------
//   * A simulated extractor run that persists a Claim and links it
//     `evidence_for` an existing Source under stable keys can be
//     replayed end-to-end: the second run returns the same
//     `(NodeId, EdgeId)` pair, leaves exactly one row in each
//     table, and emits no duplicate events.
//
//   DB-level integrity
//   ------------------
//   * Hand-rolling a duplicate `idempotency_key` directly into the
//     `edges` table is rejected by `uniq_edges_idempotency_key`.
//     This guards against any future caller that bypasses
//     `EdgeWriter`.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, EdgeId, FixedClock, NodeId, Vec;

/// Module-level scope used by the helper `persistClaim` / `persistSource`
/// fixtures. Idempotency keys are supplied per test via overrides; the
/// producer string just needs to be stable.
const _fixtureScope = Scope.nonIdempotent(producer: 'a67-fixtures');

void main() {
  group('A.67 Scope.idempotencyKey cross-cut', () {
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late EdgeWriter writer;
    late List<MemoryEvent> events;
    late int nodeIdCounter;
    late int edgeIdCounter;
    late DateTime fakeNow;

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
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      applier = _RecordingVectorApplier();
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );
      events = <MemoryEvent>[];
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
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      await registry.registerNodeType(_validClaim());
      await registry.registerNodeType(_validSource());
      await registry.registerNodeType(_validConclusion());

      // Persister and writer share the event sink so the test can
      // observe the full event stream of a simulated agent run.
      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
        eventSink: events.add,
      );
      writer = EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
        eventSink: events.add,
      );
    });

    tearDown(() => db.dispose());

    Future<NodeId> persistClaim(String text, {String? idemKey}) {
      final scope = idemKey == null
          ? _fixtureScope
          : Scope(producer: 'a67-fixtures', idempotencyKey: idemKey);
      return persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: <String, Object?>{'text': text},
          embedding: _v768(seed: text.hashCode),
        ),
        scope: scope,
      );
    }

    Future<NodeId> persistSource(String url, {String? idemKey}) {
      final scope = idemKey == null
          ? _fixtureScope
          : Scope(producer: 'a67-fixtures', idempotencyKey: idemKey);
      return persister.persist(
        NodeDraft(
          typeName: 'Source',
          values: <String, Object?>{'url': url},
          embedding: _v768(seed: url.hashCode + 7),
        ),
        scope: scope,
      );
    }

    int edgeCount() =>
        db.select('SELECT COUNT(*) AS n FROM edges').first['n'] as int;

    int nodeCount() =>
        db.select('SELECT COUNT(*) AS n FROM nodes WHERE '
                "type_name IN ('Claim','Source','Conclusion')")
            .first['n'] as int;

    // ─── Persist idempotency smoke (full coverage in A.34) ───────────

    test('repeat persist with same idempotency key returns same NodeId',
        () async {
      events.clear();
      final first = await persistClaim('observation', idemKey: 'k-claim-A');
      final eventsAfterFirst = events.length;

      final second = await persistClaim('different text', idemKey: 'k-claim-A');

      expect(second, equals(first),
          reason: 'spec § 9.1: key alone deduplicates, regardless of payload');
      expect(nodeCount(), equals(1));
      expect(events.length, equals(eventsAfterFirst),
          reason: 'idempotent re-call must not emit a second NodePersisted');
    });

    // ─── Edge idempotency — the A.67 addition ────────────────────────

    test('repeat edge with same idempotency key returns same EdgeId, '
        'no second row, no second event', () async {
      final claim = await persistClaim('the sky is blue', idemKey: 'k-claim-1');
      final source = await persistSource('https://example.org/sky',
          idemKey: 'k-source-1');

      events.clear();
      final scope = const Scope(
        producer: 'extractor:dream_extract_v1:r_01',
        idempotencyKey: 'extractor:edge:e_01',
      );

      final first = await writer.edge(
        claim,
        EdgeType.derivedFrom,
        source,
        scope: scope,
      );
      final edgeCountAfterFirst = edgeCount();
      final eventsAfterFirst = events.length;
      expect(events.whereType<EdgeCreated>(), hasLength(1));

      // Replay under the same key. The endpoints, label, weight, attrs
      // could even differ — the contract is "key alone deduplicates".
      final second = await writer.edge(
        claim,
        EdgeType.derivedFrom,
        source,
        scope: scope,
        weight: 99.0,
        attrs: const <String, Object?>{'discarded': true},
      );

      expect(second, equals(first),
          reason: 'second edge under same key must return prior EdgeId');
      expect(edgeCount(), equals(edgeCountAfterFirst),
          reason: 'no second row inserted');
      expect(events.length, equals(eventsAfterFirst),
          reason: 'no second EdgeCreated emitted');

      // And the original row's weight / attrs survive — the second
      // call's payload is *not* applied.
      final row = db
          .select('SELECT weight, attrs_json FROM edges WHERE id = ?',
              <Object?>[first.toString()])
          .first;
      expect((row['weight'] as num).toDouble(), equals(1.0));
      expect(row['attrs_json'], isNull);
    });

    test('different idempotency keys → distinct EdgeIds for the same '
        'endpoints', () async {
      final claim = await persistClaim('repeatable observation',
          idemKey: 'k-claim-rep');
      final source =
          await persistSource('https://example.org/r', idemKey: 'k-source-rep');

      final scope1 = const Scope(
        producer: 'extractor:dream_extract_v1:r_01',
        idempotencyKey: 'extractor:edge:e_keyA',
      );
      final scope2 = const Scope(
        producer: 'extractor:dream_extract_v1:r_01',
        idempotencyKey: 'extractor:edge:e_keyB',
      );

      final id1 = await writer.edge(claim, EdgeType.derivedFrom, source,
          scope: scope1);
      final id2 = await writer.edge(claim, EdgeType.derivedFrom, source,
          scope: scope2);

      expect(id1, isNot(equals(id2)));
      expect(edgeCount(), equals(2),
          reason: 'distinct keys → distinct rows (multi-graph allowed)');
    });

    test('null idempotency key never collides — two writes → two rows',
        () async {
      final claim = await persistClaim('one', idemKey: 'k-c1');
      final source =
          await persistSource('https://example.org/n', idemKey: 'k-s1');

      const scope = Scope.nonIdempotent(producer: 'no-idem-test');
      final id1 = await writer.edge(claim, EdgeType.derivedFrom, source,
          scope: scope);
      final id2 = await writer.edge(claim, EdgeType.derivedFrom, source,
          scope: scope);

      expect(id1, isNot(equals(id2)));
      expect(edgeCount(), equals(2),
          reason: 'partial-unique index ignores NULL idempotency keys');

      // Both rows carry NULL idempotency_key.
      final keys = db
          .select('SELECT idempotency_key FROM edges')
          .map((r) => r['idempotency_key'])
          .toList();
      expect(keys, equals(<Object?>[null, null]));
    });

    test('produced_by mirrors scope.producer on the first commit',
        () async {
      final claim =
          await persistClaim('source attribution', idemKey: 'k-c-attr');
      final source = await persistSource('https://example.org/attr',
          idemKey: 'k-s-attr');

      const scope = Scope(
        producer: 'extractor:dream_extract_v1:r_42',
        idempotencyKey: 'extractor:edge:e_attr',
      );
      final id = await writer.edge(claim, EdgeType.derivedFrom, source,
          scope: scope);

      final row = db.select(
          'SELECT produced_by, idempotency_key FROM edges WHERE id = ?',
          <Object?>[id.toString()]).first;
      expect(row['produced_by'],
          equals('extractor:dream_extract_v1:r_42'));
      expect(row['idempotency_key'], equals('extractor:edge:e_attr'));
    });

    // ─── Combined replay — the real motivation for A.67 ──────────────

    test('simulated agent run is replayable end-to-end under stable keys',
        () async {
      // Fixture: a Source already lives in memory. The extractor
      // run will persist a new Claim and link it `derivedFrom` the
      // source under stable keys.
      final source = await persistSource('https://example.org/seed',
          idemKey: 'extractor:source:seed');

      const claimKey = 'extractor:claim:e_001';
      const edgeKey = 'extractor:edge:claim_001';
      const scope = Scope(
        producer: 'extractor:dream_extract_v1:r_001',
        idempotencyKey: claimKey,
      );
      const edgeScope = Scope(
        producer: 'extractor:dream_extract_v1:r_001',
        idempotencyKey: edgeKey,
      );

      // First run.
      events.clear();
      final claim1 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'observed claim'},
          embedding: _v768(seed: 1),
        ),
        scope: scope,
      );
      final edge1 = await writer.edge(
        claim1,
        EdgeType.derivedFrom,
        source,
        scope: edgeScope,
      );
      final eventsAfterFirstRun = events.length;
      expect(eventsAfterFirstRun, equals(2),
          reason: 'one NodePersisted + one EdgeCreated');

      // Second run — interrupted-and-retried agent re-issues the
      // exact same writes.
      final claim2 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'observed claim'},
          embedding: _v768(seed: 1),
        ),
        scope: scope,
      );
      final edge2 = await writer.edge(
        claim2,
        EdgeType.derivedFrom,
        source,
        scope: edgeScope,
      );

      expect(claim2, equals(claim1));
      expect(edge2, equals(edge1));
      // Source + Claim only — Conclusion isn't used in this test.
      expect(nodeCount(), equals(2));
      expect(edgeCount(), equals(1));
      expect(events.length, equals(eventsAfterFirstRun),
          reason: 'replay must not emit duplicate events');
    });

    // ─── DB-level integrity ──────────────────────────────────────────

    test('uniq_edges_idempotency_key rejects manual duplicate inserts',
        () async {
      final claim = await persistClaim('integrity', idemKey: 'k-c-int');
      final source = await persistSource('https://example.org/int',
          idemKey: 'k-s-int');
      const scope = Scope(producer: 'a67-test', idempotencyKey: 'idem-collide');
      await writer.edge(claim, EdgeType.derivedFrom, source, scope: scope);

      // Hand-roll a row that bypasses EdgeWriter. The partial-unique
      // index must trip.
      void attempt() {
        db.execute(
          'INSERT INTO edges (id, from_node, to_node, type, weight, '
          'attrs_json, produced_by, created_at_ms, created_at_iso, '
          'idempotency_key) VALUES (?,?,?,?,?,?,?,?,?,?)',
          <Object?>[
            EdgeId.generate().toString(),
            claim.toString(),
            source.toString(),
            'derived_from',
            1.0,
            null,
            'bypass',
            fakeNow.millisecondsSinceEpoch,
            fakeNow.toIso8601String(),
            'idem-collide',
          ],
        );
      }

      expect(attempt, throwsA(isA<SqliteException>()));
    });
  });
}

// ─── Fixtures (mirror those in edge_writer_test.dart) ────────────────

NodeTypeDecl _validClaim() => NodeTypeDecl(
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
        EdgeType.derivedFrom,
        EdgeType.evidenceFor,
      },
      allowedIncoming: const <EdgeType>{EdgeType.evidenceFor},
    );

NodeTypeDecl _validSource() => NodeTypeDecl(
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

NodeTypeDecl _validConclusion() => NodeTypeDecl(
      typeName: 'Conclusion',
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
        defaultHorizonMs: 365 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{EdgeType.evidenceFor},
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
