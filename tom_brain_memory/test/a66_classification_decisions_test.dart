// A.66 — Classification decisions cross-cut test.
//
// A.63–A.65 cover the per-class contracts in isolation (`CentroidStore`
// write/read paths; `Classifier` decision matrix per feature;
// `UncertainFinder` band-scan). A.66 wires the read side (`Classifier`)
// against a single seeded centroid fixture and pins the three cross-cut
// behaviours the plan calls out:
//
//   1. **confident / uncertain / unknown decisions on a seeded
//      centroid set** — one fixture, three queries chosen to land in
//      each decision band, end-to-end through
//      `Classifier.classify(Vec, target)`.
//
//   2. **cold-start (no centroid) skipped** — the empty-store
//      fast-path returns `unknown` without scoring; a freshly-booted
//      memory with no centroid rows is the steady-state cold start.
//      A separate check exercises the cold-start gate
//      (`example_count < coldStartMinExamples`) — centroids that
//      technically exist but are below the trust threshold are
//      treated as "no centroid".
//
//   3. **concurrent `updateCentroid` does not affect an in-flight
//      recall** — the classifier's `readAll` returns a snapshot; once
//      the snapshot is held, subsequent `update` calls cannot change
//      the records that snapshot references. This is the property the
//      `Classifier`'s file header explicitly names ("the property A.66
//      names as 'concurrent updateCentroid does not affect an
//      in-flight recall'"). We pin it at two levels:
//
//        a. **Snapshot semantics on the store** — a `readAll` list,
//           held by the caller, is unchanged by a subsequent `update`.
//           The classifier's invariant rides on this.
//
//        b. **End-to-end through the classifier** — a sequence of
//           `classify` / `update` / `classify` calls produces
//           coherent (all-old or all-new) verdicts on every call;
//           no torn state is ever observable.
//
//        c. **Async-interleaved scheduling** — many `classify` calls
//           scheduled across microtasks alongside `update` calls
//           always produce a coherent result on each individual
//           call. Since the classifier is synchronous within a
//           microtask, the snapshot is taken at the moment classify
//           starts and the result reflects exactly the centroid
//           state visible to that microtask.
//
// All tests run against `sqlite3.openInMemory()` + `applySchemaV1` so
// the `centroids` table exists, mirroring the A.63 / A.64 / A.65 test
// pattern.

