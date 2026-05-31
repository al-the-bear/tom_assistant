// A.52 — Persist-to-vectors-db routing test.
//
// Plan step A.52:
//   "Wire the two-DB transaction coordinator into `persist` for
//    nodes with embedding fields."
//
// The wiring is composed across three earlier classes:
//
//   * `NodePersister` (A.34) — turns a `NodeDraft` into a
//     `(writeNode callback, PendingVectorWritePayload?)` pair and
//     calls `TwoDbCoordinator.persistNodeWithVector(...)`.
//   * `TwoDbCoordinator` (A.30) — runs the BEGIN/COMMIT/apply/DELETE
//     protocol over `memory.db` + `pending_vector_writes`.
//   * `VectorTable` (A.51) — the per-model index layer over
//     `vectors.db`.
//
// A.52 supplies the missing piece: `VectorTableApplier`, the
// production `VectorApplier` that converts a `PendingVectorWrite`
// (raw float32 blob + embedding-model-id + node-id) into a
// `VectorTable.insertVector(...)` call. With it the persist path
// is end-to-end real for the first time.
//
// What this file covers (one `test(...)` per row):
//
//   Roundtrip
//   ---------
//   * Persist a node with an embedding → the vector becomes
//     queryable in `vectors.db` under the right model index.
//   * The pending_vector_writes row is drained after the applier
//     commits the vector.
//   * `NodePersisted` event carries the model id and dimensions.
//
//   No-embedding path
//   -----------------
//   * Persist a `Tombstone` (EmbeddingPolicy.none) → coordinator
//     does NOT enqueue a pending row → applier sees no call →
//     `vectors.db` stays empty for that node.
//
//   Failure surfacing
//   -----------------
//   * Persist while the model's index is not installed →
//     applier raises `EmbeddingModelMismatch` → persist re-raises →
//     node row stays committed in memory.db → pending row stays so
//     a later replay can converge.
//   * After installing the index, `recoverPending` drains the row
//     into the vector index successfully.
//
//   Dimension mismatch
//   ------------------
//   * Install the index at a dim that disagrees with the type's
//     embedding policy → persist surfaces `EmbeddingDimsMismatch`
//     from the applier → pending row stays → reinstall (after
//     drop) is the operator path (not exercised here — the spec's
//     contract is "operator decision").
//
//   Idempotent replay
//   -----------------
//   * `recoverPending` on a clean store is a no-op
//     (scanned == 0).
//   * Two `recoverPending` passes against a working applier converge
//     — the second pass sees zero pending rows.
//   * A pending payload replayed twice over the same `(nodeId,
//     modelId)` converges (the second apply overwrites; the final
//     vector is the same).
//
//   Adapter contract
//   ----------------
//   * `VectorTableApplier.apply` decodes `payloadBlob` via
//     `Vec.fromBlob`; a corrupt blob (odd byte length) propagates
//     `ArgumentError` to the coordinator, leaving the pending row.
//
// The test runs entirely against `sqlite3.openInMemory()` for both
// databases and uses `PlainBlobTableBackend` for `VectorTable`, so it
// does not require the vec0 shared library (Q-A.50.2).

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, BrainVersion, FixedClock, NodeId, Vec;

const String _modelId = 'nomic-embed-text@v1.5';
const int _dims = 8; // small for test fixtures; spec uses 768 in production

