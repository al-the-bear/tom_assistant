// A.58 — Maximal Marginal Relevance diversifier (pure-function tests).
//
// Plan step A.58:
//   "Implement MMR diversifier (`λ = 0.7`) — pure function."
//
// Spec § 6.2 (memory_specification.md):
//   "MMR is the default diversifier. λ = 0.7 by default."
//
// What this file covers (one `test(...)` per row):
//
//   Default / surface
//   -----------------
//   * `kDefaultMmrLambda` is 0.7 and matches
//     `DiversityPolicy.defaultMmr.lambda`.
//   * Empty `candidates` → empty result.
//   * `k == 0` → empty result.
//   * `k < 0` → empty result.
//   * `lambda < 0` throws ArgumentError.
//   * `lambda > 1` throws ArgumentError.
//   * `lambda == 0` and `lambda == 1` accepted (boundary).
//   * Single-candidate input returns that single item with
//     `maxSimilarityToSelected == 0.0` and
//     `mmrScore == lambda * relevance`.
//
//   Selection math
//   --------------
//   * First pick is always the highest-relevance candidate
//     regardless of lambda (selected pool is empty).
//   * λ = 1.0 → output is the input sorted by descending relevance
//     (pure relevance, input-position tie-break preserved).
//   * λ = 0.0 → after the relevance-led first pick, every later pick
//     minimises max-similarity to the already-selected set.
//   * Two identical-similarity candidates pick the lower-input-index
//     first (deterministic tie-break).
//   * Two equal-MMR-score candidates pick the lower-input-index first.
//
//   k handling
//   ----------
//   * `k >= candidates.length` returns a reordering of the entire
//     input (no truncation).
//   * `k < candidates.length` truncates to k picks.
//   * `selectionOrder` is 0..k-1 in pick order.
//
//   Pure / deterministic
//   --------------------
//   * Two runs with the same inputs produce identical outputs.
//   * Result is unmodifiable (cannot be added to).
//
//   maxSimilarityToSelected accounting
//   ----------------------------------
//   * `maxSimilarityToSelected` for the first pick is exactly 0.0.
//   * After pick #1, `maxSimilarityToSelected` for the second pick
//     equals `similarity(candidate, first-pick)`.
//   * After picks #1 and #2, `maxSimilarityToSelected` for pick #3
//     is the **max** of similarity to either of them (not the sum,
//     not the latest).
//
//   Recorded mmrScore
//   -----------------
//   * `mmrScore == lambda * relevance - (1 - lambda) * maxSim` for
//     every selected row, exactly as computed.
//
//   Diversity property
//   ------------------
//   * For a synthetic two-cluster set where five items are mutually
//     identical (similarity 1.0 inside the cluster, 0.0 to the other
//     cluster) and λ = 0.5, the MMR output alternates clusters until
//     one cluster is exhausted — i.e. the second pick is from the
//     opposite cluster of the first pick.
//
//   Pure-relevance equivalence
//   --------------------------
//   * At λ = 1.0, the MMR ordering matches stable-sort-by-relevance-
//     descending exactly, for a random permutation of relevance
//     scores (property).
//
//   Similarity callback usage discipline
//   ------------------------------------
//   * Similarity is never called against an item with itself.
//   * Total similarity-call count is O(k · (n − 1)) — one call per
//     unselected candidate per pick (the per-candidate running-max
//     optimisation in the implementation).

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('A.58 MMR diversifier (pure function)', () {
    // ─── Helpers ────────────────────────────────────────────────────

    // A toy item type. The integer is just an identity tag for the
    // similarity callback.
    MmrInput<int> input(int id, double relevance) =>
        MmrInput<int>(item: id, relevance: relevance);

    // Similarity that is 1.0 for equal ids and 0.0 otherwise — i.e.
    // every distinct candidate is fully diverse from every other. Used
    // by surface tests where we only care about the relevance branch.
    double allDistinct(int a, int b) => 0.0;

    // ─── Default / surface ──────────────────────────────────────────

    test('kDefaultMmrLambda is 0.7', () {
      expect(kDefaultMmrLambda, 0.7);
    });

    test('default lambda matches DiversityPolicy.defaultMmr.lambda', () {
      expect(kDefaultMmrLambda, DiversityPolicy.defaultMmr.lambda);
    });

    test('empty candidates returns empty', () {
      final picked = mmrDiversify<int>(
        candidates: const [],
        similarity: allDistinct,
        k: 10,
      );
      expect(picked, isEmpty);
    });

    test('k == 0 returns empty', () {
      final picked = mmrDiversify<int>(
        candidates: [input(1, 0.9)],
        similarity: allDistinct,
        k: 0,
      );
      expect(picked, isEmpty);
    });

    test('k < 0 returns empty', () {
      final picked = mmrDiversify<int>(
        candidates: [input(1, 0.9)],
        similarity: allDistinct,
        k: -3,
      );
      expect(picked, isEmpty);
    });

    test('lambda < 0 throws ArgumentError', () {
      expect(
        () => mmrDiversify<int>(
          candidates: [input(1, 0.9)],
          similarity: allDistinct,
          k: 1,
          lambda: -0.0001,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('lambda > 1 throws ArgumentError', () {
      expect(
        () => mmrDiversify<int>(
          candidates: [input(1, 0.9)],
          similarity: allDistinct,
          k: 1,
          lambda: 1.0001,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('lambda == 0.0 is accepted (boundary)', () {
      final picked = mmrDiversify<int>(
        candidates: [input(1, 0.9), input(2, 0.1)],
        similarity: allDistinct,
        k: 2,
        lambda: 0.0,
      );
      expect(picked, hasLength(2));
    });

    test('lambda == 1.0 is accepted (boundary)', () {
      final picked = mmrDiversify<int>(
        candidates: [input(1, 0.9), input(2, 0.1)],
        similarity: allDistinct,
        k: 2,
        lambda: 1.0,
      );
      expect(picked, hasLength(2));
    });

    test('single candidate returns that candidate with maxSim 0', () {
      final picked = mmrDiversify<int>(
        candidates: [input(42, 0.5)],
        similarity: allDistinct,
        k: 1,
        lambda: 0.7,
      );
      expect(picked, hasLength(1));
      expect(picked.first.item, 42);
      expect(picked.first.relevance, 0.5);
      expect(picked.first.maxSimilarityToSelected, 0.0);
      expect(picked.first.mmrScore, closeTo(0.7 * 0.5, 1e-12));
      expect(picked.first.selectionOrder, 0);
    });

    // ─── Selection math ─────────────────────────────────────────────

    test('first pick is the highest-relevance item (selected pool empty)',
        () {
      // With λ > 0, the first pick has nothing to be diverse against
      // (selected pool empty → maxSim term is 0), so the MMR score
      // reduces to λ·relevance and the highest-relevance candidate
      // wins. Use a non-trivial λ to make the math meaningful.
      // (At λ = 0 the score collapses to 0 for every candidate and
      // the input-position tie-break decides — a separate, documented
      // boundary covered by the `lambda == 0.0` tests above.)
      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.2),
          input(2, 0.9),
          input(3, 0.5),
        ],
        similarity: allDistinct,
        k: 1,
        lambda: 0.7,
      );
      expect(picked.single.item, 2);
    });

    test('lambda == 1.0 returns descending-relevance ordering', () {
      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.2),
          input(2, 0.9),
          input(3, 0.5),
          input(4, 0.7),
        ],
        // Use a non-trivial similarity to prove it's ignored at λ = 1.
        similarity: (a, b) => 0.999,
        k: 4,
        lambda: 1.0,
      );
      expect(picked.map((s) => s.item).toList(), [2, 4, 3, 1]);
    });

    test('lambda == 0.0 picks for diversity after first relevance pick',
        () {
      // Three items: 1 and 2 are very similar (0.9), 3 is unrelated
      // (0.0 to both). Relevances are 0.5, 0.4, 0.3 — so the first
      // pick is item 1. After that, λ = 0 means we ignore relevance:
      // pick the item with the smallest maxSim to {1}. Item 3 has
      // 0.0; item 2 has 0.9 — pick 3 next.
      double sim(int a, int b) {
        if ({a, b}.containsAll({1, 2})) return 0.9;
        return 0.0;
      }

      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.5),
          input(2, 0.4),
          input(3, 0.3),
        ],
        similarity: sim,
        k: 3,
        lambda: 0.0,
      );
      expect(picked.map((s) => s.item).toList(), [1, 3, 2]);
    });

    test('equal MMR score → lower input index wins (tie-break)', () {
      // Two candidates with identical relevance; allDistinct
      // similarity. MMR scores are identical at every pick step.
      // Output must follow input order.
      final picked = mmrDiversify<int>(
        candidates: [
          input(10, 0.5),
          input(11, 0.5),
          input(12, 0.5),
        ],
        similarity: allDistinct,
        k: 3,
        lambda: 0.7,
      );
      expect(picked.map((s) => s.item).toList(), [10, 11, 12]);
    });

    // ─── k handling ─────────────────────────────────────────────────

    test('k >= candidates.length returns a reordering of the full input',
        () {
      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.1),
          input(2, 0.9),
        ],
        similarity: allDistinct,
        k: 100, // way larger than 2
      );
      expect(picked, hasLength(2));
      expect(picked.map((s) => s.item).toSet(), {1, 2});
    });

    test('k < candidates.length truncates to k picks', () {
      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.1),
          input(2, 0.9),
          input(3, 0.5),
          input(4, 0.7),
        ],
        similarity: allDistinct,
        k: 2,
      );
      expect(picked, hasLength(2));
    });

    test('selectionOrder is 0..k-1 in pick order', () {
      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.9),
          input(2, 0.8),
          input(3, 0.7),
        ],
        similarity: allDistinct,
        k: 3,
      );
      expect(picked.map((s) => s.selectionOrder).toList(), [0, 1, 2]);
    });

    // ─── Pure / deterministic ───────────────────────────────────────

    test('two runs with identical inputs return identical outputs', () {
      final cands = [
        input(1, 0.4),
        input(2, 0.8),
        input(3, 0.6),
        input(4, 0.5),
      ];
      double sim(int a, int b) =>
          ((a * 13 + b * 17) % 7) / 10.0; // deterministic, symmetric? not
      // strictly — but each run uses the same callback so each run gets
      // the same numbers in the same order.
      final r1 = mmrDiversify<int>(
        candidates: cands,
        similarity: sim,
        k: 3,
        lambda: 0.6,
      );
      final r2 = mmrDiversify<int>(
        candidates: cands,
        similarity: sim,
        k: 3,
        lambda: 0.6,
      );
      expect(r1.map((s) => s.item).toList(),
          r2.map((s) => s.item).toList());
      for (var i = 0; i < r1.length; i++) {
        expect(r1[i].mmrScore, r2[i].mmrScore);
        expect(r1[i].relevance, r2[i].relevance);
        expect(r1[i].maxSimilarityToSelected,
            r2[i].maxSimilarityToSelected);
      }
    });

    test('result list is unmodifiable', () {
      final picked = mmrDiversify<int>(
        candidates: [input(1, 0.5)],
        similarity: allDistinct,
        k: 1,
      );
      expect(
        () => picked.add(
          const MmrSelected<int>(
            item: 99,
            relevance: 0.0,
            maxSimilarityToSelected: 0.0,
            mmrScore: 0.0,
            selectionOrder: 1,
          ),
        ),
        throwsUnsupportedError,
      );
    });

    // ─── maxSimilarityToSelected accounting ─────────────────────────

    test('first pick has maxSimilarityToSelected == 0.0', () {
      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.9),
          input(2, 0.5),
        ],
        similarity: (a, b) => 0.42, // anything non-zero
        k: 2,
      );
      expect(picked.first.maxSimilarityToSelected, 0.0);
    });

    test(
      'second pick maxSimilarityToSelected == similarity(candidate, first)',
      () {
        // First pick is item 1 (relevance 0.9). Then for item 2,
        // maxSim to {1} is exactly similarity(2, 1) = 0.42.
        final picked = mmrDiversify<int>(
          candidates: [
            input(1, 0.9),
            input(2, 0.5),
          ],
          similarity: (a, b) => 0.42,
          k: 2,
        );
        expect(picked[1].maxSimilarityToSelected, closeTo(0.42, 1e-12));
      },
    );

    test('third pick maxSimilarityToSelected is the MAX over selected',
        () {
      // Build a similarity where:
      //   sim(3, 1) = 0.1
      //   sim(3, 2) = 0.8
      //   sim(2, 1) = 0.05  (low, so item 2 is picked second)
      // First pick: item 1 (highest relevance).
      // Second pick: between 2 and 3 with λ = 0.7:
      //   mmr(2) = 0.7*0.6 - 0.3*0.05 = 0.42 - 0.015 = 0.405
      //   mmr(3) = 0.7*0.55 - 0.3*0.1 = 0.385 - 0.03 = 0.355
      //   → item 2 wins.
      // Third pick: item 3 alone. maxSim against {1,2}:
      //   max(sim(3,1), sim(3,2)) = max(0.1, 0.8) = 0.8.
      double sim(int a, int b) {
        final s = {a, b};
        if (s.containsAll({3, 1})) return 0.1;
        if (s.containsAll({3, 2})) return 0.8;
        if (s.containsAll({2, 1})) return 0.05;
        return 0.0;
      }

      final picked = mmrDiversify<int>(
        candidates: [
          input(1, 0.9),
          input(2, 0.6),
          input(3, 0.55),
        ],
        similarity: sim,
        k: 3,
        lambda: 0.7,
      );
      expect(picked.map((s) => s.item).toList(), [1, 2, 3]);
      expect(picked[2].maxSimilarityToSelected, closeTo(0.8, 1e-12));
    });

    // ─── Recorded mmrScore ──────────────────────────────────────────

    test('mmrScore matches λ*relevance − (1−λ)*maxSim for every row',
        () {
      double sim(int a, int b) {
        // Symmetric, in [0, 1].
        final lo = a < b ? a : b;
        final hi = a < b ? b : a;
        return ((lo * 7 + hi * 11) % 10) / 10.0;
      }

      final cands = [
        input(1, 0.9),
        input(2, 0.8),
        input(3, 0.7),
        input(4, 0.6),
      ];
      const lambda = 0.65;
      final picked = mmrDiversify<int>(
        candidates: cands,
        similarity: sim,
        k: 4,
        lambda: lambda,
      );

      for (final row in picked) {
        final expected =
            lambda * row.relevance - (1.0 - lambda) * row.maxSimilarityToSelected;
        expect(row.mmrScore, closeTo(expected, 1e-12),
            reason: 'row $row');
      }
    });

    // ─── Diversity property ─────────────────────────────────────────

    test('two clusters → second pick is from the opposite cluster', () {
      // Cluster A: ids 1..5. Cluster B: ids 11..15.
      // sim is 1.0 inside a cluster (excluding self), 0.0 across.
      double sim(int a, int b) {
        if (a == b) return 1.0; // shouldn't be called, but for safety
        final sameCluster = (a < 10 && b < 10) || (a >= 10 && b >= 10);
        return sameCluster ? 1.0 : 0.0;
      }

      // Relevance: cluster A is slightly preferred so the first pick
      // is from cluster A.
      final cands = <MmrInput<int>>[
        input(1, 0.95),
        input(2, 0.90),
        input(3, 0.85),
        input(4, 0.80),
        input(5, 0.75),
        input(11, 0.70),
        input(12, 0.65),
        input(13, 0.60),
        input(14, 0.55),
        input(15, 0.50),
      ];
      final picked = mmrDiversify<int>(
        candidates: cands,
        similarity: sim,
        k: 10,
        lambda: 0.5,
      );
      // First pick is in cluster A (highest relevance).
      expect(picked[0].item < 10, isTrue,
          reason: 'first pick should be cluster A');
      // Second pick must be cluster B: any cluster-A candidate has
      // maxSim = 1.0 to the first pick, so its MMR is
      // 0.5*relevance - 0.5*1.0 = 0.5*relevance - 0.5, which is
      // negative for all relevances < 1.0. Cluster-B candidates have
      // maxSim = 0.0, so their MMR is positive. Cluster B wins.
      expect(picked[1].item >= 10, isTrue,
          reason: 'second pick should be cluster B');
    });

    // ─── Pure-relevance equivalence (property) ──────────────────────

    test('λ = 1.0 matches stable sort by descending relevance', () {
      // Build a permutation and verify the output ordering.
      final relevances = [0.13, 0.97, 0.42, 0.88, 0.55, 0.07, 0.71];
      final cands = <MmrInput<int>>[
        for (var i = 0; i < relevances.length; i++)
          input(i, relevances[i]),
      ];

      // Expected: indices sorted by relevance descending; stable wrt
      // input position on ties (no ties here, but the contract is
      // documented).
      final expectedOrder =
          List<int>.generate(relevances.length, (i) => i)
            ..sort((a, b) => relevances[b].compareTo(relevances[a]));

      final picked = mmrDiversify<int>(
        candidates: cands,
        similarity: (a, b) => 0.5, // ignored at λ = 1
        k: relevances.length,
        lambda: 1.0,
      );
      expect(picked.map((s) => s.item).toList(), expectedOrder);
    });

    // ─── Similarity callback usage discipline ───────────────────────

    test('similarity is never called against an item with itself', () {
      final calls = <List<int>>[];
      double sim(int a, int b) {
        calls.add([a, b]);
        return 0.3;
      }

      mmrDiversify<int>(
        candidates: [
          input(1, 0.9),
          input(2, 0.8),
          input(3, 0.7),
          input(4, 0.6),
        ],
        similarity: sim,
        k: 4,
      );
      for (final c in calls) {
        expect(c[0] == c[1], isFalse,
            reason: 'self-similarity call ${c[0]} vs ${c[1]}');
      }
    });

    test('similarity-call count is O(k · (n − 1))', () {
      // For k picks over n candidates, the running-max optimisation
      // calls similarity once per unselected candidate per pick — i.e.
      // (n - 1) + (n - 2) + ... + (n - k) calls, which simplifies to
      // k*n - k*(k+1)/2.
      var calls = 0;
      double sim(int a, int b) {
        calls += 1;
        return 0.1;
      }

      const n = 6;
      const k = 4;
      final cands = <MmrInput<int>>[
        for (var i = 0; i < n; i++) input(i, (n - i) / 10.0),
      ];
      mmrDiversify<int>(
        candidates: cands,
        similarity: sim,
        k: k,
      );
      final expectedCalls = k * n - (k * (k + 1)) ~/ 2;
      expect(calls, expectedCalls);
    });
  });
}
