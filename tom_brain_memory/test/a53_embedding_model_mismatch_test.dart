// A.53 — Embedding-model mismatch rejection (integration).
//
// Plan step A.53:
//   "Tests: extension load + vec query roundtrip; degraded-mode recall
//    when extension missing; embedding-model mismatch rejection."
//
// Spec § 10.4 (Embedding-model agreement):
//   "All replicas must use the same substrate embedding model. Memory
//    records the embedding-model-identity per vector and refuses to
//    mix incompatible vectors in a single index. A model change
//    triggers a `restructure_tree_v1` for re-embedding."
//
// What A.51 / A.52 already covered:
//   * A.51 — `VectorTable.insertVector` /`queryNearest` /
//     `removeVector` each raise `EmbeddingModelMismatch` when called
//     with an uninstalled model id; two models with the same dim get
//     isolated physical tables.
//   * A.52 — the persist path surfaces applier exceptions to the
//     caller and leaves the pending row for recovery.
//
// What A.53 adds (this file):
//   * The **composition** of those refusals: a `PendingVectorWrite`
//     whose `embeddingModelId` does not match any installed index
//     flows through `VectorTableApplier.apply` and surfaces
//     `EmbeddingModelMismatch` at the coordinator boundary.
//   * The **convergence-after-fix** path: a refused write leaves a
//     pending row; installing the index later allows
//     `recoverPending` to drain it idempotently.
//   * The **cross-model isolation** corollary: a vector inserted
//     under model A cannot be recalled under model B even when the
//     dims agree — the layer never falls back to "well, the
//     dimensions match, return the row anyway". This is the spec
//     § 10.4 "refuses to mix incompatible vectors in a single index"
//     contract restated at the integration level.
//   * The **dims-mismatch corollary**: when an index exists for a
//     model but the incoming payload's dimensionality disagrees, the
//     refusal type is `EmbeddingDimsMismatch` (distinct from
//     `EmbeddingModelMismatch`) — operators need the two apart to
//     pick between "install a new index" vs "re-embed with the right
//     dim".

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, FixedClock, Vec;

const String _modelA = 'A.53/model-A';
const String _modelB = 'A.53/model-B';
const int _dims = 4;

Vec _vec(int seed) => Vec.fromList(<double>[
      for (var i = 0; i < _dims; i++) (seed + i) * 0.25,
    ]);

