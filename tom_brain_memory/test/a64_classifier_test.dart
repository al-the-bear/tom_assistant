// A.64 classifier contract test.
//
// Locks the read-side `Classifier` introduced by Plan step A.64 —
// the spec § 7.2 `minConfidence` + `minMargin` decision rule on top
// of A.63's `CentroidStore`, plus the spec § 7.1 cold-start gate.
//
// Coverage:
//
//   1. Cold-start — no centroids at all
//      - Empty store → unknown, bestMatch null, both similarities 0.
//      - Empty store on the other namespace (procedure) → also unknown.
//
//   2. Cold-start gate — centroids exist but below
//      `coldStartMinExamples`
//      - Single below-threshold centroid → unknown.
//      - Mixed: one below, one above threshold → only the above-
//        threshold centroid scores; classifier returns confident on
//        it (single eligible centroid case).
//
//   3. Decision band — confident
//      - Two well-separated centroids, query close to one →
//        confident with that key as bestMatch, namespace stripped.
//      - Single eligible centroid scoring above minConfidence →
//        confident (secondSimilarity == 0.0, margin == best).
//
//   4. Decision band — uncertain
//      - Best ≥ minConfidence but `best - second < minMargin` →
//        uncertain. bestMatch still set so the caller can use it
//        as an LLM-tiebreak hint.
//
//   5. Decision band — unknown
//      - Best < minConfidence → unknown.
//
//   6. Namespace isolation
//      - A query against `target: nodeType` ignores `Procedure:*`
//        centroids and vice versa.
//      - bestMatch carries the bare key (no prefix).
//
//   7. Tie-breaking
//      - Two centroids producing identical similarities → the
//        alphabetically-first key (per `readAll`'s `ORDER BY for_key
//        ASC`) wins. Deterministic across runs.
//
//   8. Input validation
//      - Zero-norm embedding → ArgumentError (surfaced from
//        `cosine`).
//      - Dimension mismatch between embedding and centroid →
//        ArgumentError (surfaced from `cosine`).
//
//   9. Config plumbing
//      - Custom thresholds change the decision band on the same
//        seeded centroid set.
//      - `Classifier.config` round-trips the constructor input.
//
//  10. Live updates
//      - Adding a centroid after construction is picked up on the
//        next `classify` call (the classifier holds no per-call
//        cache).
//      - `updateCentroid`-shaped wholesale-replacement changes the
//        decision the next call returns.
//
// Tests run against `sqlite3.openInMemory()` + `applySchemaV1` so
// the `centroids` table exists, mirroring the A.63 in-memory test
// pattern.

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.64 Classifier', () {
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

    // Helper: seed a node-type centroid with enough examples to clear
    // the default cold-start gate (8).
    void seedNodeType(String typeName, Vec centroid, {int examples = 16}) {
      store.update(
        forKey: CentroidStore.keyForNodeType(typeName),
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: centroid,
        exampleCount: examples,
      );
    }

    void seedProcedure(String procedureId, Vec centroid, {int examples = 16}) {
      store.update(
        forKey: CentroidStore.keyForProcedure(procedureId),
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: centroid,
        exampleCount: examples,
      );
    }

    // ───────────────────────────────────────────────────────────────
    // 1. Cold-start — no centroids at all
    // ───────────────────────────────────────────────────────────────

    group('cold start (empty store)', () {
      test('classify returns unknown with null bestMatch and zero '
          'similarities', () {
        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));

        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
        expect(result.bestSimilarity, equals(0.0));
        expect(result.secondSimilarity, equals(0.0));
      });

      test('procedure target on an empty store also returns unknown', () {
        final c = Classifier(store: store);
        final result = c.classify(
          Vec.fromList(<double>[1, 0, 0]),
          target: ClassificationTarget.procedure,
        );
        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 2. Cold-start gate — centroids exist but below threshold
    // ───────────────────────────────────────────────────────────────

    group('cold start gate (example count below threshold)', () {
      test('a single below-threshold centroid is filtered out → '
          'unknown', () {
        // Default coldStartMinExamples is 8; seed with 7.
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]),
            examples: 7);

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));
        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
      });

      test('all centroids below threshold → unknown', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]),
            examples: 3);
        seedNodeType('Claim', Vec.fromList(<double>[0, 1, 0]),
            examples: 5);

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));
        expect(result.decision, equals(ClassificationDecision.unknown));
      });

      test('mixed (one below, one above) → only the above-threshold '
          'centroid is scored', () {
        // Below threshold: would have scored 1.0 against the query
        // but is filtered out.
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]),
            examples: 3);
        // Above threshold: also scores 1.0 against the query.
        seedNodeType('Claim', Vec.fromList(<double>[1, 0, 0]),
            examples: 16);

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));
        expect(result.decision, equals(ClassificationDecision.confident));
        expect(result.bestMatch, equals('Claim'));
        expect(result.bestSimilarity, closeTo(1.0, 1e-6));
        // Only one eligible centroid → second is 0.0 normalisation.
        expect(result.secondSimilarity, equals(0.0));
      });

      test('cold-start threshold is "< n", not "<= n" — an '
          'exactly-at-threshold centroid is eligible', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]),
            examples: 8);

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));
        expect(result.decision, equals(ClassificationDecision.confident));
        expect(result.bestMatch, equals('Question'));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 3. Decision band — confident
    // ───────────────────────────────────────────────────────────────

    group('confident decision', () {
      test('well-separated centroids, query close to one → '
          'confident on that key', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));
        seedNodeType('Claim', Vec.fromList(<double>[0, 1, 0]));

        final c = Classifier(store: store);
        // Query: nearly identical to Question's centroid.
        final query = Vec.fromList(<double>[0.99, 0.05, 0.01]);
        final result = c.classify(query);

        expect(result.decision, equals(ClassificationDecision.confident));
        expect(result.bestMatch, equals('Question'));
        expect(result.bestSimilarity, greaterThan(0.95));
        expect(result.secondSimilarity, lessThan(0.2));
        expect(
          result.bestSimilarity - result.secondSimilarity,
          greaterThan(0.05),
        );
      });

      test('single eligible centroid scoring above minConfidence → '
          'confident (secondSimilarity normalised to 0.0)', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));

        expect(result.decision, equals(ClassificationDecision.confident));
        expect(result.bestMatch, equals('Question'));
        expect(result.bestSimilarity, closeTo(1.0, 1e-6));
        expect(result.secondSimilarity, equals(0.0));
      });

      test('bestMatch carries the bare key (no NodeType: prefix)', () {
        seedNodeType('Pattern', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));

        expect(result.bestMatch, equals('Pattern'));
        expect(result.bestMatch, isNot(startsWith('NodeType:')));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 4. Decision band — uncertain
    // ───────────────────────────────────────────────────────────────

    group('uncertain decision', () {
      test('best ≥ minConfidence but margin tight → uncertain', () {
        // Two centroids close together; query approximately
        // equidistant from both, biased slightly toward Question.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.1, 0.0]));
        seedNodeType('Claim', Vec.fromList(<double>[1.0, 0.0, 0.1]));

        final c = Classifier(store: store);
        // Query is closer to Question than Claim, but only by a
        // hair — both will score above 0.55 (minConfidence) and the
        // margin will be below 0.05 (minMargin).
        final query = Vec.fromList(<double>[1.0, 0.1, 0.099]);
        final result = c.classify(query);

        expect(result.decision, equals(ClassificationDecision.uncertain));
        expect(result.bestMatch, isNotNull);
        expect(
          result.bestSimilarity,
          greaterThanOrEqualTo(0.55),
        );
        expect(
          result.bestSimilarity - result.secondSimilarity,
          lessThan(0.05),
        );
      });

      test('a custom minMargin can promote uncertain → confident '
          'on the same data', () {
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.1, 0.0]));
        seedNodeType('Claim', Vec.fromList(<double>[1.0, 0.0, 0.1]));

        // minMargin: 0.0 disables the margin gate entirely — any
        // positive ordering between best and second is enough.
        final lax = Classifier(
          store: store,
          config: const ClassificationConfig(minMargin: 0.0),
        );
        final query = Vec.fromList(<double>[1.0, 0.1, 0.099]);
        final result = lax.classify(query);

        expect(result.decision, equals(ClassificationDecision.confident));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 5. Decision band — unknown (best below minConfidence)
    // ───────────────────────────────────────────────────────────────

    group('unknown decision (best below minConfidence)', () {
      test('query orthogonal to every centroid → unknown', () {
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]));
        seedNodeType('Claim', Vec.fromList(<double>[0.0, 1.0, 0.0]));

        final c = Classifier(store: store);
        // Orthogonal to both centroids.
        final query = Vec.fromList(<double>[0.0, 0.0, 1.0]);
        final result = c.classify(query);

        expect(result.decision, equals(ClassificationDecision.unknown));
        // bestMatch is still recorded — caller can inspect for
        // diagnostics — but the decision band is the contract.
        expect(result.bestMatch, isNotNull);
        expect(result.bestSimilarity, lessThan(0.55));
      });

      test('a stricter minConfidence can demote confident → unknown '
          'on the same data', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));

        final strict = Classifier(
          store: store,
          config: const ClassificationConfig(minConfidence: 0.999),
        );
        // Identical-vector query scores 1.0 but the threshold is 0.999.
        // The query is a near-but-not-identical vector that lands
        // under 0.999.
        final query = Vec.fromList(<double>[0.9, 0.1, 0.0]);
        final result = strict.classify(query);

        expect(result.bestSimilarity, lessThan(0.999));
        expect(result.decision, equals(ClassificationDecision.unknown));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 6. Namespace isolation
    // ───────────────────────────────────────────────────────────────

    group('namespace isolation', () {
      test('nodeType target ignores Procedure:* centroids', () {
        // The procedure centroid would have scored perfectly; the
        // node-type query must not see it.
        seedProcedure('research_v1', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final result = c.classify(
          Vec.fromList(<double>[1, 0, 0]),
          target: ClassificationTarget.nodeType,
        );

        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
      });

      test('procedure target ignores NodeType:* centroids', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final result = c.classify(
          Vec.fromList(<double>[1, 0, 0]),
          target: ClassificationTarget.procedure,
        );

        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
      });

      test('procedure bestMatch strips the Procedure: prefix', () {
        seedProcedure('classify_inbound_v1', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final result = c.classify(
          Vec.fromList(<double>[1, 0, 0]),
          target: ClassificationTarget.procedure,
        );

        expect(result.bestMatch, equals('classify_inbound_v1'));
        expect(result.bestMatch, isNot(startsWith('Procedure:')));
      });

      test('coexisting node-type and procedure centroids on the same '
          'store route correctly by target', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));
        seedProcedure('research_v1', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final nodeResult = c.classify(
          Vec.fromList(<double>[1, 0, 0]),
          target: ClassificationTarget.nodeType,
        );
        final procResult = c.classify(
          Vec.fromList(<double>[1, 0, 0]),
          target: ClassificationTarget.procedure,
        );

        expect(nodeResult.bestMatch, equals('Question'));
        expect(procResult.bestMatch, equals('research_v1'));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 7. Tie-breaking
    // ───────────────────────────────────────────────────────────────

    group('tie breaking', () {
      test('identical similarities → alphabetically-first key wins '
          '(deterministic across runs)', () {
        // Two centroids that produce identical cosine against the
        // query. Insertion order: Question first, Claim second.
        // Alphabetical order: Claim < Question, so Claim must win.
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));
        seedNodeType('Claim', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));

        // Both score 1.0; alphabetical-first ("Claim") wins.
        expect(result.bestMatch, equals('Claim'));
        expect(result.bestSimilarity, closeTo(1.0, 1e-6));
        expect(result.secondSimilarity, closeTo(1.0, 1e-6));
        // Margin is zero → decision is uncertain (best ≥
        // minConfidence, margin < minMargin).
        expect(result.decision, equals(ClassificationDecision.uncertain));
      });

      test('tie-break is stable across repeated calls', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));
        seedNodeType('Claim', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        final query = Vec.fromList(<double>[1, 0, 0]);
        final r1 = c.classify(query);
        final r2 = c.classify(query);
        final r3 = c.classify(query);

        expect(r1.bestMatch, equals(r2.bestMatch));
        expect(r2.bestMatch, equals(r3.bestMatch));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 8. Input validation
    // ───────────────────────────────────────────────────────────────

    group('input validation', () {
      test('zero-norm embedding surfaces ArgumentError from cosine', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        expect(
          () => c.classify(Vec.fromList(<double>[0, 0, 0])),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('dimension mismatch between query and centroid surfaces '
          'ArgumentError from cosine', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        // 4-d query vs 3-d centroid.
        expect(
          () => c.classify(Vec.fromList(<double>[1, 0, 0, 0])),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('cold-start path is taken before any cosine, so zero-norm '
          'query against an empty store returns unknown (no throw)',
          () {
        // The empty-store fast-path returns unknown without ever
        // calling cosine — so a zero-norm query that would otherwise
        // throw quietly returns unknown. This is the right shape:
        // a producer bug surfaces only when there is something to
        // score against; an empty store cannot tell the query is
        // malformed.
        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[0, 0, 0]));
        expect(result.decision, equals(ClassificationDecision.unknown));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 9. Config plumbing
    // ───────────────────────────────────────────────────────────────

    group('config plumbing', () {
      test('Classifier.config round-trips the constructor input', () {
        const cfg = ClassificationConfig(
          minConfidence: 0.7,
          minMargin: 0.1,
          coldStartMinExamples: 16,
        );
        final c = Classifier(store: store, config: cfg);
        expect(c.config.minConfidence, equals(0.7));
        expect(c.config.minMargin, equals(0.1));
        expect(c.config.coldStartMinExamples, equals(16));
      });

      test('default config matches spec § 7.2 defaults '
          '(0.55 / 0.05 / 8)', () {
        final c = Classifier(store: store);
        expect(c.config.minConfidence, equals(0.55));
        expect(c.config.minMargin, equals(0.05));
        expect(c.config.coldStartMinExamples, equals(8));
      });

      test('coldStartMinExamples raised to 16 demotes an 8-example '
          'centroid to cold-start', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]),
            examples: 8);

        final c = Classifier(
          store: store,
          config: const ClassificationConfig(coldStartMinExamples: 16),
        );
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));
        expect(result.decision, equals(ClassificationDecision.unknown));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 10. Live updates (no per-call cache)
    // ───────────────────────────────────────────────────────────────

    group('live updates', () {
      test('a centroid added after construction is picked up on '
          'the next call', () {
        final c = Classifier(store: store);
        // Empty store → unknown.
        expect(
          c.classify(Vec.fromList(<double>[1, 0, 0])).decision,
          equals(ClassificationDecision.unknown),
        );

        // Add a centroid; same classifier instance must see it.
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));
        expect(result.decision, equals(ClassificationDecision.confident));
        expect(result.bestMatch, equals('Question'));
      });

      test('a wholesale-replacement update changes the next '
          'classification outcome', () {
        seedNodeType('Question', Vec.fromList(<double>[1, 0, 0]));

        final c = Classifier(store: store);
        expect(
          c.classify(Vec.fromList(<double>[1, 0, 0])).bestMatch,
          equals('Question'),
        );

        // Replace Question's centroid with a vector that does NOT
        // match the query; the same classifier should reflect the
        // new state.
        seedNodeType('Question', Vec.fromList(<double>[0, 0, 1]));
        final result = c.classify(Vec.fromList(<double>[1, 0, 0]));
        expect(result.bestSimilarity, closeTo(0.0, 1e-6));
        expect(result.decision, equals(ClassificationDecision.unknown));
      });
    });
  });
}
