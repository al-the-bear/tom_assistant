// Tests for the § 5 usage-aware ranking surface
// (memory_optimization_plan.md § 5).
//
// Surface under test:
//   * `RecallRanking` — the five-strategy ordering enum.
//   * `RecallQuery.ranking` / `RecallQuery.countsAsAccess` — new fields
//     defaulting to `relevance` / `false`.
//   * `MultiRecallQuery.ranking` / `MultiRecallQuery.countsAsAccess` —
//     the same two fields, same defaults.
//
// The isolate round-trip for these fields is covered separately in
// `tom_brain_memory/test/a82_full_catalogue_test.dart` (the query object
// crosses the SendPort by value; enum + bool are sendable, so no codec
// change is involved).

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('RecallRanking', () {
    test('exposes exactly the five named strategies', () {
      expect(RecallRanking.values, hasLength(5));
      expect(
        RecallRanking.values.map((r) => r.name).toSet(),
        equals(<String>{
          'relevance',
          'recencyBoosted',
          'frequencyBoosted',
          'oldest',
          'coldest',
        }),
      );
    });
  });

  group('RecallQuery § 5 fields', () {
    test('default to relevance ranking and countsAsAccess = false', () {
      const q = RecallQuery(modes: <RecallMode>{RecallMode.bm25});
      expect(q.ranking, equals(RecallRanking.relevance));
      expect(q.countsAsAccess, isFalse);
    });

    test('carry explicitly supplied values', () {
      const q = RecallQuery(
        modes: <RecallMode>{RecallMode.bm25},
        ranking: RecallRanking.coldest,
        countsAsAccess: true,
      );
      expect(q.ranking, equals(RecallRanking.coldest));
      expect(q.countsAsAccess, isTrue);
    });
  });

  group('MultiRecallQuery § 5 fields', () {
    test('default to relevance ranking and countsAsAccess = false', () {
      const q = MultiRecallQuery(seeds: <RecallSeed>[]);
      expect(q.ranking, equals(RecallRanking.relevance));
      expect(q.countsAsAccess, isFalse);
    });

    test('carry explicitly supplied values', () {
      const q = MultiRecallQuery(
        seeds: <RecallSeed>[],
        ranking: RecallRanking.oldest,
        countsAsAccess: true,
      );
      expect(q.ranking, equals(RecallRanking.oldest));
      expect(q.countsAsAccess, isTrue);
    });
  });
}
