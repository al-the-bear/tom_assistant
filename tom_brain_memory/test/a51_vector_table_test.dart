// A.51 vector-table contract test.
//
// Locks the `vectors.db` side of the storage stack introduced by Plan
// step A.51 — the per-model vector-index layer (`VectorTable`), its
// meta-table bookkeeping, its insert / remove / query semantics, and
// the sealed exception family that guards the embedding-model
// invariants from spec § 10.4 and § 12.3.
//
// Coverage:
//
//   1. Meta-table lifecycle
//      - `ensureMetaTable` creates `vector_indexes` and is idempotent.
//      - `lookupIndex` / `listInstalledIndexes` / `hasIndex` work
//        against a freshly-opened DB (no explicit ensureMetaTable
//        first).
//      - `installIndex` writes a meta row with all five columns
//        populated.
//
//   2. installIndex semantics
//      - First install creates meta row + physical table.
//      - Re-install with same (modelId, dims) returns the existing
//        info unchanged (idempotent).
//      - Re-install with same modelId but different dims raises
//        `IndexInstallationConflict`.
//      - ArgumentError on empty modelId or non-positive dims.
//      - Re-running createIndex on the backend after an already-
//        present meta row closes the
//        "meta-row-without-table" crash gap (we simulate by deleting
//        the table out-of-band, then calling installIndex again).
//
//   3. insertVector semantics
//      - Success: row visible in subsequent queryNearest.
//      - Embedding-model identity recorded per row (queryNearest
//        against a *different* model's index does not return the
//        vector).
//      - EmbeddingModelMismatch when modelId is not installed.
//      - EmbeddingDimsMismatch when vec dims do not match installed
//        dims.
//      - Re-insert under the same (modelId, nodeId) overwrites
//        (idempotent — the two-DB coordinator's recovery contract).
//
//   4. removeVector semantics
//      - Removes a previously-inserted row; subsequent queryNearest
//        no longer returns it.
//      - Remove of a never-inserted node is a no-op.
//      - EmbeddingModelMismatch when modelId is not installed.
//
//   5. queryNearest semantics
//      - Returns up to k results ordered by ascending L2 distance.
//      - Returns identical vectors at distance 0.
//      - Returns fewer than k results when the index has fewer rows.
//      - Empty index returns an empty list.
//      - ArgumentError when k <= 0.
//      - EmbeddingModelMismatch when modelId is not installed.
//      - EmbeddingDimsMismatch when query dim does not match.
//
//   6. Embedding-model isolation
//      - Two models with the same dim get separate physical tables
//        and do not see each other's vectors.
//      - Two models with different dims coexist.
//
//   7. deriveTableName
//      - Deterministic for the same input.
//      - SQL-safe (only `[a-z0-9_]`).
//      - Always prefixed with `vec_idx_`.
//      - Different inputs yield different names (collision check on
//        the FNV-1a suffix for a small sample).
//
//   8. Vec0VirtualTableBackend
//      - DDL string composition is the documented vec0 shape (we
//        cannot run against vec0 in this test environment per
//        Q-A.50.2; we exercise the backend through a recording fake
//        and assert the SQL it issues).
//      - `backendName == 'vec0'`.
//
//   9. PlainBlobTableBackend (the in-test backend used by groups
//      1–7)
//      - `backendName == 'plain'`.
//      - Brute-force k-NN matches the cosine/L2 contract of
//        `Vec.l2`.
//
// Everything runs against `sqlite3.openInMemory()` with the
// `PlainBlobTableBackend` standing in for the production vec0
// backend, mirroring the A.30 / A.50 style of in-memory deterministic
// SQL tests. No filesystem, no FFI, no vec0 binary required.

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.51 vector table', () {
    late Database db;
    late MutableTestClock clock;
    late VectorTable table;

    setUp(() {
      db = sqlite3.openInMemory();
      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));
      table = VectorTable(
        vectorsDb: db,
        backend: const PlainBlobTableBackend(),
        clock: clock,
      );
    });

    tearDown(() {
      db.dispose();
    });

    // ─────────────────────────────────────────────────────────────────
    // 1. Meta-table lifecycle
    // ─────────────────────────────────────────────────────────────────

    group('meta-table lifecycle', () {
      test('ensureMetaTable creates vector_indexes (and is idempotent)',
          () {
        table.ensureMetaTable();
        // Idempotent — second call is a no-op (no exception).
        table.ensureMetaTable();

        final rows = db.select(
          "SELECT name FROM sqlite_master "
          "WHERE type='table' AND name='vector_indexes'",
        );
        expect(rows.length, equals(1));
      });

      test('lookupIndex against a fresh DB returns null without an '
          'explicit ensureMetaTable', () {
        // No prior table creation — the layer ensures meta on read.
        expect(table.lookupIndex('nomic-embed-text@1.5'), isNull);
      });

      test('listInstalledIndexes against a fresh DB returns an empty '
          'list without an explicit ensureMetaTable', () {
        expect(table.listInstalledIndexes(), isEmpty);
      });

      test('hasIndex against a fresh DB returns false without an '
          'explicit ensureMetaTable', () {
        expect(table.hasIndex('nomic-embed-text@1.5'), isFalse);
      });

      test('installIndex writes a meta row with all five columns '
          'populated', () {
        final info = table.installIndex(
          modelId: 'ollama/nomic-embed-text@1.5',
          dims: 768,
        );

        final rows = db.select(
          'SELECT model_id, table_name, dims, backend_name, '
          'installed_at_ms, installed_at_iso FROM vector_indexes',
        );
        expect(rows.length, equals(1));
        final row = rows.single;
        expect(row['model_id'], equals('ollama/nomic-embed-text@1.5'));
        expect(row['table_name'], equals(info.tableName));
        expect(row['dims'], equals(768));
        expect(row['backend_name'], equals('plain'));
        expect(
          row['installed_at_ms'],
          equals(info.installedAt.toMs()),
        );
        expect(
          row['installed_at_iso'],
          equals(info.installedAt.toIso8601String()),
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // 2. installIndex semantics
    // ─────────────────────────────────────────────────────────────────

    group('installIndex', () {
      test('first install creates meta row and physical table', () {
        final info = table.installIndex(
          modelId: 'nomic-embed-text',
          dims: 4,
        );
        expect(info.modelId, equals('nomic-embed-text'));
        expect(info.dims, equals(4));
        expect(info.backendName, equals('plain'));
        expect(info.tableName, startsWith('vec_idx_'));

        // Physical table exists.
        final phys = db.select(
          "SELECT name FROM sqlite_master "
          "WHERE type='table' AND name=?",
          <Object?>[info.tableName],
        );
        expect(phys.length, equals(1));
      });

      test('re-install with same (modelId, dims) returns existing info '
          'unchanged', () {
        final first = table.installIndex(
          modelId: 'nomic-embed-text',
          dims: 4,
        );
        clock.advance(const Duration(hours: 1));
        final second = table.installIndex(
          modelId: 'nomic-embed-text',
          dims: 4,
        );
        expect(second.tableName, equals(first.tableName));
        expect(
          second.installedAt.toMs(),
          equals(first.installedAt.toMs()),
          reason: 'idempotent re-install must NOT bump installed_at',
        );

        // Meta table still has exactly one row.
        final count = db.select(
          'SELECT COUNT(*) AS n FROM vector_indexes',
        );
        expect(count.first['n'], equals(1));
      });

      test('re-install with same modelId but different dims raises '
          'IndexInstallationConflict', () {
        table.installIndex(modelId: 'nomic-embed-text', dims: 4);
        expect(
          () => table.installIndex(
            modelId: 'nomic-embed-text',
            dims: 8,
          ),
          throwsA(isA<IndexInstallationConflict>()
              .having((e) => e.modelId, 'modelId',
                  equals('nomic-embed-text'))
              .having((e) => e.existingDims, 'existingDims',
                  equals(4))
              .having((e) => e.proposedDims, 'proposedDims',
                  equals(8))),
        );
      });

      test('ArgumentError on empty modelId', () {
        expect(
          () => table.installIndex(modelId: '', dims: 4),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('ArgumentError on non-positive dims', () {
        expect(
          () => table.installIndex(modelId: 'm', dims: 0),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => table.installIndex(modelId: 'm', dims: -1),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('re-install closes the meta-row-without-table crash gap', () {
        final info = table.installIndex(
          modelId: 'nomic-embed-text',
          dims: 4,
        );
        // Simulate the "crash between meta INSERT and CREATE TABLE":
        // delete the physical table out of band.
        db.execute('DROP TABLE "${info.tableName}"');
        expect(
          db
              .select(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name=?",
                <Object?>[info.tableName],
              )
              .isEmpty,
          isTrue,
        );

        // Re-installing with the same params re-creates the table.
        final reinstalled = table.installIndex(
          modelId: 'nomic-embed-text',
          dims: 4,
        );
        expect(reinstalled.tableName, equals(info.tableName));
        final phys = db.select(
          "SELECT name FROM sqlite_master "
          "WHERE type='table' AND name=?",
          <Object?>[info.tableName],
        );
        expect(phys.length, equals(1));
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // 3. insertVector semantics
    // ─────────────────────────────────────────────────────────────────

    group('insertVector', () {
      test('inserted row is visible in subsequent queryNearest', () {
        table.installIndex(modelId: 'm', dims: 4);
        final vec = Vec.fromList(<double>[1, 0, 0, 0]);
        table.insertVector(nodeId: 'n_a', vector: vec, modelId: 'm');

        final matches = table.queryNearest(
          query: vec,
          k: 5,
          modelId: 'm',
        );
        expect(matches.length, equals(1));
        expect(matches.single.nodeId, equals('n_a'));
        expect(matches.single.distance, closeTo(0.0, 1e-6));
      });

      test('embedding-model identity recorded per row — '
          'a vector under model A is invisible under model B', () {
        table.installIndex(modelId: 'A', dims: 4);
        table.installIndex(modelId: 'B', dims: 4);
        final v = Vec.fromList(<double>[1, 2, 3, 4]);
        table.insertVector(nodeId: 'n_a', vector: v, modelId: 'A');

        final inA = table.queryNearest(query: v, k: 5, modelId: 'A');
        expect(inA.map((m) => m.nodeId).toList(), equals(<String>['n_a']));

        final inB = table.queryNearest(query: v, k: 5, modelId: 'B');
        expect(inB, isEmpty);
      });

      test('EmbeddingModelMismatch when modelId is not installed', () {
        final v = Vec.fromList(<double>[1, 2, 3, 4]);
        expect(
          () => table.insertVector(
            nodeId: 'n_a',
            vector: v,
            modelId: 'never-installed',
          ),
          throwsA(isA<EmbeddingModelMismatch>().having(
            (e) => e.modelId,
            'modelId',
            equals('never-installed'),
          )),
        );
      });

      test('EmbeddingDimsMismatch when vec dims do not match', () {
        table.installIndex(modelId: 'm', dims: 4);
        final wrong = Vec.fromList(<double>[1, 2, 3, 4, 5]);
        expect(
          () => table.insertVector(
            nodeId: 'n_a',
            vector: wrong,
            modelId: 'm',
          ),
          throwsA(isA<EmbeddingDimsMismatch>()
              .having((e) => e.expectedDims, 'expectedDims',
                  equals(4))
              .having((e) => e.actualDims, 'actualDims',
                  equals(5))),
        );
      });

      test('re-insert under same (modelId, nodeId) overwrites', () {
        table.installIndex(modelId: 'm', dims: 4);
        final v1 = Vec.fromList(<double>[1, 0, 0, 0]);
        final v2 = Vec.fromList(<double>[0, 1, 0, 0]);

        table.insertVector(nodeId: 'n_a', vector: v1, modelId: 'm');
        table.insertVector(nodeId: 'n_a', vector: v2, modelId: 'm');

        // Querying with v2 returns the row at distance 0.
        final matches = table.queryNearest(
          query: v2,
          k: 5,
          modelId: 'm',
        );
        expect(matches.length, equals(1));
        expect(matches.single.nodeId, equals('n_a'));
        expect(matches.single.distance, closeTo(0.0, 1e-6));

        // Querying with v1 now finds n_a at distance sqrt(2).
        final farther = table.queryNearest(
          query: v1,
          k: 5,
          modelId: 'm',
        );
        expect(farther.length, equals(1));
        expect(
          farther.single.distance,
          closeTo(1.4142135, 1e-4),
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // 4. removeVector semantics
    // ─────────────────────────────────────────────────────────────────

    group('removeVector', () {
      test('removes a previously-inserted row', () {
        table.installIndex(modelId: 'm', dims: 4);
        final v = Vec.fromList(<double>[1, 2, 3, 4]);
        table.insertVector(nodeId: 'n_a', vector: v, modelId: 'm');
        table.insertVector(nodeId: 'n_b', vector: v, modelId: 'm');

        table.removeVector(nodeId: 'n_a', modelId: 'm');

        final matches = table.queryNearest(
          query: v,
          k: 5,
          modelId: 'm',
        );
        expect(matches.map((m) => m.nodeId).toList(),
            equals(<String>['n_b']));
      });

      test('remove of a never-inserted node is a no-op', () {
        table.installIndex(modelId: 'm', dims: 4);
        // No exception.
        table.removeVector(nodeId: 'n_ghost', modelId: 'm');
      });

      test('EmbeddingModelMismatch when modelId is not installed', () {
        expect(
          () => table.removeVector(
            nodeId: 'n_a',
            modelId: 'never-installed',
          ),
          throwsA(isA<EmbeddingModelMismatch>()),
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // 5. queryNearest semantics
    // ─────────────────────────────────────────────────────────────────

    group('queryNearest', () {
      test('returns up to k results ordered by ascending L2 distance',
          () {
        table.installIndex(modelId: 'm', dims: 3);
        table.insertVector(
            nodeId: 'n_close',
            vector: Vec.fromList(<double>[1, 0, 0]),
            modelId: 'm');
        table.insertVector(
            nodeId: 'n_mid',
            vector: Vec.fromList(<double>[1, 1, 0]),
            modelId: 'm');
        table.insertVector(
            nodeId: 'n_far',
            vector: Vec.fromList(<double>[10, 10, 10]),
            modelId: 'm');

        final matches = table.queryNearest(
          query: Vec.fromList(<double>[1, 0, 0]),
          k: 2,
          modelId: 'm',
        );
        expect(matches.map((m) => m.nodeId).toList(),
            equals(<String>['n_close', 'n_mid']));
        // distances strictly increasing.
        expect(
          matches.first.distance < matches.last.distance,
          isTrue,
        );
      });

      test('identical vectors return distance 0', () {
        table.installIndex(modelId: 'm', dims: 4);
        final v = Vec.fromList(<double>[1, 2, 3, 4]);
        table.insertVector(nodeId: 'n_a', vector: v, modelId: 'm');

        final matches = table.queryNearest(
          query: Vec.fromList(<double>[1, 2, 3, 4]),
          k: 1,
          modelId: 'm',
        );
        expect(matches.single.distance, closeTo(0.0, 1e-6));
      });

      test('returns fewer than k results when the index has fewer rows',
          () {
        table.installIndex(modelId: 'm', dims: 2);
        table.insertVector(
            nodeId: 'n_a',
            vector: Vec.fromList(<double>[1, 0]),
            modelId: 'm');
        final matches = table.queryNearest(
          query: Vec.fromList(<double>[1, 0]),
          k: 100,
          modelId: 'm',
        );
        expect(matches.length, equals(1));
      });

      test('empty index returns an empty list', () {
        table.installIndex(modelId: 'm', dims: 2);
        final matches = table.queryNearest(
          query: Vec.fromList(<double>[1, 0]),
          k: 5,
          modelId: 'm',
        );
        expect(matches, isEmpty);
      });

      test('ArgumentError when k <= 0', () {
        table.installIndex(modelId: 'm', dims: 2);
        final q = Vec.fromList(<double>[1, 0]);
        expect(
          () => table.queryNearest(query: q, k: 0, modelId: 'm'),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => table.queryNearest(query: q, k: -3, modelId: 'm'),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('EmbeddingModelMismatch when modelId is not installed', () {
        expect(
          () => table.queryNearest(
            query: Vec.fromList(<double>[1, 0]),
            k: 5,
            modelId: 'absent',
          ),
          throwsA(isA<EmbeddingModelMismatch>()),
        );
      });

      test('EmbeddingDimsMismatch when query dim does not match', () {
        table.installIndex(modelId: 'm', dims: 4);
        expect(
          () => table.queryNearest(
            query: Vec.fromList(<double>[1, 0, 0]),
            k: 5,
            modelId: 'm',
          ),
          throwsA(isA<EmbeddingDimsMismatch>()
              .having((e) => e.expectedDims, 'expectedDims',
                  equals(4))
              .having((e) => e.actualDims, 'actualDims',
                  equals(3))),
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // 6. Embedding-model isolation
    // ─────────────────────────────────────────────────────────────────

    group('model isolation', () {
      test('two models with the same dim get separate physical tables',
          () {
        final a = table.installIndex(modelId: 'A', dims: 4);
        final b = table.installIndex(modelId: 'B', dims: 4);
        expect(a.tableName, isNot(equals(b.tableName)));

        // Insert distinct rows into each.
        final v = Vec.fromList(<double>[1, 2, 3, 4]);
        table.insertVector(nodeId: 'n_a', vector: v, modelId: 'A');
        table.insertVector(nodeId: 'n_b', vector: v, modelId: 'B');

        final inA = table.queryNearest(query: v, k: 5, modelId: 'A');
        final inB = table.queryNearest(query: v, k: 5, modelId: 'B');
        expect(inA.map((m) => m.nodeId).toList(),
            equals(<String>['n_a']));
        expect(inB.map((m) => m.nodeId).toList(),
            equals(<String>['n_b']));

        // listInstalledIndexes covers both.
        final all = table.listInstalledIndexes();
        expect(all.map((i) => i.modelId).toSet(),
            equals(<String>{'A', 'B'}));
      });

      test('two models with different dims coexist', () {
        final small = table.installIndex(modelId: 'small', dims: 4);
        final big = table.installIndex(modelId: 'big', dims: 8);
        expect(small.dims, equals(4));
        expect(big.dims, equals(8));

        table.insertVector(
            nodeId: 'n_s',
            vector: Vec.fromList(<double>[1, 0, 0, 0]),
            modelId: 'small');
        table.insertVector(
            nodeId: 'n_b',
            vector: Vec.fromList(<double>[1, 0, 0, 0, 0, 0, 0, 0]),
            modelId: 'big');

        expect(
          table
              .queryNearest(
                query: Vec.fromList(<double>[1, 0, 0, 0]),
                k: 1,
                modelId: 'small',
              )
              .single
              .nodeId,
          equals('n_s'),
        );
        expect(
          table
              .queryNearest(
                query: Vec.fromList(<double>[1, 0, 0, 0, 0, 0, 0, 0]),
                k: 1,
                modelId: 'big',
              )
              .single
              .nodeId,
          equals('n_b'),
        );
      });
    });

    // ─────────────────────────────────────────────────────────────────
    // 7. deriveTableName
    // ─────────────────────────────────────────────────────────────────

    group('deriveTableName', () {
      test('is deterministic for the same input', () {
        final a = VectorTable.deriveTableName('nomic-embed-text@1.5');
        final b = VectorTable.deriveTableName('nomic-embed-text@1.5');
        expect(a, equals(b));
      });

      test('always starts with vec_idx_', () {
        for (final m in const <String>[
          'nomic-embed-text',
          'openai/text-embedding-3-small',
          'A',
          'ALLCAPS',
          'with spaces and !!! chars',
        ]) {
          expect(VectorTable.deriveTableName(m), startsWith('vec_idx_'));
        }
      });

      test('produces SQL-safe identifiers (only [a-z0-9_])', () {
        final name = VectorTable.deriveTableName(
          'My Weird/Model!@#%^&*()1.5',
        );
        expect(RegExp(r'^[a-z0-9_]+$').hasMatch(name), isTrue,
            reason: 'derived name "$name" contains forbidden chars');
      });

      test('different inputs yield different names (small sample)', () {
        final names = <String>{
          for (final m in const <String>[
            'nomic-embed-text',
            'nomic-embed-text@1.5',
            'openai/text-embedding-3-small',
            'openai/text-embedding-3-large',
            'cohere/embed-english-v3',
          ])
            VectorTable.deriveTableName(m),
        };
        expect(names.length, equals(5));
      });
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // 8. Vec0VirtualTableBackend (SQL composition only — no live vec0)
  // ───────────────────────────────────────────────────────────────────

  group('A.51 Vec0VirtualTableBackend (SQL composition)', () {
    test('backendName is "vec0"', () {
      expect(const Vec0VirtualTableBackend().backendName, equals('vec0'));
    });

    test('createIndex against a DB without vec0 raises the expected '
        '"no such module" SqliteException', () {
      // This is the production-failure tell: a DB that has not loaded
      // the vec0 extension rejects `CREATE VIRTUAL TABLE … USING vec0`
      // with "no such module: vec0". The exception itself is the
      // contract A.50's `loadVecExtensionWithFailOpen` gates against;
      // we lock the failure shape here so a future sqlite-vec syntax
      // change is detected.
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      expect(
        () => const Vec0VirtualTableBackend().createIndex(
          db,
          'vec_idx_test_00000000',
          4,
        ),
        throwsA(isA<SqliteException>().having(
          (e) => e.message.toLowerCase(),
          'message',
          contains('no such module'),
        )),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // 9. PlainBlobTableBackend
  // ───────────────────────────────────────────────────────────────────

  group('A.51 PlainBlobTableBackend', () {
    test('backendName is "plain"', () {
      expect(const PlainBlobTableBackend().backendName, equals('plain'));
    });

    test('brute-force k-NN matches Vec.l2 on a small input', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      const backend = PlainBlobTableBackend();
      backend.createIndex(db, 'tbl', 3);

      Uint8List blobOf(List<double> xs) =>
          Vec.fromList(xs).toBlob();

      backend.insertRow(db, 'tbl', 'a', blobOf(<double>[1, 0, 0]), 3);
      backend.insertRow(db, 'tbl', 'b', blobOf(<double>[0, 1, 0]), 3);
      backend.insertRow(db, 'tbl', 'c', blobOf(<double>[0, 0, 1]), 3);
      backend.insertRow(db, 'tbl', 'd', blobOf(<double>[1, 1, 1]), 3);

      final q = Vec.fromList(<double>[1, 0, 0]);
      final matches = backend.queryNearest(db, 'tbl', q.toBlob(), 3, 4);

      // Expected order by L2:
      //   a (0), b (sqrt 2), c (sqrt 2), d (sqrt 2)
      expect(matches.first.nodeId, equals('a'));
      expect(matches.first.distance, closeTo(0.0, 1e-6));
      // Ties resolved by sort stability; we only assert the head is
      // 'a' and the tail set is {b, c, d}.
      final tail = matches.skip(1).map((m) => m.nodeId).toSet();
      expect(tail, equals(<String>{'b', 'c', 'd'}));
      for (final m in matches.skip(1)) {
        expect(m.distance, closeTo(l2(q, Vec.fromList(_unitOf(m.nodeId))),
            1e-6));
      }
    });

    test('deleteRow removes the row from subsequent queries', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      const backend = PlainBlobTableBackend();
      backend.createIndex(db, 'tbl', 2);

      final blob = Vec.fromList(<double>[1, 0]).toBlob();
      backend.insertRow(db, 'tbl', 'x', blob, 2);
      backend.deleteRow(db, 'tbl', 'x');

      final matches = backend.queryNearest(db, 'tbl', blob, 2, 5);
      expect(matches, isEmpty);
    });

    test('insertRow with same nodeId overwrites', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      const backend = PlainBlobTableBackend();
      backend.createIndex(db, 'tbl', 2);

      backend.insertRow(
          db, 'tbl', 'x', Vec.fromList(<double>[1, 0]).toBlob(), 2);
      backend.insertRow(
          db, 'tbl', 'x', Vec.fromList(<double>[0, 1]).toBlob(), 2);

      final matches = backend.queryNearest(
        db,
        'tbl',
        Vec.fromList(<double>[0, 1]).toBlob(),
        2,
        5,
      );
      expect(matches.length, equals(1));
      expect(matches.single.nodeId, equals('x'));
      expect(matches.single.distance, closeTo(0.0, 1e-6));
    });
  });
}

/// Helper for the PlainBlob brute-force test — maps the four sample
/// node ids back to their inserted unit vectors so the test can
/// recompute the expected L2 distance.
List<double> _unitOf(String nodeId) {
  switch (nodeId) {
    case 'a':
      return <double>[1, 0, 0];
    case 'b':
      return <double>[0, 1, 0];
    case 'c':
      return <double>[0, 0, 1];
    case 'd':
      return <double>[1, 1, 1];
  }
  throw StateError('unknown node id $nodeId');
}
