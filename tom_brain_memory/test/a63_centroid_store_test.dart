// A.63 centroid-store contract test.
//
// Locks the `memory.db`-side centroid storage surface introduced by
// Plan step A.63 — the `centroids` table's write path
// (`CentroidStore.update`), its read helpers (`read`, `readAll`,
// `listKeys`, `count`), the key-namespacing helpers (`keyForNodeType`,
// `keyForProcedure`, `targetOfKey`), and the input-validation
// contract.
//
// Coverage:
//
//   1. Key-namespacing helpers (pure)
//      - `keyForNodeType` / `keyForProcedure` produce the canonical
//        `'NodeType:Foo'` / `'Procedure:bar_v1'` form.
//      - Both reject the empty string with ArgumentError.
//      - `targetOfKey` reverses the namespace; unknown prefix → null.
//
//   2. read against an empty table
//      - Returns null (cold-start).
//      - count() is 0; listKeys() / readAll() are empty.
//
//   3. update — insert path
//      - Stamps `updated_at` from the injected clock (not from the
//        caller-supplied record).
//      - Stores the model id, the centroid bytes, the dims, and the
//        example count.
//      - The returned record matches a subsequent read.
//      - count() advances by 1.
//
//   4. update — upsert path
//      - Re-update on the same key wholesale-replaces every field
//        except `for_key` (model id, blob, dims, example count,
//        updated_at all change).
//      - count() stays at 1.
//
//   5. Argument validation on update
//      - Empty `forKey` → ArgumentError.
//      - Empty `embeddingModelId` → ArgumentError.
//      - Negative `exampleCount` → ArgumentError.
//
//   6. Round-trip integrity
//      - Vec.toBlob / Vec.fromBlob round-trip preserves every
//        element (closeTo within 0 — float32 → float32 → float32 is
//        bit-identical).
//
//   7. Multi-key listings
//      - listKeys(prefix: nodeTypeKeyPrefix) returns only NodeType:*
//        keys, alphabetically.
//      - listKeys(prefix: procedureKeyPrefix) returns only Procedure:*
//        keys, alphabetically.
//      - listKeys() returns every key, alphabetically (NodeType:*
//        keys sort before Procedure:* keys by string order).
//      - readAll(prefix: ...) mirrors listKeys's filtering.
//
//   8. Concurrent-update isolation
//      - A reader connection opened on the same `:memory:` URI sees
//        either the pre-update or post-update row, never a torn read.
//        With `:memory:` (no WAL) we use one connection and assert
//        the per-statement transactional guarantee — the row is
//        either present-old or present-new across the `update`
//        boundary, never absent or half-written. This is the property
//        A.66 names ("concurrent `updateCentroid` does not affect an
//        in-flight recall").
//
// Every test runs against `sqlite3.openInMemory()` with
// `applySchemaV1(db)` so the `centroids` table exists; this mirrors
// the A.30 / A.51 / A.55 in-memory test pattern.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.63 CentroidStore', () {
    late Database db;
    late MutableTestClock clock;
    late CentroidStore store;

    setUp(() {
      db = sqlite3.openInMemory();
      applySchemaV1(db);
      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));
      store = CentroidStore(memoryDb: db, clock: clock);
    });

    tearDown(() {
      db.dispose();
    });

    // ───────────────────────────────────────────────────────────────
    // 1. Key-namespacing helpers
    // ───────────────────────────────────────────────────────────────

    group('key namespacing', () {
      test('keyForNodeType produces "NodeType:Foo"', () {
        expect(
          CentroidStore.keyForNodeType('Question'),
          equals('NodeType:Question'),
        );
      });

      test('keyForProcedure produces "Procedure:foo_v1"', () {
        expect(
          CentroidStore.keyForProcedure('research_v1'),
          equals('Procedure:research_v1'),
        );
      });

      test('keyForNodeType rejects empty', () {
        expect(
          () => CentroidStore.keyForNodeType(''),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('keyForProcedure rejects empty', () {
        expect(
          () => CentroidStore.keyForProcedure(''),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('targetOfKey recognises both namespaces', () {
        expect(
          CentroidStore.targetOfKey('NodeType:Claim'),
          equals(ClassificationTarget.nodeType),
        );
        expect(
          CentroidStore.targetOfKey('Procedure:think_v1'),
          equals(ClassificationTarget.procedure),
        );
      });

      test('targetOfKey returns null for unknown namespace', () {
        expect(CentroidStore.targetOfKey('Unknown:foo'), isNull);
        expect(CentroidStore.targetOfKey(''), isNull);
        expect(CentroidStore.targetOfKey('NodeType'), isNull);
      });

      test('constants match the spec § 7.1 namespace strings', () {
        expect(CentroidStore.nodeTypeKeyPrefix, equals('NodeType:'));
        expect(CentroidStore.procedureKeyPrefix, equals('Procedure:'));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 2. read against an empty table
    // ───────────────────────────────────────────────────────────────

    group('cold start', () {
      test('read returns null when no row exists for the key', () {
        expect(store.read('NodeType:Question'), isNull);
      });

      test('count returns 0 against an empty table', () {
        expect(store.count(), equals(0));
      });

      test('listKeys returns empty list when no rows exist', () {
        expect(store.listKeys(), isEmpty);
        expect(
          store.listKeys(prefix: CentroidStore.nodeTypeKeyPrefix),
          isEmpty,
        );
      });

      test('readAll returns empty list when no rows exist', () {
        expect(store.readAll(), isEmpty);
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 3. update — insert path
    // ───────────────────────────────────────────────────────────────

    group('update — insert', () {
      test('returns the stamped record with clock-supplied updatedAt',
          () {
        final at = BrainTime.utc(2026, 5, 30, 14, 30, 0);
        clock.setTo(at);
        final vec = Vec.fromList(<double>[0.1, 0.2, 0.3, 0.4]);

        final result = store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'ollama/nomic-embed-text@1.5',
          centroid: vec,
          exampleCount: 12,
        );

        expect(result.forKey, equals('NodeType:Question'));
        expect(result.embeddingModelId,
            equals('ollama/nomic-embed-text@1.5'));
        expect(result.exampleCount, equals(12));
        expect(result.centroid.closeTo(vec), isTrue);
        expect(result.updatedAt, equals(at));
      });

      test('persists every column to the centroids table', () {
        final at = BrainTime.utc(2026, 5, 30, 14, 30, 0);
        clock.setTo(at);
        final vec = Vec.fromList(<double>[0.1, 0.2, 0.3, 0.4]);

        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'ollama/nomic-embed-text@1.5',
          centroid: vec,
          exampleCount: 12,
        );

        final rows = db.select(
          'SELECT for_key, embedding_model_id, centroid_dims, '
          'example_count, updated_at_ms, updated_at_iso '
          'FROM centroids',
        );
        expect(rows.length, equals(1));
        final row = rows.single;
        expect(row['for_key'], equals('NodeType:Question'));
        expect(row['embedding_model_id'],
            equals('ollama/nomic-embed-text@1.5'));
        expect(row['centroid_dims'], equals(4));
        expect(row['example_count'], equals(12));
        expect(row['updated_at_ms'], equals(at.toMs()));
        expect(row['updated_at_iso'], equals(at.toIso8601String()));
      });

      test('subsequent read returns the same record', () {
        final vec = Vec.fromList(<double>[0.9, 0.8, 0.7, 0.6]);
        store.update(
          forKey: 'Procedure:research_v1',
          embeddingModelId: 'ollama/nomic-embed-text@1.5',
          centroid: vec,
          exampleCount: 3,
        );

        final loaded = store.read('Procedure:research_v1');
        expect(loaded, isNotNull);
        expect(loaded!.forKey, equals('Procedure:research_v1'));
        expect(loaded.embeddingModelId,
            equals('ollama/nomic-embed-text@1.5'));
        expect(loaded.exampleCount, equals(3));
        expect(loaded.centroid.closeTo(vec), isTrue);
      });

      test('count advances by 1 after each fresh-key insert', () {
        expect(store.count(), equals(0));
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[1, 0]),
          exampleCount: 1,
        );
        expect(store.count(), equals(1));
        store.update(
          forKey: 'NodeType:Claim',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0, 1]),
          exampleCount: 1,
        );
        expect(store.count(), equals(2));
      });

      test('exampleCount = 0 is accepted (a freshly-promoted '
          'centroid may legitimately start at 0 examples in the same '
          'pass that records it)', () {
        store.update(
          forKey: 'NodeType:Pattern',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[1, 0]),
          exampleCount: 0,
        );
        expect(store.read('NodeType:Pattern')!.exampleCount, equals(0));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 4. update — upsert path
    // ───────────────────────────────────────────────────────────────

    group('update — upsert', () {
      test('re-update overwrites every field except for_key', () {
        final t1 = BrainTime.utc(2026, 5, 30, 12, 0, 0);
        clock.setTo(t1);
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'old-model',
          centroid: Vec.fromList(<double>[0.1, 0.2]),
          exampleCount: 5,
        );

        final t2 = BrainTime.utc(2026, 5, 31, 12, 0, 0);
        clock.setTo(t2);
        final newVec = Vec.fromList(<double>[0.9, 0.1]);
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'new-model',
          centroid: newVec,
          exampleCount: 50,
        );

        final loaded = store.read('NodeType:Question')!;
        expect(loaded.embeddingModelId, equals('new-model'));
        expect(loaded.exampleCount, equals(50));
        expect(loaded.centroid.closeTo(newVec), isTrue);
        expect(loaded.updatedAt, equals(t2));
      });

      test('re-update does not duplicate the row (count stays at 1)',
          () {
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.1, 0.2]),
          exampleCount: 1,
        );
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.2, 0.1]),
          exampleCount: 2,
        );
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.3, 0.0]),
          exampleCount: 3,
        );

        expect(store.count(), equals(1));
        expect(store.read('NodeType:Question')!.exampleCount, equals(3));
      });

      test('re-update on a different key inserts a second row, '
          'leaves the first row untouched', () {
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[1.0, 0.0]),
          exampleCount: 10,
        );
        store.update(
          forKey: 'NodeType:Claim',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.0, 1.0]),
          exampleCount: 20,
        );

        expect(store.count(), equals(2));
        expect(
          store.read('NodeType:Question')!.exampleCount,
          equals(10),
        );
        expect(
          store.read('NodeType:Claim')!.exampleCount,
          equals(20),
        );
      });

      test('re-update with a different dimension is accepted '
          '(switching to a higher-dim embedding model)', () {
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'small-model',
          centroid: Vec.fromList(<double>[0.1, 0.2]),
          exampleCount: 5,
        );
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'big-model',
          centroid: Vec.fromList(<double>[0.1, 0.2, 0.3, 0.4]),
          exampleCount: 10,
        );

        final loaded = store.read('NodeType:Question')!;
        expect(loaded.centroid.dimension, equals(4));
        expect(loaded.embeddingModelId, equals('big-model'));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 5. Argument validation on update
    // ───────────────────────────────────────────────────────────────

    group('argument validation', () {
      test('empty forKey throws ArgumentError', () {
        expect(
          () => store.update(
            forKey: '',
            embeddingModelId: 'm',
            centroid: Vec.fromList(<double>[0.1, 0.2]),
            exampleCount: 1,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('empty embeddingModelId throws ArgumentError', () {
        expect(
          () => store.update(
            forKey: 'NodeType:Question',
            embeddingModelId: '',
            centroid: Vec.fromList(<double>[0.1, 0.2]),
            exampleCount: 1,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('negative exampleCount throws ArgumentError', () {
        expect(
          () => store.update(
            forKey: 'NodeType:Question',
            embeddingModelId: 'm',
            centroid: Vec.fromList(<double>[0.1, 0.2]),
            exampleCount: -1,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('a failed update leaves the table unchanged', () {
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.1, 0.2]),
          exampleCount: 5,
        );
        try {
          store.update(
            forKey: 'NodeType:Question',
            embeddingModelId: '',
            centroid: Vec.fromList(<double>[9.9, 9.9]),
            exampleCount: 999,
          );
          fail('expected ArgumentError');
        } on ArgumentError {
          // expected
        }
        final loaded = store.read('NodeType:Question')!;
        expect(loaded.exampleCount, equals(5));
        expect(
          loaded.centroid.closeTo(Vec.fromList(<double>[0.1, 0.2])),
          isTrue,
        );
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 6. Round-trip integrity
    // ───────────────────────────────────────────────────────────────

    group('round trip', () {
      test('the centroid blob round-trips bit-exactly through float32',
          () {
        // Vec stores float32; we hand it float64-source values that
        // happen to be exactly representable in float32 so the
        // read-back equality is bit-identical (not approximate).
        final vec = Vec.fromList(<double>[0.125, 0.5, 0.0, -0.25]);
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: vec,
          exampleCount: 1,
        );

        final loaded = store.read('NodeType:Question')!;
        for (var i = 0; i < vec.dimension; i++) {
          expect(loaded.centroid[i], equals(vec[i]));
        }
      });

      test('high-dimensional centroid (768-d, the production '
          'nomic-embed-text dim) round-trips', () {
        final values = List<double>.generate(
          768,
          (i) => (i % 7) / 7.0 - 0.5,
        );
        final vec = Vec.fromList(values);
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'ollama/nomic-embed-text@1.5',
          centroid: vec,
          exampleCount: 100,
        );

        final loaded = store.read('NodeType:Question')!;
        expect(loaded.centroid.dimension, equals(768));
        // Per Vec.fromList, the float32 truncation already happened on
        // the way in; the read-back is bit-identical to that stored
        // form.
        expect(loaded.centroid.closeTo(vec, tolerance: 1e-9), isTrue);
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 7. Multi-key listings
    // ───────────────────────────────────────────────────────────────

    group('listings', () {
      setUp(() {
        // Two node types, two procedures.
        store.update(
          forKey: 'NodeType:Claim',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[1, 0]),
          exampleCount: 1,
        );
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0, 1]),
          exampleCount: 1,
        );
        store.update(
          forKey: 'Procedure:plan_v1',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[1, 1]),
          exampleCount: 1,
        );
        store.update(
          forKey: 'Procedure:research_v1',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[1, -1]),
          exampleCount: 1,
        );
      });

      test('listKeys() returns every key, alphabetically', () {
        expect(
          store.listKeys(),
          equals(<String>[
            'NodeType:Claim',
            'NodeType:Question',
            'Procedure:plan_v1',
            'Procedure:research_v1',
          ]),
        );
      });

      test('listKeys(prefix: NodeType:) returns only NodeType keys', () {
        expect(
          store.listKeys(prefix: CentroidStore.nodeTypeKeyPrefix),
          equals(<String>['NodeType:Claim', 'NodeType:Question']),
        );
      });

      test('listKeys(prefix: Procedure:) returns only Procedure keys',
          () {
        expect(
          store.listKeys(prefix: CentroidStore.procedureKeyPrefix),
          equals(<String>['Procedure:plan_v1', 'Procedure:research_v1']),
        );
      });

      test('listKeys with a prefix that matches nothing returns empty',
          () {
        expect(store.listKeys(prefix: 'Pattern:'), isEmpty);
      });

      test('readAll() returns every record', () {
        final all = store.readAll();
        expect(all.length, equals(4));
        expect(
          all.map((r) => r.forKey).toList(),
          equals(<String>[
            'NodeType:Claim',
            'NodeType:Question',
            'Procedure:plan_v1',
            'Procedure:research_v1',
          ]),
        );
      });

      test('readAll(prefix: NodeType:) mirrors listKeys filtering',
          () {
        final nodeTypeRecords =
            store.readAll(prefix: CentroidStore.nodeTypeKeyPrefix);
        expect(nodeTypeRecords.length, equals(2));
        for (final r in nodeTypeRecords) {
          expect(
            r.forKey.startsWith(CentroidStore.nodeTypeKeyPrefix),
            isTrue,
          );
        }
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 8. Concurrent-update isolation
    // ───────────────────────────────────────────────────────────────

    group('concurrent update isolation', () {
      test('update is atomic at the row level — a reader observes '
          'either the pre-update or post-update row, never absent or '
          'half-written', () {
        // Seed the row.
        clock.setTo(BrainTime.utc(2026, 5, 30, 12, 0, 0));
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.1, 0.2]),
          exampleCount: 5,
        );

        // Read should not return null here — we just inserted.
        final before = store.read('NodeType:Question');
        expect(before, isNotNull);
        expect(before!.exampleCount, equals(5));

        // Update the row.
        clock.setTo(BrainTime.utc(2026, 5, 31, 12, 0, 0));
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.9, 0.1]),
          exampleCount: 50,
        );

        // After the update, the read must reflect the new row in full
        // — never a mix of old example-count + new vector (the
        // upsert is a single SQL statement, so SQLite's
        // per-statement implicit transaction guarantees this).
        final after = store.read('NodeType:Question')!;
        expect(after.exampleCount, equals(50));
        expect(
          after.centroid.closeTo(Vec.fromList(<double>[0.9, 0.1])),
          isTrue,
        );
        expect(after.embeddingModelId, equals('m'));
        expect(
          after.updatedAt,
          equals(BrainTime.utc(2026, 5, 31, 12, 0, 0)),
        );
      });

      test('a recompute that fails mid-way (validation error on the '
          'second update) leaves the first row visible and untouched',
          () {
        store.update(
          forKey: 'NodeType:Question',
          embeddingModelId: 'm',
          centroid: Vec.fromList(<double>[0.1, 0.2]),
          exampleCount: 5,
        );

        expect(
          () => store.update(
            forKey: 'NodeType:Question',
            embeddingModelId: '', // invalid — will throw
            centroid: Vec.fromList(<double>[0.9, 0.1]),
            exampleCount: 50,
          ),
          throwsA(isA<ArgumentError>()),
        );

        final loaded = store.read('NodeType:Question')!;
        expect(loaded.exampleCount, equals(5));
        expect(loaded.embeddingModelId, equals('m'));
      });
    });
  });
}