import 'dart:async';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('A.66 classification decisions (cross-cut)', () {
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
    void seedNodeType(
      String typeName,
      Vec centroid, {
      int examples = 16,
    }) {
      store.update(
        forKey: CentroidStore.keyForNodeType(typeName),
        embeddingModelId: 'ollama/nomic-embed-text@1.5',
        centroid: centroid,
        exampleCount: examples,
      );
    }

    // Seeded set used by the "all three decisions on one fixture"
    // group. Three well-separated centroids embedded in 4-d so the
    // "unknown" band is reachable — three orthonormal centroids in
    // 3-d would force max cosine ≥ 1/√3 ≈ 0.577, above the 0.55
    // minConfidence floor, so no 3-d query can land in the unknown
    // band against this seed. The 4th dimension gives the unknown
    // query somewhere orthogonal to all three centroids to live.
    void seedDecisionFixture() {
      seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0, 0.0]));
      seedNodeType('Claim', Vec.fromList(<double>[0.0, 1.0, 0.0, 0.0]));
      seedNodeType('Concept', Vec.fromList(<double>[0.0, 0.0, 1.0, 0.0]));
    }

    // ───────────────────────────────────────────────────────────────
    // 1. Confident / uncertain / unknown on a seeded centroid set.
    // ───────────────────────────────────────────────────────────────

    group('decisions on a seeded centroid set', () {
      test('all three decision bands are reachable on one fixture '
          'by varying the query alone', () {
        seedDecisionFixture();
        final c = Classifier(store: store);

        // (a) Confident — query close to Question's centroid, far
        //     from the others. Margin to runner-up is large.
        final confident = c.classify(
          Vec.fromList(<double>[0.99, 0.05, 0.01, 0.0]),
        );
        expect(
          confident.decision,
          equals(ClassificationDecision.confident),
          reason: 'query close to Question and far from Claim/Concept '
              'must land in the confident band',
        );
        expect(confident.bestMatch, equals('Question'));
        expect(confident.bestSimilarity, greaterThan(0.95));
        expect(
          confident.bestSimilarity - confident.secondSimilarity,
          greaterThanOrEqualTo(0.05),
        );

        // (b) Uncertain — query well above minConfidence on its
        //     winner *and* on its runner-up, but the margin between
        //     them is below minMargin. Two equally-strong dimensions
        //     with a hair of bias toward Question.
        final uncertain = c.classify(
          Vec.fromList(<double>[1.0, 0.99, 0.0, 0.0]),
        );
        expect(
          uncertain.decision,
          equals(ClassificationDecision.uncertain),
          reason: 'query nearly equidistant from Question and Claim '
              'must land in the uncertain band',
        );
        expect(uncertain.bestMatch, isNotNull);
        expect(
          uncertain.bestSimilarity,
          greaterThanOrEqualTo(0.55),
        );
        expect(
          uncertain.bestSimilarity - uncertain.secondSimilarity,
          lessThan(0.05),
        );

        // (c) Unknown — query orthogonal to all three centroids
        //     (lives entirely in the 4th dimension). Max cosine
        //     against any centroid is 0.0 — well below the 0.55
        //     minConfidence floor.
        final unknown = c.classify(
          Vec.fromList(<double>[0.0, 0.0, 0.0, 1.0]),
        );
        expect(
          unknown.decision,
          equals(ClassificationDecision.unknown),
          reason: 'query roughly equidistant from every centroid and '
              'below minConfidence must land in the unknown band',
        );
        expect(unknown.bestSimilarity, lessThan(0.55));
      });

      test('the same seeded fixture is stable across repeated calls '
          '— no per-call state leaks between classifications', () {
        seedDecisionFixture();
        final c = Classifier(store: store);
        final query = Vec.fromList(<double>[0.99, 0.05, 0.01, 0.0]);

        final r1 = c.classify(query);
        final r2 = c.classify(query);
        final r3 = c.classify(query);

        expect(r1.decision, equals(r2.decision));
        expect(r2.decision, equals(r3.decision));
        expect(r1.bestMatch, equals(r2.bestMatch));
        expect(r1.bestSimilarity, equals(r2.bestSimilarity));
        expect(r1.secondSimilarity, equals(r2.secondSimilarity));
      });

      test('a confident-on-Question query becomes uncertain once a '
          'nearby competitor centroid is added — the seeded set is '
          'reachable from any direction', () {
        // Start with Question alone; query scores perfectly.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]));
        final c = Classifier(store: store);
        final query = Vec.fromList(<double>[1.0, 0.05, 0.0]);

        final before = c.classify(query);
        expect(before.decision, equals(ClassificationDecision.confident));
        expect(before.bestMatch, equals('Question'));

        // Add a nearby competitor. The same query now has a tight
        // margin — decision flips to uncertain.
        seedNodeType('Claim', Vec.fromList(<double>[1.0, 0.04, 0.0]));
        final after = c.classify(query);
        expect(after.decision, equals(ClassificationDecision.uncertain));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 2. Cold-start (no centroid) skipped.
    // ───────────────────────────────────────────────────────────────

    group('cold start (no centroid) is skipped', () {
      test('empty store returns unknown without scoring', () {
        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1.0, 0.0, 0.0]));

        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
        expect(result.bestSimilarity, equals(0.0));
        expect(result.secondSimilarity, equals(0.0));
      });

      test('empty store on the procedure target also returns unknown '
          '— cold-start fast-path is per-target', () {
        // Seed a node-type centroid; the procedure namespace remains
        // empty. A procedure-target classify must still cold-start.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]));

        final c = Classifier(store: store);
        final result = c.classify(
          Vec.fromList(<double>[1.0, 0.0, 0.0]),
          target: ClassificationTarget.procedure,
        );
        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
      });

      test('all centroids below coldStartMinExamples → still '
          'unknown (cold-start gate is the same outcome as empty)', () {
        // Default coldStartMinExamples is 8.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]),
            examples: 3);
        seedNodeType('Claim', Vec.fromList(<double>[0.0, 1.0, 0.0]),
            examples: 7);

        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[1.0, 0.0, 0.0]));

        expect(result.decision, equals(ClassificationDecision.unknown));
        expect(result.bestMatch, isNull);
      });

      test('cold-start fast-path skips cosine entirely — a zero-norm '
          'query against an empty store does not throw', () {
        // The empty-store branch returns unknown without invoking
        // cosine. Producer bugs only surface when there is something
        // to score against; the cold-start contract is "skipped",
        // not "validated".
        final c = Classifier(store: store);
        final result = c.classify(Vec.fromList(<double>[0.0, 0.0, 0.0]));
        expect(result.decision, equals(ClassificationDecision.unknown));
      });

      test('crossing the cold-start threshold via updateCentroid '
          'flips unknown → confident on the next call (no extra '
          'machinery needed)', () {
        // Below threshold first.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]),
            examples: 5);

        final c = Classifier(store: store);
        expect(
          c.classify(Vec.fromList(<double>[1.0, 0.0, 0.0])).decision,
          equals(ClassificationDecision.unknown),
        );

        // Upsert with examples crossing the gate.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]),
            examples: 16);
        final after = c.classify(Vec.fromList(<double>[1.0, 0.0, 0.0]));
        expect(after.decision, equals(ClassificationDecision.confident));
        expect(after.bestMatch, equals('Question'));
      });
    });

    // ───────────────────────────────────────────────────────────────
    // 3. Concurrent updateCentroid does not affect an in-flight recall.
    // ───────────────────────────────────────────────────────────────

    group('concurrent updateCentroid does not affect an in-flight '
        'recall', () {
      // (a) Snapshot semantics at the store level — `readAll` returns
      //     a fully materialised list of records. Once that list is
      //     in the caller's hands, a subsequent `update` cannot
      //     mutate it (each `CentroidRecord` is immutable and the
      //     list is a fresh allocation per call). The classifier's
      //     "snapshot during classify" property rides on this.
      test('readAll returns a snapshot — mutating the store afterwards '
          'does not change the previously-returned list', () {
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]),
            examples: 16);
        seedNodeType('Claim', Vec.fromList(<double>[0.0, 1.0, 0.0]),
            examples: 16);

        final snapshot = store.readAll(
          prefix: CentroidStore.nodeTypeKeyPrefix,
        );
        expect(snapshot, hasLength(2));

        // Capture the centroid blob of Question from the snapshot,
        // then update the row to a completely different vector.
        final beforeQuestion = snapshot.firstWhere(
          (r) => r.forKey == 'NodeType:Question',
        );
        final beforeBlob = beforeQuestion.centroid.toBlob();
        final beforeExampleCount = beforeQuestion.exampleCount;

        // Mutate the underlying row.
        seedNodeType('Question', Vec.fromList(<double>[0.0, 0.0, 1.0]),
            examples: 99);

        // The originally-returned snapshot must be unchanged. The
        // record object is immutable, the vector inside it is not
        // aliased to the SQLite blob, and the example count was
        // captured at read time.
        final afterFromSnapshot = snapshot.firstWhere(
          (r) => r.forKey == 'NodeType:Question',
        );
        expect(afterFromSnapshot.centroid.toBlob(), equals(beforeBlob));
        expect(afterFromSnapshot.exampleCount, equals(beforeExampleCount));

        // A fresh readAll, however, must reflect the update.
        final freshSnapshot = store.readAll(
          prefix: CentroidStore.nodeTypeKeyPrefix,
        );
        final freshQuestion = freshSnapshot.firstWhere(
          (r) => r.forKey == 'NodeType:Question',
        );
        expect(freshQuestion.exampleCount, equals(99));
      });

      // (b) End-to-end through the classifier — sequential
      //     classify/update/classify never produces a torn verdict.
      //     Each call returns a result consistent with the centroid
      //     state visible at the start of that call.
      test('sequential classify → update → classify always yields '
          'coherent verdicts (all-old or all-new, never mixed)', () {
        // Pre-state: Question at [1,0,0]; query close to it.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]));
        final c = Classifier(store: store);
        final query = Vec.fromList(<double>[1.0, 0.05, 0.0]);

        final preUpdate = c.classify(query);
        expect(preUpdate.decision, equals(ClassificationDecision.confident));
        expect(preUpdate.bestMatch, equals('Question'));

        // Wholesale-replace Question's centroid with an orthogonal
        // vector; the query is now far from it.
        seedNodeType('Question', Vec.fromList(<double>[0.0, 0.0, 1.0]));

        final postUpdate = c.classify(query);
        expect(postUpdate.decision, equals(ClassificationDecision.unknown));

        // The two results are each individually coherent — old
        // verdict before, new verdict after — never an interleaved
        // mix (e.g. new vector with stale similarity).
        expect(preUpdate.bestSimilarity, greaterThan(0.95));
        expect(postUpdate.bestSimilarity, lessThan(0.55));
      });

      // (c) Async-interleaved scheduling — many `classify` calls
      //     scheduled as microtasks alongside `update` calls.
      //     Within Dart's single-threaded event loop the classifier
      //     is synchronous, so each individual `classify` runs to
      //     completion against a fixed centroid snapshot — no torn
      //     verdict is possible. We assert each individual result is
      //     either a "pre-update" or "post-update" verdict; never a
      //     halfway state.
      test('async-interleaved classify and update calls always '
          'produce coherent per-call verdicts', () async {
        // Two centroid states: A (Question at [1,0,0]) and B
        // (Question at [0,0,1]). Query close to [1,0,0]: under A
        // → confident; under B → unknown.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]));
        final c = Classifier(store: store);
        final query = Vec.fromList(<double>[1.0, 0.05, 0.0]);

        // Schedule 20 classify calls and 4 update calls (alternating
        // A → B → A → B → A) as microtasks. We capture each
        // classify's verdict and assert every verdict was coherent.
        final verdicts = <ClassificationDecision>[];
        final futures = <Future<void>>[];

        for (var i = 0; i < 20; i++) {
          futures.add(Future<void>.microtask(() {
            verdicts.add(c.classify(query).decision);
          }));
          if (i % 5 == 4) {
            // Flip the centroid every 5 classify schedules.
            final flipToB = (i ~/ 5) % 2 == 0;
            futures.add(Future<void>.microtask(() {
              seedNodeType(
                'Question',
                flipToB
                    ? Vec.fromList(<double>[0.0, 0.0, 1.0])
                    : Vec.fromList(<double>[1.0, 0.0, 0.0]),
              );
            }));
          }
        }

        await Future.wait(futures);

        // 20 classify verdicts were recorded.
        expect(verdicts, hasLength(20));

        // Every verdict must be one of the two coherent outcomes:
        // confident on state A, or unknown on state B. The
        // uncertain band is impossible here because there is exactly
        // one centroid, well-separated from the query in state B and
        // matching it in state A. A "torn" verdict would surface
        // either as a value outside this set or as a stale-vector /
        // fresh-state mismatch — neither can happen because each
        // classify runs to completion synchronously within its
        // microtask.
        for (final v in verdicts) {
          expect(
            v,
            anyOf(
              equals(ClassificationDecision.confident),
              equals(ClassificationDecision.unknown),
            ),
            reason: 'every per-call verdict must be one of the two '
                'coherent outcomes; got $v',
          );
        }
      });

      // (d) Update that *changes the cold-start eligibility* mid-
      //     stream is also a coherent transition. A classify before
      //     the gate-crossing sees unknown; a classify after sees
      //     confident; never a half-state where eligibility and
      //     vector are out of sync.
      test('an updateCentroid that crosses the cold-start gate '
          'flips the next classify wholesale, not partially', () {
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]),
            examples: 5);
        final c = Classifier(store: store);
        final query = Vec.fromList(<double>[1.0, 0.0, 0.0]);

        // Below the gate — unknown.
        final before = c.classify(query);
        expect(before.decision, equals(ClassificationDecision.unknown));
        expect(before.bestMatch, isNull);

        // Cross the gate with one wholesale update. Vector unchanged,
        // example count above 8.
        seedNodeType('Question', Vec.fromList(<double>[1.0, 0.0, 0.0]),
            examples: 16);

        // After the update, classify sees the new row in full —
        // confident on the same query, bestMatch populated.
        final after = c.classify(query);
        expect(after.decision, equals(ClassificationDecision.confident));
        expect(after.bestMatch, equals('Question'));
        expect(after.bestSimilarity, closeTo(1.0, 1e-6));
      });
    });
  });
}
