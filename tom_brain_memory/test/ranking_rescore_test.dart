// Pure-function tests for the post-fusion recency/frequency re-score
// (memory_optimization_plan § 7; memory_specification.md § 6.1.1,
// § 6.2.1).
//
// Surface under test:
//   * `RankingCandidate<T>` — the minimal shape carried into the
//     re-score.
//   * `rescoreByRanking<T>` — the pure function that re-orders a fused
//     candidate set per a `RecallRanking`.
//
// What this suite intentionally does NOT cover:
//   * The `RecallExecutor` wiring (how a materialised `Node` becomes a
//     `RankingCandidate`, and where the re-score sits in the pipeline).
//     That is exercised by `a59_recall_executor_test.dart`.
//
// The fixed candidate set is designed so that all five strategies yield
// distinct, hand-verifiable orderings. All four candidates share the
// same relevance (0.5) so each strategy's order is driven purely by the
// usage columns, with relevance/index acting only as the stable
// tiebreak.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show RankingCandidate, RecallRanking, rescoreByRanking;
import 'package:test/test.dart';

void main() {
  // A fixed reference instant. Ages below are measured back from here.
  final now = DateTime.utc(2026, 6, 16, 12, 0, 0);

  int msAgo(int days) =>
      now.subtract(Duration(days: days)).millisecondsSinceEpoch;

  // The fixed candidate set, in fusion (input) order [A, B, C, D].
  //
  //   id | relevance | lastAccess (ago) | accessCount
  //   ---+-----------+------------------+------------
  //   A  |   0.5     |   1 day          |   2
  //   B  |   0.5     | 100 days         |  50
  //   C  |   0.5     |  10 days         |   2
  //   D  |   0.5     |  50 days         |   0
  List<RankingCandidate<String>> fixedSet() => <RankingCandidate<String>>[
        RankingCandidate(
          item: 'A',
          relevance: 0.5,
          typeName: 'Claim',
          lastAccessMs: msAgo(1),
          accessCount: 2,
        ),
        RankingCandidate(
          item: 'B',
          relevance: 0.5,
          typeName: 'Claim',
          lastAccessMs: msAgo(100),
          accessCount: 50,
        ),
        RankingCandidate(
          item: 'C',
          relevance: 0.5,
          typeName: 'Claim',
          lastAccessMs: msAgo(10),
          accessCount: 2,
        ),
        RankingCandidate(
          item: 'D',
          relevance: 0.5,
          typeName: 'Claim',
          lastAccessMs: msAgo(50),
          accessCount: 0,
        ),
      ];

  // Flat 30-day half-life — the executor's pre-config default.
  Duration flatHalfLife(String _) => const Duration(days: 30);

  List<String> rescore(RecallRanking ranking, {double recencyWeight = 1.0}) =>
      rescoreByRanking<String>(
        ranking: ranking,
        candidates: fixedSet(),
        now: now,
        halfLifeForType: flatHalfLife,
        recencyWeight: recencyWeight,
      );

  group('rescoreByRanking — the five strategies over a fixed set', () {
    test('relevance returns the fusion+MMR order unchanged', () {
      // The default: no re-score, input order is the answer.
      expect(rescore(RecallRanking.relevance), equals(['A', 'B', 'C', 'D']));
    });

    test('recencyBoosted orders by most-recent last access', () {
      // recencyFactor = 2^(-ageDays/30); equal relevance ⇒ the more
      // recently accessed node scores higher. A(1d) > C(10d) > D(50d)
      // > B(100d).
      expect(
        rescore(RecallRanking.recencyBoosted),
        equals(['A', 'C', 'D', 'B']),
      );
    });

    test('frequencyBoosted orders by access_count, recency breaks ties', () {
      // factor = 1 + ln(1 + count). B(50) leads; A and C both count=2
      // tie on score, broken by newer last access first ⇒ A before C;
      // D(0) last.
      expect(
        rescore(RecallRanking.frequencyBoosted),
        equals(['B', 'A', 'C', 'D']),
      );
    });

    test('oldest sorts ascending by last_access_ms (coldest-by-time first)',
        () {
      // Least-recently accessed first: B(100d) > D(50d) > C(10d) > A(1d).
      expect(rescore(RecallRanking.oldest), equals(['B', 'D', 'C', 'A']));
    });

    test('coldest sorts ascending by access_count, then last_access_ms', () {
      // D(0) first; then the count=2 pair ordered by oldest-access first
      // (C@10d before A@1d); then B(50) last.
      expect(rescore(RecallRanking.coldest), equals(['D', 'C', 'A', 'B']));
    });
  });

  group('rescoreByRanking — edge cases and invariants', () {
    test('empty candidate set returns empty for every strategy', () {
      for (final ranking in RecallRanking.values) {
        expect(
          rescoreByRanking<String>(
            ranking: ranking,
            candidates: const [],
            now: now,
            halfLifeForType: flatHalfLife,
          ),
          isEmpty,
          reason: '$ranking should pass an empty set through unchanged',
        );
      }
    });

    test('every strategy is a permutation of the input (re-order only)', () {
      // The re-score never adds or drops candidates — it only re-orders.
      for (final ranking in RecallRanking.values) {
        expect(
          rescore(ranking).toSet(),
          equals({'A', 'B', 'C', 'D'}),
          reason: '$ranking must preserve the candidate set',
        );
        expect(rescore(ranking), hasLength(4));
      }
    });

    test('recencyBoosted clamps a future last access to age 0 (no throw)',
        () {
      // Clock skew: a node whose recorded last access is in the future
      // must not blow up the exponent. Its age clamps to 0, giving the
      // maximal recency factor (2^0 = 1), so it sorts to the front.
      final skewed = <RankingCandidate<String>>[
        RankingCandidate(
          item: 'past',
          relevance: 0.5,
          typeName: 'Claim',
          lastAccessMs: msAgo(5),
          accessCount: 0,
        ),
        RankingCandidate(
          item: 'future',
          relevance: 0.5,
          typeName: 'Claim',
          lastAccessMs:
              now.add(const Duration(days: 3)).millisecondsSinceEpoch,
          accessCount: 0,
        ),
      ];
      final ordered = rescoreByRanking<String>(
        ranking: RecallRanking.recencyBoosted,
        candidates: skewed,
        now: now,
        halfLifeForType: flatHalfLife,
      );
      expect(ordered, equals(['future', 'past']));
    });

    test('recencyBoosted honours the per-type half-life', () {
      // Two equally-relevant nodes accessed at the same age but of
      // different types. A short half-life for the first type decays it
      // faster, so the longer-half-life node wins despite identical age.
      Duration perType(String typeName) => typeName == 'Fast'
          ? const Duration(days: 1)
          : const Duration(days: 365);
      final candidates = <RankingCandidate<String>>[
        RankingCandidate(
          item: 'fast',
          relevance: 0.5,
          typeName: 'Fast',
          lastAccessMs: msAgo(7),
          accessCount: 0,
        ),
        RankingCandidate(
          item: 'slow',
          relevance: 0.5,
          typeName: 'Slow',
          lastAccessMs: msAgo(7),
          accessCount: 0,
        ),
      ];
      final ordered = rescoreByRanking<String>(
        ranking: RecallRanking.recencyBoosted,
        candidates: candidates,
        now: now,
        halfLifeForType: perType,
      );
      expect(ordered, equals(['slow', 'fast']));
    });

    test('recencyWeight scales the recency contribution', () {
      // A high-relevance stale node vs a low-relevance fresh one, with a
      // relevance gap small enough that the recency boost can overtake
      // it. At weight 0 recency contributes nothing and relevance wins;
      // at weight 1 the fresh node's boost flips the order.
      final candidates = <RankingCandidate<String>>[
        RankingCandidate(
          item: 'stale',
          relevance: 0.55,
          typeName: 'Claim',
          lastAccessMs: msAgo(100),
          accessCount: 0,
        ),
        RankingCandidate(
          item: 'fresh',
          relevance: 0.45,
          typeName: 'Claim',
          lastAccessMs: msAgo(1),
          accessCount: 0,
        ),
      ];
      List<String> withWeight(double w) => rescoreByRanking<String>(
            ranking: RecallRanking.recencyBoosted,
            candidates: candidates,
            now: now,
            halfLifeForType: flatHalfLife,
            recencyWeight: w,
          );
      expect(withWeight(0.0), equals(['stale', 'fresh']));
      expect(withWeight(1.0), equals(['fresh', 'stale']));
    });
  });
}