void main() {
  group('A.52 persist → vectors.db routing', () {
    late Database memoryDb;
    late Database vectorsDb;
    late VectorTable vectorTable;
    late VectorTableApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late List<MemoryEvent> events;
    late int idCounter;
    late DateTime fakeNow;
    late BrainTime fakeBrainTime;

    NodeId mintId() {
      idCounter += 1;
      final randomness = List<int>.generate(16, (i) => (idCounter + i) & 31);
      return NodeId.generate(at: fakeNow, randomness: randomness);
    }

    Future<NodeTypeRegistry> buildRegistry() async {
      var regIdCounter = 1000;
      NodeId mintRegistryId() {
        regIdCounter += 1;
        return NodeId.generate(
          at: fakeNow,
          randomness:
              List<int>.generate(16, (i) => (regIdCounter + i) & 31),
        );
      }

      final r = NodeTypeRegistry(
        memoryDb: memoryDb,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      await r.registerNodeType(_claimType());
      await r.registerNodeType(_tombstoneType());
      return r;
    }

    setUp(() async {
      memoryDb = sqlite3.openInMemory();
      applySchemaV1(memoryDb);

      vectorsDb = sqlite3.openInMemory();
      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      fakeBrainTime = BrainTime.utc(2026, 5, 30, 14, 0, 0);
      vectorTable = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: FixedClock(fakeBrainTime),
      );

      applier = VectorTableApplier(vectorTable: vectorTable);
      coordinator = TwoDbCoordinator(
        memoryDb: memoryDb,
        applier: applier,
        clock: FixedClock(fakeBrainTime),
      );
      events = <MemoryEvent>[];
      idCounter = 0;
      registry = await buildRegistry();
    });

    tearDown(() {
      memoryDb.dispose();
      vectorsDb.dispose();
    });

    NodePersister buildPersister() => NodePersister(
          memoryDb: memoryDb,
          coordinator: coordinator,
          registry: registry,
          idMint: mintId,
          now: () => fakeNow,
          eventSink: events.add,
        );

    // ─── Roundtrip ────────────────────────────────────────────────

    test('persist with embedding writes vector through applier into '
        'vectors.db; pending row is drained; node is queryable by '
        'k-NN', () async {
      vectorTable.installIndex(modelId: _modelId, dims: _dims);
      final persister = buildPersister();

      final embedding = _vec(seed: 1);
      final id = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'the sky is blue'},
          embedding: embedding,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-claim-1'),
      );

      // memory.db side: row committed, pending row drained.
      final rows = memoryDb.select(
        'SELECT id, embedding_model_id FROM nodes WHERE id = ?',
        <Object?>[id.toString()],
      );
      expect(rows, hasLength(1));
      expect(rows.first['embedding_model_id'], equals(_modelId));
      expect(coordinator.pendingCount(), equals(0));

      // vectors.db side: vector is queryable, distance 0 to itself.
      final matches = vectorTable.queryNearest(
        query: embedding,
        k: 3,
        modelId: _modelId,
      );
      expect(matches, hasLength(1));
      expect(matches.first.nodeId, equals(id.toString()));
      expect(matches.first.distance, closeTo(0.0, 1e-9));

      // Event surface carries the embedding identity.
      expect(events, hasLength(1));
      final ev = events.single as NodePersisted;
      expect(ev.embeddingModelId, equals(_modelId));
      expect(ev.embeddingDimensions, equals(_dims));
    });

    test('two persists under the same model produce two queryable '
        'vectors with deterministic ordering by distance', () async {
      vectorTable.installIndex(modelId: _modelId, dims: _dims);
      final persister = buildPersister();

      final near = _vec(seed: 1);
      final far = _vec(seed: 99);

      final nearId = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'near'},
          embedding: near,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-near'),
      );
      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'far'},
          embedding: far,
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-far'),
      );

      expect(coordinator.pendingCount(), equals(0));

      final matches = vectorTable.queryNearest(
        query: near,
        k: 2,
        modelId: _modelId,
      );
      expect(matches, hasLength(2));
      expect(matches.first.nodeId, equals(nearId.toString()));
      expect(matches.first.distance, closeTo(0.0, 1e-9));
      // Second match is the far node, with strictly greater distance.
      expect(matches[1].distance, greaterThan(matches.first.distance));
    });

    // ─── No-embedding path ────────────────────────────────────────

    test('persist with EmbeddingPolicy.none does not touch the applier '
        'or vectors.db', () async {
      // Deliberately do NOT install any index — exercising that the
      // no-embedding path never reaches the applier so the missing
      // index cannot surface as an error.
      final persister = buildPersister();

      final id = await persister.persist(
        const NodeDraft(
          typeName: 'Tombstone',
          values: <String, Object?>{'reason': 'user-requested'},
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-ts-1'),
      );

      expect(coordinator.pendingCount(), equals(0));

      // vectors.db has no installed indexes — listInstalledIndexes
      // returns an empty list, and no per-model table was created.
      expect(vectorTable.listInstalledIndexes(), isEmpty);

      // Node row carries no embedding_model_id.
      final rows = memoryDb.select(
        'SELECT embedding_model_id FROM nodes WHERE id = ?',
        <Object?>[id.toString()],
      );
      expect(rows.first['embedding_model_id'], isNull);

      // The emitted event reflects the no-embedding state.
      final ev = events.single as NodePersisted;
      expect(ev.embeddingModelId, isNull);
      expect(ev.embeddingDimensions, isNull);
    });

    // ─── Failure surfacing + replay ───────────────────────────────

    test('persist while index is uninstalled surfaces '
        'EmbeddingModelMismatch and leaves the pending row; install + '
        'recoverPending drains it', () async {
      // Index not installed → applier raises EmbeddingModelMismatch.
      final persister = buildPersister();
      final embedding = _vec(seed: 7);

      expect(
        () => persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: const <String, Object?>{'text': 'unindexed write'},
            embedding: embedding,
          ),
          scope: const Scope(producer: 'p', idempotencyKey: 'k-unindex'),
        ),
        throwsA(isA<EmbeddingModelMismatch>()),
      );

      // Spec § 2.4: the pending row stays so recovery can converge.
      expect(coordinator.pendingCount(), equals(1));

      // The node row is committed (memory.db succeeded before the
      // applier was called) — the missing vector is the recoverable
      // state, not a missing node.
      final nodeRows = memoryDb.select(
        'SELECT COUNT(*) AS n FROM nodes WHERE type_name = ?',
        <Object?>['Claim'],
      );
      expect(nodeRows.first['n'], equals(1));

      // Operator installs the index; recoverPending now succeeds.
      vectorTable.installIndex(modelId: _modelId, dims: _dims);
      final report = coordinator.recoverPending();
      expect(report.scanned, equals(1));
      expect(report.succeeded, equals(1));
      expect(report.hasFailures, isFalse);
      expect(coordinator.pendingCount(), equals(0));

      // The vector is now queryable.
      final matches = vectorTable.queryNearest(
        query: embedding,
        k: 1,
        modelId: _modelId,
      );
      expect(matches, hasLength(1));
      expect(matches.first.distance, closeTo(0.0, 1e-9));
    });

    test('persist with index at wrong dim surfaces '
        'EmbeddingDimsMismatch from the applier', () async {
      // Install with the wrong dim — persister's policy check passes
      // (vector matches the type's declared dims) but the applier's
      // VectorTable.insertVector compares against the installed index
      // dims, which differ.
      vectorTable.installIndex(modelId: _modelId, dims: _dims + 4);
      final persister = buildPersister();

      expect(
        () => persister.persist(
          NodeDraft(
            typeName: 'Claim',
            values: const <String, Object?>{'text': 'dim drift'},
            embedding: _vec(seed: 11),
          ),
          scope: const Scope(producer: 'p', idempotencyKey: 'k-dim'),
        ),
        throwsA(isA<EmbeddingDimsMismatch>()),
      );

      // Pending row stays — operator must drop the bad index and
      // reinstall at the correct dim before recovery converges.
      expect(coordinator.pendingCount(), equals(1));
    });

    // ─── Idempotent replay ────────────────────────────────────────

    test('recoverPending on a clean store is a no-op', () {
      final report = coordinator.recoverPending();
      expect(report.isEmpty, isTrue);
      expect(report.scanned, equals(0));
      expect(report.succeeded, equals(0));
      expect(report.hasFailures, isFalse);
    });

    test('a second recoverPending after success sees zero pending rows '
        '(idempotent at the protocol level)', () async {
      vectorTable.installIndex(modelId: _modelId, dims: _dims);
      final persister = buildPersister();

      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'text': 'one'},
          embedding: _vec(seed: 5),
        ),
        scope: const Scope(producer: 'p', idempotencyKey: 'k-idem'),
      );

      // First pass: nothing to recover (the persist path already
      // drained the row).
      final r1 = coordinator.recoverPending();
      expect(r1.scanned, equals(0));
      // Second pass: still nothing.
      final r2 = coordinator.recoverPending();
      expect(r2.scanned, equals(0));
    });

    test('replaying the same payload twice through the applier '
        'converges (insertVector uses upsert semantics)', () {
      vectorTable.installIndex(modelId: _modelId, dims: _dims);
      final embedding = _vec(seed: 42);

      // Construct a PendingVectorWrite by hand and feed it to apply
      // twice — this is the recovery-loop's contract on the adapter.
      final write = PendingVectorWrite(
        nodeId: 'n_handcrafted',
        embeddingModelId: _modelId,
        payloadBlob: embedding.toBlob(),
        payloadDims: _dims,
        enqueuedAt: fakeBrainTime,
      );
      applier.apply(write);
      applier.apply(write); // second apply must converge (no throw)

      final matches = vectorTable.queryNearest(
        query: embedding,
        k: 5,
        modelId: _modelId,
      );
      expect(matches, hasLength(1));
      expect(matches.first.nodeId, equals('n_handcrafted'));
      expect(matches.first.distance, closeTo(0.0, 1e-9));
    });

    // ─── Adapter contract ─────────────────────────────────────────

    test('apply with corrupt (odd-length) payload_blob propagates '
        'ArgumentError from Vec.fromBlob', () {
      vectorTable.installIndex(modelId: _modelId, dims: _dims);

      // Length 3 is not a multiple of 4 — Vec.fromBlob refuses.
      final corrupt = Uint8List.fromList(<int>[1, 2, 3]);
      final write = PendingVectorWrite(
        nodeId: 'n_corrupt',
        embeddingModelId: _modelId,
        payloadBlob: corrupt,
        payloadDims: _dims,
        enqueuedAt: fakeBrainTime,
      );
      expect(
        () => applier.apply(write),
        throwsA(isA<ArgumentError>()),
      );

      // The vector index is empty — the bad apply did not partially
      // commit anything.
      final matches = vectorTable.queryNearest(
        query: _vec(seed: 0),
        k: 5,
        modelId: _modelId,
      );
      expect(matches, isEmpty);
    });

    test('apply forwards (nodeId, modelId) without translation '
        '— same as VectorTable.insertVector would receive directly', () {
      vectorTable.installIndex(modelId: _modelId, dims: _dims);
      final embedding = _vec(seed: 13);

      applier.apply(PendingVectorWrite(
        nodeId: 'n_direct',
        embeddingModelId: _modelId,
        payloadBlob: embedding.toBlob(),
        payloadDims: _dims,
        enqueuedAt: fakeBrainTime,
      ));

      // Pulled via VectorTable: the adapter does not store anywhere
      // else and does not silently rename the model.
      final viaApplier = vectorTable.queryNearest(
        query: embedding,
        k: 1,
        modelId: _modelId,
      );

      // Compare against a direct insertVector under a different node
      // id — both routes land in the same per-model table.
      vectorTable.insertVector(
        nodeId: 'n_direct_again',
        vector: embedding,
        modelId: _modelId,
      );
      final viaDirect = vectorTable.queryNearest(
        query: embedding,
        k: 2,
        modelId: _modelId,
      );

      expect(viaApplier, hasLength(1));
      expect(viaApplier.first.nodeId, equals('n_direct'));
      expect(viaDirect, hasLength(2));
      final ids = viaDirect.map((m) => m.nodeId).toSet();
      expect(ids, equals(<String>{'n_direct', 'n_direct_again'}));
    });
  });
}

// ─── Test fixtures ─────────────────────────────────────────────────

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
        modelIdentity: _modelId,
        dimensions: _dims,
        sourceFields: <String>['text'],
      ),
      indexPolicy: const IndexPolicy(
        ftsFields: <String>{'text'},
        vectorFields: <String>{},
      ),
      retentionPolicy: const RetentionPolicy(
        defaultHorizonMs: 365 * 86400 * 1000,
      ),
      allowedOutgoing: const <EdgeType>{EdgeType.mentions},
      allowedIncoming: const <EdgeType>{EdgeType.mentions},
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

Vec _vec({required int seed}) {
  // Cheap deterministic vector — repeatable across runs so distance
  // assertions stay stable.
  final values = Float32List(_dims);
  for (var i = 0; i < _dims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}