void main() {
  group('A.53 embedding-model mismatch rejection', () {
    late Database memoryDb;
    late Database vectorsDb;
    late VectorTable table;
    late VectorTableApplier applier;
    late TwoDbCoordinator coordinator;

    setUp(() {
      memoryDb = sqlite3.openInMemory();
      applySchemaV1(memoryDb);
      vectorsDb = sqlite3.openInMemory();

      table = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 12)),
      );
      applier = VectorTableApplier(vectorTable: table);
      coordinator = TwoDbCoordinator(
        memoryDb: memoryDb,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 12)),
      );
    });

    tearDown(() {
      memoryDb.dispose();
      vectorsDb.dispose();
    });

    test('applier rejects PendingVectorWrite for an uninstalled model '
        'with EmbeddingModelMismatch', () {
      // No installIndex call. The applier sees a raw payload whose
      // model id has never been registered.
      final write = PendingVectorWrite(
        nodeId: 'n_unknown_model',
        embeddingModelId: 'A.53/never-installed',
        payloadBlob: _vec(1).toBlob(),
        payloadDims: _dims,
        enqueuedAt: BrainTime.utc(2026, 5, 30, 12),
      );

      expect(
        () => applier.apply(write),
        throwsA(isA<EmbeddingModelMismatch>().having(
          (e) => e.modelId,
          'modelId',
          equals('A.53/never-installed'),
        )),
      );
    });

    test('coordinator.persistNodeWithVector surfaces the mismatch; '
        'node row stays committed; pending row is preserved for '
        'recovery', () {
      // Only model B is installed; the payload uses model A.
      table.installIndex(modelId: _modelB, dims: _dims);

      const nodeId = 'a53-mismatch-node-1';
      final embedding = _vec(2);

      expect(
        () => coordinator.persistNodeWithVector(
          nodeId: nodeId,
          writeNode: (db) {
            db.execute(
              'INSERT INTO nodes (id, type_name, scope_json, '
              'attrs_json, status, created_at_ms, created_at_iso, '
              'updated_at_ms, updated_at_iso, embedding_model_id) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              <Object?>[
                nodeId,
                'Claim',
                '{}',
                '{"text":"a.53 mismatch"}',
                'active',
                0,
                '2026-05-30T12:00:00.000Z',
                0,
                '2026-05-30T12:00:00.000Z',
                _modelA,
              ],
            );
          },
          vector: PendingVectorWritePayload(
            embeddingModelId: _modelA, // unknown to the vector table
            payloadBlob: embedding.toBlob(),
            payloadDims: _dims,
          ),
        ),
        throwsA(isA<EmbeddingModelMismatch>()),
      );

      // Node row is committed (the BEGIN/COMMIT happened before the
      // applier was called).
      final nodes = memoryDb.select(
        'SELECT id FROM nodes WHERE id = ?',
        <Object?>[nodeId],
      );
      expect(nodes, hasLength(1));

      // Pending row is intentionally left so the next recovery pass
      // can replay (spec § 2.4 — conservative branch).
      expect(coordinator.pendingCount(), equals(1));
    });

    test('after installing the missing model, recoverPending drains '
        'the previously-refused row', () {
      table.installIndex(modelId: _modelB, dims: _dims);

      const nodeId = 'a53-mismatch-recover-1';
      final embedding = _vec(3);

      try {
        coordinator.persistNodeWithVector(
          nodeId: nodeId,
          writeNode: (db) {
            db.execute(
              'INSERT INTO nodes (id, type_name, scope_json, '
              'attrs_json, status, created_at_ms, created_at_iso, '
              'updated_at_ms, updated_at_iso, embedding_model_id) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
              <Object?>[
                nodeId,
                'Claim',
                '{}',
                '{"text":"a.53 recover"}',
                'active',
                0,
                '2026-05-30T12:00:00.000Z',
                0,
                '2026-05-30T12:00:00.000Z',
                _modelA,
              ],
            );
          },
          vector: PendingVectorWritePayload(
            embeddingModelId: _modelA,
            payloadBlob: embedding.toBlob(),
            payloadDims: _dims,
          ),
        );
        fail('expected EmbeddingModelMismatch on initial persist');
      } on EmbeddingModelMismatch {
        // Expected — the index for model A is not installed yet.
      }

      // A first recovery pass while model A is still uninstalled
      // reports the failure but does not drain.
      final beforeFix = coordinator.recoverPending();
      expect(beforeFix.scanned, equals(1));
      expect(beforeFix.succeeded, equals(0));
      expect(beforeFix.failures, hasLength(1));
      expect(beforeFix.failures.single.error, isA<EmbeddingModelMismatch>());
      expect(coordinator.pendingCount(), equals(1));

      // Operator installs the missing index.
      table.installIndex(modelId: _modelA, dims: _dims);

      // Recovery converges on the next pass.
      final afterFix = coordinator.recoverPending();
      expect(afterFix.scanned, equals(1));
      expect(afterFix.succeeded, equals(1));
      expect(afterFix.failures, isEmpty);
      expect(coordinator.pendingCount(), equals(0));

      // Vector is now queryable.
      final matches = table.queryNearest(
        query: embedding,
        k: 3,
        modelId: _modelA,
      );
      expect(matches, hasLength(1));
      expect(matches.single.nodeId, equals(nodeId));
      expect(matches.single.distance, closeTo(0.0, 1e-6));
    });

    test('cross-model isolation: identical vector inserted under '
        'model A is never returned under model B (no silent fallback)',
        () {
      table.installIndex(modelId: _modelA, dims: _dims);
      table.installIndex(modelId: _modelB, dims: _dims);

      final v = _vec(4);
      table.insertVector(nodeId: 'n_a_only', vector: v, modelId: _modelA);

      // Same query vector under each model's index.
      final inA = table.queryNearest(query: v, k: 5, modelId: _modelA);
      final inB = table.queryNearest(query: v, k: 5, modelId: _modelB);

      expect(inA.map((m) => m.nodeId).toList(),
          equals(<String>['n_a_only']));
      expect(inB, isEmpty,
          reason: 'spec § 10.4 — refuses to mix incompatible vectors '
              'in a single index');
    });

    test('dims mismatch surfaces a distinct refusal '
        '(EmbeddingDimsMismatch, not EmbeddingModelMismatch) — '
        'operator needs the two apart', () {
      table.installIndex(modelId: _modelA, dims: _dims);

      // Payload uses the installed model id but the wrong dim. The
      // applier propagates the dims refusal verbatim.
      final wrongDimVec = Vec.fromList(<double>[1, 2, 3, 4, 5]); // 5-d
      expect(wrongDimVec.dimension, equals(5));

      final write = PendingVectorWrite(
        nodeId: 'n_dims_mismatch',
        embeddingModelId: _modelA,
        payloadBlob: wrongDimVec.toBlob(),
        payloadDims: 5,
        enqueuedAt: BrainTime.utc(2026, 5, 30, 12),
      );

      expect(
        () => applier.apply(write),
        throwsA(isA<EmbeddingDimsMismatch>()
            .having((e) => e.expectedDims, 'expectedDims', equals(_dims))
            .having((e) => e.actualDims, 'actualDims', equals(5))),
      );
    });

    test('a corrupt payload blob (odd length) propagates ArgumentError '
        'from Vec.fromBlob without touching vectors.db', () {
      table.installIndex(modelId: _modelA, dims: _dims);

      // Float32 wire format requires length divisible by 4; 7 bytes is
      // intentionally corrupt. The applier does not catch this — it
      // surfaces as a coordinator-visible exception so the pending
      // row stays for operator inspection.
      final corrupt = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7]);
      final write = PendingVectorWrite(
        nodeId: 'n_corrupt',
        embeddingModelId: _modelA,
        payloadBlob: corrupt,
        payloadDims: _dims,
        enqueuedAt: BrainTime.utc(2026, 5, 30, 12),
      );

      expect(
        () => applier.apply(write),
        throwsA(isA<ArgumentError>()),
      );

      // The vectors.db side stayed empty — the refusal happened
      // before any backend write.
      final matches = table.queryNearest(
        query: _vec(0),
        k: 5,
        modelId: _modelA,
      );
      expect(matches, isEmpty);
    });
  });
}
