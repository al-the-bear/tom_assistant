// A.34 — NodePersister contract test.
//
// Covers `NodePersister.persist` end-to-end against a real in-memory
// SQLite engine and an in-memory fake `VectorApplier`. The validation
// matrix exercises every branch of `_validateValuesAgainstSchema`,
// `_validateEmbeddingAgainstPolicy`, and the idempotency path.
//
// Coverage map (one `test(...)` per row):
//
//   Success paths
//   -------------
//   * Fresh node with embedding commits to memory.db AND vectors.db
//     (via the coordinator), emits NodePersisted, returns a fresh
//     NodeId.
//   * Type with EmbeddingPolicy.none persists without touching the
//     vector applier (no pending row, no NodePersisted.embedding*).
//   * Nullable fields can be omitted.
//   * Enum field accepts a value in the allowed set.
//   * Multiple writes generate distinct ids and rows.
//   * Scope.causedBy / scope.runId surface on the emitted event.
//
//   Idempotency
//   -----------
//   * Second persist with the same idempotency_key returns the
//     original NodeId, performs no INSERT, emits no event, leaves the
//     vector applier untouched on the second call.
//   * Different idempotency keys produce distinct nodes.
//   * `Scope.nonIdempotent` always writes a fresh node.
//
//   Failure — UnknownNodeType
//   -------------------------
//   * Draft.typeName not in registry → UnknownNodeType, no row, no
//     event, no vector.
//
//   Failure — InvalidNodeDraft
//   --------------------------
//   * Unknown field in values.
//   * Missing required (non-nullable) field.
//   * Field type mismatch (int provided for string).
//   * Enum value out of range.
//   * Noderef value is not a valid NodeId.
//
//   Failure — EmbeddingPolicyViolation
//   ----------------------------------
//   * EmbeddingPolicy declared but draft.embedding is null.
//   * EmbeddingPolicy.none but draft.embedding supplied.
//   * Dimension mismatch (768 declared, 16 supplied).
//
//   Side-effect invariants on failure
//   ---------------------------------
//   * On every failure: 0 rows in nodes, 0 rows in
//     pending_vector_writes, applier.calls empty, events empty.
//
// The persister is tested without going through `SqliteTomBrainMemory`
// (which doesn't exist yet — that class composes per-operation owners
// in a later step). The tests construct the owners directly, the same
// way the future store opener will.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, FixedClock, NodeId, Vec;

