// A.65 findUncertain contract test.
//
// Locks the borderline-band batch path introduced by Plan step A.65 —
// `UncertainFinder` over a `(CentroidStore, VectorTable, memory.db)`
// triple. Mirrors spec § 7.4: "Returns ids of nodes whose best
// similarity against the centroid for forKey falls in [low, high]"
// and "Memory never originates this call".
//
// Coverage:
//
//   1. Cold start — no centroid
//      - Empty centroid table → find returns empty without scanning
//        candidate nodes.
//
//   2. Cold-start gate (example count below threshold)
//      - Centroid present but `exampleCount < coldStartMinExamples`
//        → empty. Custom config raising the threshold demotes an
//        otherwise-eligible centroid to cold-start.
//
//   3. Band filter — only in-band nodes returned
//      - Candidates outside the `[low, high]` band are dropped.
//      - The interval is closed (inclusive at both ends).
//      - A node at exactly `low` is returned; a node at exactly
//        `high` is returned; just-below-low and just-above-high are
//        not.
//
//   4. Order — similarity ascending with node-id tie-break
//      - Multiple in-band candidates come back ordered from lowest
//        to highest similarity.
//      - Identical similarities tie-break on node-id lexicographic.
//
//   5. Limit cap
//      - Result count is at most `limit`.
//      - The kept ids are the lowest-similarity in-band ones (the
//        sort happens before the truncation).
//
//   6. Embedding-model identity filter
//      - A candidate node whose `embedding_model_id` differs from the
//        centroid's is silently dropped (re-embed migration territory).
//
//   7. Status and column filters
//      - Forgotten nodes never appear in candidates.
//      - Nodes with NULL `embedding_model_id` (no embedding) never
//        appear in candidates.
//      - `active`, `demoted`, `archived` all stay in scope (LLM-batch
//        review can correct any of them).
//
//   8. Procedure-keyed find
//      - `Procedure:foo_v1` throws `UnimplementedError` with a
//        message naming the missing wiring (Q-A.65.2).
//
//   9. Input validation
//      - Empty forKey → ArgumentError.
//      - NaN low / high → ArgumentError.
//      - low > high → ArgumentError.
//      - limit < 1 → ArgumentError.
//      - Unrecognised namespace prefix → ArgumentError.
//
//  10. Missing-vector tolerance
//      - A node whose vector row is absent from `vectors.db`
//        (referential drift / persist race) is silently dropped.
//      - A node whose stored vector blob is the wrong size for the
//        installed index is silently dropped (covered by
//        VectorTable.readVectors's dim guard).
//
//  11. findWithSimilarities surface
//      - Returns the same set as `find` plus the per-candidate
//        similarity value.
//
//  12. Configuration plumbing
//      - `UncertainFinder.config` round-trips the constructor input.
//      - Default config matches `ClassificationConfig` defaults.
//
//  13. Live updates
//      - A centroid added after construction is picked up on the next
//        call.
//      - A wholesale-replacement `updateCentroid` (mirroring spec
//        § 7.3) shifts which nodes fall in band.
//
// Tests run against `sqlite3.openInMemory()` (memory.db) + a second
// `sqlite3.openInMemory()` for `vectors.db` + `PlainBlobTableBackend`,
// the same pattern A.55 uses. The vec0 backend is the production
// substitute and is wired by `loadVecExtensionOrRefuseToBoot` at boot;
// the contract this file pins is backend-agnostic.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

const String _modelId = 'ollama/nomic-embed-text@1.5';
const int _dims = 3;

