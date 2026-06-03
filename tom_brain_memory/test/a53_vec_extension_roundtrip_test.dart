// A.53 — Extension load + vec query roundtrip (integration).
//
// Plan step A.53:
//   "Tests: extension load + vec query roundtrip; degraded-mode recall
//    when extension missing; embedding-model mismatch rejection."
//
// What A.50 / A.51 / A.52 already covered:
//   * A.50  — the loader in isolation: every outcome branch, side-
//             effect discipline, the wiring helper's event-emission
//             policy.
//   * A.51  — the `VectorTable` in isolation: meta-table lifecycle,
//             install / insert / query / remove against an in-memory
//             `vectors.db` using `PlainBlobTableBackend`.
//   * A.52  — the persister → coordinator → applier → vector_table
//             chain for nodes with embeddings.
//
// What A.53 adds (this file):
//   * The **integration seam** between the loader and the vector
//     table. A.50 returns a typed `VecExtensionLoadResult` but does
//     not verify that, on `loaded`, a vector index can be installed
//     and a roundtrip insert / query / remove succeeds against the
//     same `Sqlite3` instance. A.53 exercises that boundary as one
//     test scenario: synthetic-loader → install → insert → query →
//     remove → re-query → empty.
//   * The full **boot → persist-with-vector → recall** chain when the
//     loader is `loaded`. A.52 wires the coordinator into the
//     persister but doesn't reference the loader at all; A.53
//     composes the open() story end-to-end: wiring helper returns
//     `loaded` with zero events emitted → coordinator persists a
//     pending vector write → applier writes into `vectors.db` →
//     queryNearest finds it at distance 0 → pending row is drained.
//
// Why we still use `PlainBlobTableBackend` (and not `vec0`) here:
//   See `vec_extension_loader.dart` Q-A.50.2 and `vector_table.dart`
//   file header: no vec0 shared library ships in `tom_binaries/` yet
//   (`find tom_binaries -name 'vec0*'` returns nothing as of A.53).
//   A real-binary roundtrip is the obvious next step once the binary
//   is published. The A.53 contract is "the seams compose"; the
//   substrate the seams compose against is interchangeable. The vec0
//   syntax shape is already locked by the A.51
//   `Vec0VirtualTableBackend (SQL composition)` test group.
//
// Open question Q-A.53.1 (logged in
// `prototype_implementation_questions.md`): "Should A.53 require a
// real vec0 binary on disk?" Default: NO — use injected hooks +
// PlainBlobTableBackend; defer real-binary integration to a later
// step when the binary is published into `tom_binaries/`.

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, FixedClock, Vec;

const String _modelId = 'A.53/synthetic-loaded-model';
const int _dims = 8;

Pointer<Void> _fakeEntrypoint(int address) =>
    Pointer<Void>.fromAddress(address);