void main() {
  group('A.34 NodePersister.persist', () {
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late List<MemoryEvent> events;
    late int idCounter;
    late DateTime fakeNow;

    NodeId mintId() {
      // Deterministic id stream — same pattern as the A.33 test.
      idCounter += 1;
      final randomness = List<int>.generate(16, (i) => (idCounter + i) & 31);
      return NodeId.generate(at: fakeNow, randomness: randomness);
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
      idCounter = 0;
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);

      // The persister consults the registry, not the underlying SQL,
      // so we register the test types up front via the registry (which
      // also covers the cache-warm path) using its own id mint so the
      // ids don't collide with the persister's mints.
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
      await registry.registerNodeType(_validTombstone());
      await registry.registerNodeType(_validQuestion());
      await registry.registerNodeType(_validWithEnumAndRef());
    });

    tearDown(() {
      db.dispose();
    });

    NodePersister buildPersister() {
      return NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintId,
        now: () => fakeNow,
        eventSink: events.add,
      );
    }

    // Shared assertion used by every refusal-path test: a persist()
    // that throws must leave zero rows, no pending vector write, no
    // applier call, and no emitted event behind. Hoisted here so all
    // tests below can reference it.
    void expectNoNodeSideEffects() {
      expect(db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
          equals(0));
      expect(coordinator.pendingCount(), equals(0));
      expect(applier.calls, isEmpty);
      expect(events, isEmpty);
    }

    // ─── Success paths ─────────────────────────────────────────────

    test('commits a fresh node with embedding and emits event',
        () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'Claim',
        values: const <String, Object?>{'text': 'the sky is blue'},
        embedding: _v768(seed: 1),
      );
      final scope = Scope(
        producer: 'extractor:dream_extract_v1:r_test',
        idempotencyKey: 'k-claim-1',
        causedBy: 'event-42',
        runId: 'r_test',
      );

      final id = await persister.persist(draft, scope: scope);

      // Row exists.
      final rows = db.select('SELECT * FROM nodes WHERE id = ?',
          <Object?>[id.toString()]);
      expect(rows, hasLength(1));
      final row = rows.first;
      expect(row['type_name'], equals('Claim'));
      expect(row['status'], equals('active'));
      expect(row['idempotency_key'], equals('k-claim-1'));
      expect(row['produced_by'], equals('extractor:dream_extract_v1:r_test'));
      expect(row['embedding_model_id'], equals('nomic-embed-text@v1.5'));
      expect(row['created_at_ms'], equals(fakeNow.millisecondsSinceEpoch));
      expect(row['updated_at_ms'], equals(fakeNow.millisecondsSinceEpoch));

      // Vector applier was called once with the right dims/model.
      expect(applier.calls, hasLength(1));
      expect(applier.calls.single.nodeId, equals(id.toString()));
      expect(applier.calls.single.embeddingModelId,
          equals('nomic-embed-text@v1.5'));
      expect(applier.calls.single.payloadDims, equals(768));

      // pending_vector_writes is empty (apply succeeded → row deleted).
      expect(coordinator.pendingCount(), equals(0));

      // Event emitted.
      expect(events, hasLength(1));
      final ev = events.single as NodePersisted;
      expect(ev.nodeId, equals(id));
      expect(ev.typeName, equals('Claim'));
      expect(ev.producer, equals('extractor:dream_extract_v1:r_test'));
      expect(ev.idempotencyKey, equals('k-claim-1'));
      expect(ev.embeddingModelId, equals('nomic-embed-text@v1.5'));
      expect(ev.embeddingDimensions, equals(768));
      expect(ev.kind, equals('memory.node-persisted'));
      expect(ev.occurredAt, equals(fakeNow));
      expect(ev.causedBy, equals('event-42'));
      expect(ev.runId, equals('r_test'));
    });

    test('EmbeddingPolicy.none type persists without touching applier',
        () async {
      final persister = buildPersister();
      final draft = const NodeDraft(
        typeName: 'Tombstone',
        values: <String, Object?>{'reason': 'user-requested'},
      );
      final scope = Scope(
        producer: 'reconsolidator:dream_reconsolidate_v1:r_test',
        idempotencyKey: 'k-ts-1',
      );

      final id = await persister.persist(draft, scope: scope);

      final rows = db.select('SELECT embedding_model_id FROM nodes '
          'WHERE id = ?', <Object?>[id.toString()]);
      expect(rows.first['embedding_model_id'], isNull);
      expect(applier.calls, isEmpty);
      expect(coordinator.pendingCount(), equals(0));

      final ev = events.single as NodePersisted;
      expect(ev.embeddingModelId, isNull);
      expect(ev.embeddingDimensions, isNull);
    });

    test('nullable fields can be omitted', () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'WithEnumAndRef',
        // `tag` and `ref` are nullable; omit them entirely.
        values: const <String, Object?>{'title': 'hello'},
        embedding: _v768(seed: 7),
      );
      final id = await persister.persist(
        draft,
        scope: const Scope(producer: 'p', idempotencyKey: 'k-omit'),
      );
      expect(id.toString(), startsWith('n_'));
    });

    test('enum field accepts a value in the allowed set', () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'WithEnumAndRef',
        values: const <String, Object?>{
          'title': 'priority pick',
          'tag': 'high',
        },
        embedding: _v768(seed: 3),
      );
      await persister.persist(
        draft,
        scope: const Scope(producer: 'p', idempotencyKey: 'k-enum-ok'),
      );
      expect(events, hasLength(1));
    });

    test('multiple writes produce distinct ids and rows', () async {
      final persister = buildPersister();
      final scope1 = const Scope(producer: 'p', idempotencyKey: 'k1');
      final scope2 = const Scope(producer: 'p', idempotencyKey: 'k2');
      final id1 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'one'},
          embedding: _v768(seed: 1),
        ),
        scope: scope1,
      );
      final id2 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'two'},
          embedding: _v768(seed: 2),
        ),
        scope: scope2,
      );
      expect(id1, isNot(equals(id2)));
      expect(db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
          equals(2));
      expect(events, hasLength(2));
      expect(applier.calls, hasLength(2));
    });

    // ─── Idempotency ───────────────────────────────────────────────

    test('second persist with same idempotency key returns prior id, '
        'no INSERT, no event, no applier call', () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'Claim',
        values: const <String, Object?>{'text': 'once'},
        embedding: _v768(seed: 1),
      );
      const scope = Scope(producer: 'p', idempotencyKey: 'k-same');

      final first = await persister.persist(draft, scope: scope);
      // Snapshot the side-effects after the first call.
      final applierCallsAfterFirst = applier.calls.length;
      final eventsAfterFirst = events.length;

      // A re-issued persist with the same key — different values,
      // different embedding, even — must still dedup to the first id.
      final second = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'totally different'},
          embedding: _v768(seed: 999),
        ),
        scope: scope,
      );

      expect(second, equals(first));
      expect(applier.calls.length, equals(applierCallsAfterFirst));
      expect(events.length, equals(eventsAfterFirst));
      expect(db.select('SELECT COUNT(*) AS n FROM nodes').first['n'],
          equals(1));
    });

    test('different idempotency keys produce distinct nodes', () async {
      final persister = buildPersister();
      final id1 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'a'},
          embedding: _v768(seed: 1),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'kA'),
      );
      final id2 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'a'},
          embedding: _v768(seed: 1),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'kB'),
      );
      expect(id1, isNot(equals(id2)));
    });

    test('Scope.nonIdempotent always writes a fresh node', () async {
      final persister = buildPersister();
      const scope = Scope.nonIdempotent(producer: 'p');
      final id1 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'one'},
          embedding: _v768(seed: 1),
        ),
        scope: scope,
      );
      final id2 = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'one'},
          embedding: _v768(seed: 1),
        ),
        scope: scope,
      );
      expect(id1, isNot(equals(id2)));
      // Both rows have NULL idempotency_key — the partial unique index
      // ignores NULL collisions.
      expect(db.select('SELECT COUNT(*) AS n FROM nodes '
              'WHERE idempotency_key IS NULL').first['n'],
          equals(2));
    });

    // ─── UnknownNodeType ───────────────────────────────────────────

    test('unknown typeName → UnknownNodeType, no side effects', () async {
      final persister = buildPersister();
      final draft = const NodeDraft(
        typeName: 'NotRegistered',
        values: <String, Object?>{'x': 1},
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<UnknownNodeType>()
            .having((e) => e.typeName, 'typeName', 'NotRegistered')),
      );
      expectNoNodeSideEffects();
    });

    // ─── InvalidNodeDraft branches ─────────────────────────────────

    test('unknown field → InvalidNodeDraft.unknownField', () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'Claim',
        values: const <String, Object?>{
          'text': 'hi',
          'random_extra': 'oops',
        },
        embedding: _v768(seed: 1),
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<InvalidNodeDraft>()
            .having((e) => e.fieldName, 'fieldName', 'random_extra')
            .having((e) => e.reason, 'reason',
                InvalidNodeDraftReason.unknownField)),
      );
      expectNoNodeSideEffects();
    });

    test('missing required field → InvalidNodeDraft.missingRequiredField',
        () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'Claim',
        values: const <String, Object?>{},
        embedding: _v768(seed: 1),
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<InvalidNodeDraft>()
            .having((e) => e.fieldName, 'fieldName', 'text')
            .having((e) => e.reason, 'reason',
                InvalidNodeDraftReason.missingRequiredField)),
      );
      expectNoNodeSideEffects();
    });

    test('field type mismatch → InvalidNodeDraft.fieldTypeMismatch',
        () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'Claim',
        values: const <String, Object?>{'text': 42}, // int, expected String
        embedding: _v768(seed: 1),
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<InvalidNodeDraft>()
            .having((e) => e.fieldName, 'fieldName', 'text')
            .having((e) => e.reason, 'reason',
                InvalidNodeDraftReason.fieldTypeMismatch)),
      );
      expectNoNodeSideEffects();
    });

    test('enum value out of range → InvalidNodeDraft.enumValueOutOfRange',
        () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'WithEnumAndRef',
        values: const <String, Object?>{
          'title': 'x',
          'tag': 'banana', // not in [low, medium, high]
        },
        embedding: _v768(seed: 1),
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<InvalidNodeDraft>()
            .having((e) => e.fieldName, 'fieldName', 'tag')
            .having((e) => e.reason, 'reason',
                InvalidNodeDraftReason.enumValueOutOfRange)),
      );
      expectNoNodeSideEffects();
    });

    test('invalid nodeRef → InvalidNodeDraft.invalidNodeRef', () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'WithEnumAndRef',
        values: const <String, Object?>{
          'title': 'x',
          'ref': 'not-a-node-id',
        },
        embedding: _v768(seed: 1),
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<InvalidNodeDraft>()
            .having((e) => e.fieldName, 'fieldName', 'ref')
            .having((e) => e.reason, 'reason',
                InvalidNodeDraftReason.invalidNodeRef)),
      );
      expectNoNodeSideEffects();
    });

    test('valid nodeRef is accepted', () async {
      final persister = buildPersister();
      final otherId = NodeId.generate();
      final draft = NodeDraft(
        typeName: 'WithEnumAndRef',
        values: <String, Object?>{
          'title': 'x',
          'ref': otherId.toString(),
        },
        embedding: _v768(seed: 1),
      );
      final id = await persister.persist(draft,
          scope: const Scope(producer: 'p', idempotencyKey: 'k-ref-ok'));
      expect(id.toString(), startsWith('n_'));
    });

    // ─── EmbeddingPolicyViolation branches ─────────────────────────

    test('missing embedding for embedding-bearing type → '
        'EmbeddingPolicyViolation.missingEmbedding', () async {
      final persister = buildPersister();
      final draft = const NodeDraft(
        typeName: 'Claim',
        values: <String, Object?>{'text': 'hello'},
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<EmbeddingPolicyViolation>()
            .having((e) => e.reason, 'reason',
                EmbeddingPolicyViolationReason.missingEmbedding)),
      );
      expectNoNodeSideEffects();
    });

    test('unexpected embedding on EmbeddingPolicy.none → '
        'EmbeddingPolicyViolation.unexpectedEmbedding', () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'Tombstone',
        values: const <String, Object?>{'reason': 'r'},
        embedding: _v768(seed: 1),
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<EmbeddingPolicyViolation>()
            .having((e) => e.reason, 'reason',
                EmbeddingPolicyViolationReason.unexpectedEmbedding)),
      );
      expectNoNodeSideEffects();
    });

    test('embedding dimension mismatch → '
        'EmbeddingPolicyViolation.dimensionMismatch', () async {
      final persister = buildPersister();
      final draft = NodeDraft(
        typeName: 'Claim',
        values: const <String, Object?>{'text': 'short embed'},
        embedding: Vec(Float32List(16)), // policy declares 768
      );
      await expectLater(
        persister.persist(draft,
            scope: const Scope(producer: 'p', idempotencyKey: 'k')),
        throwsA(isA<EmbeddingPolicyViolation>()
            .having((e) => e.reason, 'reason',
                EmbeddingPolicyViolationReason.dimensionMismatch)
            .having((e) => e.expectedDimensions, 'expected', 768)
            .having((e) => e.actualDimensions, 'actual', 16)),
      );
      expectNoNodeSideEffects();
    });

  });
}