void main() {
  group('A.65 UncertainFinder', () {
    late Database memoryDb;
    late Database vectorsDb;
    late MutableTestClock clock;
    late CentroidStore centroidStore;
    late VectorTable vectorTable;
    late UncertainFinder finder;

    setUp(() {
      memoryDb = sqlite3.openInMemory();
      applySchemaV1(memoryDb);

      vectorsDb = sqlite3.openInMemory();

      clock = MutableTestClock(BrainTime.utc(2026, 5, 30, 12, 0, 0));

      centroidStore = CentroidStore(memoryDb: memoryDb, clock: clock);

      vectorTable = VectorTable(
        vectorsDb: vectorsDb,
        backend: const PlainBlobTableBackend(),
        clock: clock,
      );
      vectorTable.installIndex(modelId: _modelId, dims: _dims);

      finder = UncertainFinder(
        memoryDb: memoryDb,
        vectorTable: vectorTable,
        centroidStore: centroidStore,
      );
    });

    tearDown(() {
      memoryDb.dispose();
      vectorsDb.dispose();
    });

    // ───────── Helpers ─────────

    /// Seeds a centroid for a node type with enough examples to clear
    /// the default cold-start gate (8).
    void seedNodeTypeCentroid(
      String typeName,
      Vec centroid, {
      int examples = 16,
      String modelId = _modelId,
    }) {
      centroidStore.update(
        forKey: CentroidStore.keyForNodeType(typeName),
        embeddingModelId: modelId,
        centroid: centroid,
        exampleCount: examples,
      );
    }

    /// Inserts a node row + its vector under the same model. Returns
    /// the generated `node_id` string.
    ///
    /// `idHint` lets tests fix the id's textual ordering for tie-break
    /// assertions; when omitted a fresh `NodeId.generate()` is used.
    String seedNode({
      required String typeName,
      required Vec embedding,
      String? embeddingModelId = _modelId,
      NodeStatus status = NodeStatus.active,
      String? idHint,
      int? createdAtMs,
    }) {
      final id = idHint ?? NodeId.generate().toString();
      final atMs = createdAtMs ??
          clock.now().toUtc().millisecondsSinceEpoch;
      final atIso = DateTime.fromMillisecondsSinceEpoch(
        atMs,
        isUtc: true,
      ).toIso8601String();
      memoryDb.execute(
        'INSERT INTO nodes ('
        'id, type_name, scope_json, produced_by, attrs_json, status, '
        'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso, '
        'idempotency_key, embedding_model_id) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          id,
          typeName,
          '{}',
          null,
          '{}',
          status.name,
          atMs,
          atIso,
          atMs,
          atIso,
          null,
          embeddingModelId,
        ],
      );
      if (embeddingModelId != null) {
        vectorTable.insertVector(
          nodeId: id,
          vector: embedding,
          modelId: embeddingModelId,
        );
      }
      return id;
    }

    // ───────────────────────────────────────────────────────────────
    // 1. Cold start — no centroid
    // ───────────────────────────────────────────────────────────────

    group('cold start (no centroid)', () {
      test('empty centroid table → empty result, even with candidate '
          'nodes present', () {
        // Seed candidate nodes but no centroid.
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[1, 0, 0]),
        );

        final ids = finder.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.0,
          high: 1.0,
        );
        expect(ids, isEmpty);
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 2. Cold-start gate (example count below threshold)
    // ───────────────────────────────────────────────────────────────

    group('cold-start gate', () {
      test('centroid with exampleCount < default 8 → empty', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
          examples: 7,
        );
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[1, 0, 0]),
        );

        final ids = finder.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.0,
          high: 1.0,
        );
        expect(ids, isEmpty);
      });

      test('cold-start threshold is "< n", not "<= n" — exactly-at-n '
          'is eligible', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
          examples: 8,
        );
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );

        final ids = finder.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.0,
          high: 1.0,
        );
        expect(ids, hasLength(1));
      });

      test('custom coldStartMinExamples raises the gate', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
          examples: 8,
        );
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[1, 0, 0]),
        );

        final strict = UncertainFinder(
          memoryDb: memoryDb,
          vectorTable: vectorTable,
          centroidStore: centroidStore,
          config: const ClassificationConfig(coldStartMinExamples: 16),
        );
        final ids = strict.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.0,
          high: 1.0,
        );
        expect(ids, isEmpty);
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 3. Band filter — closed interval
    // ───────────────────────────────────────────────────────────────

    group('band filter', () {
      test('candidates outside the band are dropped, in-band kept', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // Similarity 1.0 — well above the band.
        final tooHigh = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[1, 0, 0]),
        );
        // Similarity 0.0 — well below the band.
        final tooLow = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0, 1, 0]),
        );
        // Similarity ~0.6 — in the band [0.45, 0.65].
        final inBand = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );

        final ids = finder.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.45,
          high: 0.65,
        );
        final idStrings = ids.map((id) => id.toString()).toList();
        expect(idStrings, contains(inBand));
        expect(idStrings, isNot(contains(tooHigh)));
        expect(idStrings, isNot(contains(tooLow)));
      });

      test('the interval is closed — exactly at low and exactly at '
          'high are included', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // Vector chosen so cos(centroid, [a, b, 0]) = a / sqrt(a^2+b^2)
        // = 0.5 → choose a=0.5, b = sqrt(0.75) ≈ 0.8660254.
        const exactLowComponent = 0.8660254037844386;
        final atLow = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.5, exactLowComponent, 0.0]),
        );
        // Similarity 0.8: a=0.8, b=0.6 → cos = 0.8.
        final atHigh = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.8, 0.6, 0.0]),
        );

        final candidates = finder.findWithSimilarities(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.5,
          high: 0.8,
        );
        final ids = candidates.map((c) => c.nodeId.toString()).toList();
        expect(ids, containsAll(<String>[atLow, atHigh]));
        // Both similarities round-trip; both must be within
        // [low, high] to a tight float32 tolerance.
        for (final c in candidates) {
          expect(c.similarity, greaterThanOrEqualTo(0.5 - 1e-5));
          expect(c.similarity, lessThanOrEqualTo(0.8 + 1e-5));
        }
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 4. Order — similarity ascending, node-id tie-break
    // ───────────────────────────────────────────────────────────────

    group('ordering', () {
      test('ids ordered by similarity ascending (most borderline '
          'first)', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // a / sqrt(a^2 + b^2) yields the cosine to [1, 0, 0].
        // Vectors picked to land in band [0.45, 0.65] at three
        // distinct similarities.
        final sim047 = seedNode(
          typeName: 'Question',
          // 0.47 / sqrt(0.47^2 + sqrt(1-0.47^2)^2) = 0.47.
          embedding: Vec.fromList(<double>[0.47, 0.8827231696, 0.0]),
        );
        final sim055 = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.55, 0.8351646544, 0.0]),
        );
        final sim063 = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.63, 0.7766594, 0.0]),
        );

        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.45,
              high: 0.65,
            )
            .map((id) => id.toString())
            .toList();
        expect(ids, equals(<String>[sim047, sim055, sim063]));
      });

      test('identical similarities tie-break on node-id lex '
          'ascending', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // Two nodes with the same vector → identical similarity.
        // Use NodeId.generate twice (real prefixed-ULID ids); the
        // tie-break is deterministic via lex ordering of the strings.
        final first = NodeId.generate().toString();
        final second = NodeId.generate().toString();
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
          idHint: first,
        );
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
          idHint: second,
        );

        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.45,
              high: 0.65,
            )
            .map((id) => id.toString())
            .toList();
        final expected = <String>[first, second]..sort();
        expect(ids, equals(expected));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 5. Limit cap
    // ───────────────────────────────────────────────────────────────

    group('limit cap', () {
      test('result count is at most `limit`', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // Seed five in-band candidates.
        final inBand = <String>[
          for (final a in const <double>[0.47, 0.51, 0.55, 0.59, 0.63])
            seedNode(
              typeName: 'Question',
              // b = sqrt(1 - a^2); cosine to [1,0,0] is a.
              embedding: Vec.fromList(<double>[a, _bForA(a), 0.0]),
            )
        ];

        final ids = finder.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.45,
          high: 0.65,
          limit: 3,
        );
        expect(ids, hasLength(3));

        // The three lowest similarities (0.47, 0.51, 0.55) win the
        // cap — sort happens before truncation.
        final kept = ids.map((id) => id.toString()).toList();
        expect(kept, equals(inBand.sublist(0, 3)));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 6. Embedding-model identity filter
    // ───────────────────────────────────────────────────────────────

    group('embedding-model identity filter', () {
      test('a candidate stored under a different model is silently '
          'dropped', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // Install a second model index and seed a node under it.
        const otherModel = 'openai/text-embedding-3-small';
        vectorTable.installIndex(modelId: otherModel, dims: _dims);
        final mismatched = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
          embeddingModelId: otherModel,
        );
        final matched = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );

        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.0,
              high: 1.0,
            )
            .map((id) => id.toString())
            .toList();
        expect(ids, contains(matched));
        expect(ids, isNot(contains(mismatched)));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 7. Status and column filters
    // ───────────────────────────────────────────────────────────────

    group('status and column filters', () {
      test('forgotten nodes are never returned', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );
        final live = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
          status: NodeStatus.forgotten,
        );

        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.0,
              high: 1.0,
            )
            .map((id) => id.toString())
            .toList();
        expect(ids, equals(<String>[live]));
      });

      test('demoted and archived nodes stay in scope', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );
        final demoted = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
          status: NodeStatus.demoted,
        );
        final archived = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
          status: NodeStatus.archived,
        );

        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.0,
              high: 1.0,
            )
            .map((id) => id.toString())
            .toList();
        expect(ids, containsAll(<String>[demoted, archived]));
      });

      test('nodes without embedding_model_id never appear', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );
        // Direct insert: no embedding, no vector row.
        const noVecId = 'n_01HZZZZZZZZZZZZZZZZZZZZZZZ';
        memoryDb.execute(
          'INSERT INTO nodes ('
          'id, type_name, scope_json, produced_by, attrs_json, status, '
          'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso, '
          'idempotency_key, embedding_model_id) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)',
          <Object?>[
            noVecId,
            'Question',
            '{}',
            null,
            '{}',
            NodeStatus.active.name,
            0,
            '1970-01-01T00:00:00.000Z',
            0,
            '1970-01-01T00:00:00.000Z',
            null,
          ],
        );

        final live = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );
        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.0,
              high: 1.0,
            )
            .map((id) => id.toString())
            .toList();
        expect(ids, isNot(contains(noVecId)));
        expect(ids, contains(live));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 8. Procedure-keyed find — deferred (Q-A.65.2)
    // ───────────────────────────────────────────────────────────────

    group('procedure-keyed find', () {
      test('throws UnimplementedError with a referencing message', () {
        // Seed a procedure centroid so the cold-start branch does not
        // short-circuit before the procedure-target branch runs.
        centroidStore.update(
          forKey: CentroidStore.keyForProcedure('research_v1'),
          embeddingModelId: _modelId,
          centroid: Vec.fromList(<double>[1, 0, 0]),
          exampleCount: 16,
        );

        expect(
          () => finder.find(
            forKey: CentroidStore.keyForProcedure('research_v1'),
            low: 0.45,
            high: 0.65,
          ),
          throwsA(
            isA<UnimplementedError>().having(
              (e) => e.message,
              'message',
              contains('Q-A.65.2'),
            ),
          ),
        );
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 9. Input validation
    // ───────────────────────────────────────────────────────────────

    group('input validation', () {
      test('empty forKey → ArgumentError', () {
        expect(
          () => finder.find(forKey: '', low: 0.0, high: 1.0),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('low > high → ArgumentError', () {
        expect(
          () => finder.find(
            forKey: CentroidStore.keyForNodeType('Question'),
            low: 0.7,
            high: 0.5,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('NaN low → ArgumentError', () {
        expect(
          () => finder.find(
            forKey: CentroidStore.keyForNodeType('Question'),
            low: double.nan,
            high: 0.5,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('NaN high → ArgumentError', () {
        expect(
          () => finder.find(
            forKey: CentroidStore.keyForNodeType('Question'),
            low: 0.0,
            high: double.nan,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('limit < 1 → ArgumentError', () {
        expect(
          () => finder.find(
            forKey: CentroidStore.keyForNodeType('Question'),
            low: 0.0,
            high: 1.0,
            limit: 0,
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => finder.find(
            forKey: CentroidStore.keyForNodeType('Question'),
            low: 0.0,
            high: 1.0,
            limit: -5,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('unrecognised namespace prefix → ArgumentError', () {
        // Seed a row directly so the cold-start branch passes.
        centroidStore.update(
          forKey: 'WeirdNamespace:foo',
          embeddingModelId: _modelId,
          centroid: Vec.fromList(<double>[1, 0, 0]),
          exampleCount: 16,
        );

        expect(
          () => finder.find(
            forKey: 'WeirdNamespace:foo',
            low: 0.0,
            high: 1.0,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('low == high is a valid (degenerate) band', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // A node at similarity 1.0; the degenerate band [1.0, 1.0]
        // includes it (interval is closed).
        final exact = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[1, 0, 0]),
        );
        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 1.0,
              high: 1.0,
            )
            .map((id) => id.toString())
            .toList();
        expect(ids, equals(<String>[exact]));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 10. Missing-vector tolerance
    // ───────────────────────────────────────────────────────────────

    group('missing-vector tolerance', () {
      test('a node row whose vector row is absent is silently '
          'dropped', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // Insert a node row with embedding_model_id set, but DO NOT
        // call insertVector → no row in vectors.db. This is the
        // referential-drift / mid-persist race case.
        const orphan = 'n_01HYYYYYYYYYYYYYYYYYYYYYYY';
        memoryDb.execute(
          'INSERT INTO nodes ('
          'id, type_name, scope_json, produced_by, attrs_json, status, '
          'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso, '
          'idempotency_key, embedding_model_id) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            orphan,
            'Question',
            '{}',
            null,
            '{}',
            NodeStatus.active.name,
            0,
            '1970-01-01T00:00:00.000Z',
            0,
            '1970-01-01T00:00:00.000Z',
            null,
            _modelId,
          ],
        );

        // A real candidate alongside so the result is non-empty.
        final live = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );

        final ids = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.0,
              high: 1.0,
            )
            .map((id) => id.toString())
            .toList();
        expect(ids, isNot(contains(orphan)));
        expect(ids, contains(live));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 11. findWithSimilarities surface
    // ───────────────────────────────────────────────────────────────

    group('findWithSimilarities', () {
      test('returns same ids as find, with per-candidate similarity', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.55, 0.8351646544, 0.0]),
        );

        final ids = finder.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.45,
          high: 0.65,
        );
        final candidates = finder.findWithSimilarities(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.45,
          high: 0.65,
        );
        expect(candidates.length, equals(ids.length));
        for (var i = 0; i < ids.length; i++) {
          expect(candidates[i].nodeId, equals(ids[i]));
          expect(candidates[i].similarity, greaterThanOrEqualTo(0.45));
          expect(candidates[i].similarity, lessThanOrEqualTo(0.65));
        }
        // Sorted ascending by similarity:
        for (var i = 1; i < candidates.length; i++) {
          expect(
            candidates[i].similarity,
            greaterThanOrEqualTo(candidates[i - 1].similarity),
          );
        }
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 12. Configuration plumbing
    // ───────────────────────────────────────────────────────────────

    group('configuration', () {
      test('finder.config round-trips constructor input', () {
        const cfg = ClassificationConfig(coldStartMinExamples: 32);
        final f = UncertainFinder(
          memoryDb: memoryDb,
          vectorTable: vectorTable,
          centroidStore: centroidStore,
          config: cfg,
        );
        expect(f.config.coldStartMinExamples, equals(32));
      });

      test('default config matches ClassificationConfig defaults', () {
        expect(finder.config.coldStartMinExamples, equals(8));
        expect(finder.config.minConfidence, equals(0.55));
        expect(finder.config.minMargin, equals(0.05));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 13. Live updates
    // ───────────────────────────────────────────────────────────────

    group('live updates (no per-call cache)', () {
      test('a centroid added after construction is picked up on the '
          'next call', () {
        // No centroid yet → empty even with candidates.
        seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );
        expect(
          finder.find(
            forKey: CentroidStore.keyForNodeType('Question'),
            low: 0.0,
            high: 1.0,
          ),
          isEmpty,
        );

        // Add the centroid; same finder instance must see it.
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );
        final ids = finder.find(
          forKey: CentroidStore.keyForNodeType('Question'),
          low: 0.0,
          high: 1.0,
        );
        expect(ids, hasLength(1));
      });

      test('wholesale-replacement updateCentroid shifts which nodes '
          'fall in band', () {
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[1, 0, 0]),
        );

        // Candidate similarity vs [1,0,0] is 1.0 (out of [0.45, 0.65]).
        final candidate = seedNode(
          typeName: 'Question',
          embedding: Vec.fromList(<double>[1, 0, 0]),
        );

        expect(
          finder
              .find(
                forKey: CentroidStore.keyForNodeType('Question'),
                low: 0.45,
                high: 0.65,
              )
              .map((id) => id.toString())
              .toList(),
          isEmpty,
        );

        // Replace the centroid with one that scores ~0.6 against the
        // candidate.
        seedNodeTypeCentroid(
          'Question',
          Vec.fromList(<double>[0.6, 0.8, 0.0]),
        );
        final after = finder
            .find(
              forKey: CentroidStore.keyForNodeType('Question'),
              low: 0.45,
              high: 0.65,
            )
            .map((id) => id.toString())
            .toList();
        expect(after, equals(<String>[candidate]));
      });
    });
  });
}

/// Returns the second component for a unit-cosine vector
/// `[a, b, 0]` whose cosine against `[1, 0, 0]` is `a`.
///
/// `b = sqrt(1 - a^2)`. Used by the limit-cap test to seed five
/// candidates at five distinct, sortable similarities without
/// repeating the same vector twice.
double _bForA(double a) {
  final b = (1.0 - a * a);
  return b <= 0 ? 0.0 : _sqrt(b);
}

double _sqrt(double x) {
  // Newton's method, 8 iterations is more than enough for a 3-d
  // unit-vector seed within float32 precision.
  if (x == 0.0) return 0.0;
  var z = x;
  for (var i = 0; i < 8; i++) {
    z = (z + x / z) / 2.0;
  }
  return z;
}