/// Builds a `MemoryConfig` whose `extensionPath` points at any file
/// that exists on disk — the file is *not* required to be a real vec0
/// binary because the injected `openDynamicLibrary` / `lookupSymbol` /
/// `registerExtension` hooks short-circuit the FFI side.
MemoryConfig _configWithExistingStubFile() {
  final dir = Directory.systemTemp.createTempSync('tbm_a53_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final stub = File('${dir.path}${Platform.pathSeparator}fake_vec0.bin');
  stub.writeAsStringSync('not-actually-a-binary');
  return MemoryConfig.forTesting(root: dir.path, extensionPath: stub.path);
}

/// A loader whose injected hooks always succeed — it lands on
/// `VecLoadOutcome.loaded` without touching FFI. Used as the
/// "synthetic loaded" boot in every A.53 integration test.
VecExtensionLoader _syntheticLoadedLoader() => VecExtensionLoader(
      openDynamicLibrary: (_) => DynamicLibrary.process(),
      lookupSymbol: (_, _) => _fakeEntrypoint(0xA53),
      registerExtension: (_, _) {},
    );

Vec _vec(int seed) => Vec.fromList(<double>[
      for (var i = 0; i < _dims; i++) (seed + i) * 0.125,
    ]);

void main() {
  group('A.53 extension load + vec query roundtrip', () {
    late Database vectorsDb;

    setUp(() {
      vectorsDb = sqlite3.openInMemory();
    });

    tearDown(() {
      vectorsDb.dispose();
    });

    test('synthetic loaded boot → install → insert → query → remove '
        'is a clean roundtrip', () {
      final result = loadVecExtensionOrRefuseToBoot(
        sqlite: sqlite3,
        config: _configWithExistingStubFile(),
        loader: _syntheticLoadedLoader(),
      );

      expect(result.isLoaded, isTrue,
          reason: 'A.53 roundtrip premise — boot must reach loaded');

      final table = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 12)),
      );

      // Install
      final info = table.installIndex(modelId: _modelId, dims: _dims);
      expect(info.modelId, equals(_modelId));
      expect(info.dims, equals(_dims));

      // Insert
      final v = _vec(1);
      table.insertVector(nodeId: 'n_seed', vector: v, modelId: _modelId);

      // Query — distance 0 against itself.
      final matches = table.queryNearest(
        query: v,
        k: 5,
        modelId: _modelId,
      );
      expect(matches, hasLength(1));
      expect(matches.single.nodeId, equals('n_seed'));
      expect(matches.single.distance, closeTo(0.0, 1e-6));

      // Remove + re-query — index empty.
      table.removeVector(nodeId: 'n_seed', modelId: _modelId);
      final after = table.queryNearest(
        query: v,
        k: 5,
        modelId: _modelId,
      );
      expect(after, isEmpty);
    });

    test('end-to-end: synthetic loaded boot → coordinator persist '
        'with embedding → applier writes vectors.db → queryNearest '
        'finds the row; pending row is drained', () {
      // Boot — synthetic-loaded.
      final result = loadVecExtensionOrRefuseToBoot(
        sqlite: sqlite3,
        config: _configWithExistingStubFile(),
        loader: _syntheticLoadedLoader(),
      );
      expect(result.isLoaded, isTrue);

      // memory.db with the canonical schema applied — gives us the
      // `nodes` and `pending_vector_writes` tables the coordinator
      // writes through.
      final memoryDb = sqlite3.openInMemory();
      addTearDown(memoryDb.dispose);
      applySchemaV1(memoryDb);

      // Vector store assembly (stand-in backend per Q-A.53.1).
      final table = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 13)),
      );
      table.installIndex(modelId: _modelId, dims: _dims);

      final applier = VectorTableApplier(vectorTable: table);
      final coordinator = TwoDbCoordinator(
        memoryDb: memoryDb,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 13)),
      );

      const nodeId = 'a53-e2e-node-1';
      final embedding = _vec(7);

      coordinator.persistNodeWithVector(
        nodeId: nodeId,
        writeNode: (db) {
          // Minimal valid `nodes` row — every NOT NULL column gets a
          // value; the embedding lives in `vectors.db`, not here.
          db.execute(
            'INSERT INTO nodes (id, type_name, scope_json, attrs_json, '
            'status, created_at_ms, created_at_iso, updated_at_ms, '
            'updated_at_iso, embedding_model_id) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              nodeId,
              'Claim',
              '{}',
              '{"text":"a.53 e2e"}',
              'active',
              0,
              '2026-05-30T13:00:00.000Z',
              0,
              '2026-05-30T13:00:00.000Z',
              _modelId,
            ],
          );
        },
        vector: PendingVectorWritePayload(
          embeddingModelId: _modelId,
          payloadBlob: embedding.toBlob(),
          payloadDims: _dims,
        ),
      );

      // Pending row drained.
      expect(coordinator.pendingCount(), equals(0));

      // Node row is committed in memory.db.
      final nodes = memoryDb.select(
        'SELECT id, embedding_model_id FROM nodes WHERE id = ?',
        <Object?>[nodeId],
      );
      expect(nodes, hasLength(1));
      expect(nodes.single['embedding_model_id'], equals(_modelId));

      // queryNearest finds the persisted vector at distance 0.
      final matches = table.queryNearest(
        query: embedding,
        k: 3,
        modelId: _modelId,
      );
      expect(matches, hasLength(1));
      expect(matches.single.nodeId, equals(nodeId));
      expect(matches.single.distance, closeTo(0.0, 1e-6));
    });
  });
}