// ─── Fixtures ───────────────────────────────────────────────────

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
      allowedOutgoing: const <EdgeType>{EdgeType.derivedFrom},
      allowedIncoming: const <EdgeType>{EdgeType.evidenceFor},
    );

NodeTypeDecl _validTombstone() => NodeTypeDecl(
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

NodeTypeDecl _validQuestion() => NodeTypeDecl(
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

/// Test-only type exercising the enum and nodeRef branches.
NodeTypeDecl _validWithEnumAndRef() => NodeTypeDecl(
      typeName: 'WithEnumAndRef',
      version: BrainVersion.fromInt(1),
      schema: <String, FieldSpec>{
        'title': const FieldSpec(
          name: 'title',
          type: FieldType.string,
          ftsEligible: true,
        ),
        'tag': const FieldSpec(
          name: 'tag',
          type: FieldType.enumeration,
          nullable: true,
          enumValues: <String>['low', 'medium', 'high'],
        ),
        'ref': const FieldSpec(
          name: 'ref',
          type: FieldType.nodeRef,
          nullable: true,
        ),
      },
      embeddingPolicy: const EmbeddingPolicy(
        modelIdentity: 'nomic-embed-text@v1.5',
        dimensions: 768,
        sourceFields: <String>['title'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'title'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 30 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.mentions},
      allowedIncoming: const <EdgeType>{EdgeType.mentions},
    );

Vec _v768({required int seed}) {
  // Cheap deterministic vector — not used for retrieval, just for
  // round-tripping through the coordinator's blob path.
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

// ─── In-memory fake VectorApplier ───────────────────────────────

final class _RecordingVectorApplier implements VectorApplier {
  final List<PendingVectorWrite> calls = <PendingVectorWrite>[];

  @override
  void apply(PendingVectorWrite write) {
    calls.add(write);
  }
}
