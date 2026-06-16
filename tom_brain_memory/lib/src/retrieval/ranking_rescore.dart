// ranking_rescore.dart — the post-fusion recency/frequency re-score
// (memory_optimization_plan § 7; memory_specification.md § 6.1.1, § 6.2.1).
//
// What this file owns:
//
//   - `RankingCandidate<T>` — the minimal shape the re-score needs: the
//     fused relevance `r(d)`, the node's `typeName` (for the per-type
//     half-life lookup), and the two usage columns (`lastAccessMs` /
//     `accessCount`). Generic over the carried `item` so the recall
//     executor can re-score `Node`s without this file taking a
//     dependency on the materialised node type.
//   - `rescoreByRanking<T>` — the pure function that re-orders a fused
//     candidate set per a `RecallRanking`. It NEVER changes which
//     candidates are present — it only re-orders them — so it is cheap
//     and LLM-free, matching the spec's "re-score of the survivors"
//     contract.
//
// What this file does NOT own:
//
//   - Retrieval, fusion, or diversity. Those run before the re-score
//     (in `RecallExecutor`); this function receives the already-fused,
//     already-diversified survivors and only re-orders them.
//   - The half-life / recency-weight config. The caller supplies the
//     per-type half-life lookup and `recencyWeight`; until the `decay`
//     config block lands (plan § 12) the executor passes a constant
//     default. This function does not read config.
//   - Reading the usage columns from SQLite. The caller projects a
//     materialised `Node` onto a `RankingCandidate` before calling.
//
// The five strategies (spec § 6.1.1 table + § 6.2.1 formula):
//
//   * `relevance`       — no re-score; the input (fusion+MMR) order is
//                         returned unchanged.
//   * `recencyBoosted`  — score'(d) = r(d) · (1 + w_recency ·
//                         recencyFactor(d)); recencyFactor(d) =
//                         2^(-ageSinceAccess(d)/halfLife(typeOf d)) ∈
//                         (0, 1]. Sort descending; newer `lastAccessMs`
//                         wins ties.
//   * `frequencyBoosted`— score'(d) = r(d) · (1 + log(1 + accessCount)).
//                         Sort descending; higher `accessCount` then
//                         newer `lastAccessMs` wins ties.
//   * `oldest`          — discard the fused score; sort ascending by
//                         `lastAccessMs` (least-recently-accessed
//                         first); relevance descending as the tiebreak.
//   * `coldest`         — discard the fused score; sort ascending by
//                         `accessCount`, then `lastAccessMs`; relevance
//                         descending as the tiebreak.
//
// Every sort carries the candidate's original input index as the final
// tiebreak, so the re-order is deterministic even though `List.sort` is
// not guaranteed stable.

import 'dart:math' as math;

import 'package:tom_brain_shared/tom_brain_shared.dart' show RecallRanking;

/// One candidate fed to [rescoreByRanking].
///
/// Carries the fused relevance score `r(d)` plus exactly the fields the
/// usage-aware strategies read: the node's [typeName] (used to look up
/// the per-type recency half-life) and the two usage columns
/// ([lastAccessMs] = the *effective* last access in epoch ms, i.e.
/// `last_access_ms` falling back to `created_at_ms`; [accessCount]).
final class RankingCandidate<T> {
  /// The carried item — the recall executor passes a materialised
  /// `Node`; tests pass whatever opaque token is convenient.
  final T item;

  /// The fused relevance score `r(d)` produced by RRF (+ MMR's
  /// relevance input). Used directly by the boosted strategies and as
  /// the tiebreak by `oldest` / `coldest`.
  final double relevance;

  /// The node's type name — the key for the per-type half-life lookup
  /// the `recencyBoosted` strategy uses.
  final String typeName;

  /// Effective last-access time in epoch milliseconds: the node's
  /// `last_access_ms`, falling back to `created_at_ms` for a
  /// never-accessed node (the same reading `Node.lastAccess` exposes).
  final int lastAccessMs;

  /// The node's `access_count` (zero for a never-accessed node).
  final int accessCount;

  const RankingCandidate({
    required this.item,
    required this.relevance,
    required this.typeName,
    required this.lastAccessMs,
    required this.accessCount,
  });
}

/// Re-orders [candidates] per [ranking] and returns the carried items in
/// the new order. Pure: no I/O, no clock read of its own (the reference
/// time is the supplied [now]), deterministic for a given input.
///
/// [now] is the reference instant for `ageSinceAccess` in the
/// `recencyBoosted` strategy. [halfLifeForType] returns the recency
/// half-life for a given `typeName` (spec § 6.6 / config § 14);
/// [recencyWeight] is `w_recency` from the same config. Both are ignored
/// by every strategy except `recencyBoosted`.
///
/// The input order is treated as the fusion+diversity order. For
/// [RecallRanking.relevance] the items are returned unchanged.
List<T> rescoreByRanking<T>({
  required RecallRanking ranking,
  required List<RankingCandidate<T>> candidates,
  required DateTime now,
  required Duration Function(String typeName) halfLifeForType,
  double recencyWeight = 1.0,
}) {
  if (candidates.isEmpty) return <T>[];

  switch (ranking) {
    case RecallRanking.relevance:
      // No re-score — the fusion+MMR order is the answer.
      return [for (final c in candidates) c.item];

    case RecallRanking.recencyBoosted:
    case RecallRanking.frequencyBoosted:
      final nowMs = now.millisecondsSinceEpoch;
      // (candidate, original index, boosted score).
      final scored = <(RankingCandidate<T>, int, double)>[];
      for (var i = 0; i < candidates.length; i++) {
        final c = candidates[i];
        final double boosted;
        if (ranking == RecallRanking.recencyBoosted) {
          // Guard the half-life to >= 1ms so the exponent stays finite,
          // and clamp a future last-access (clock skew) to age 0.
          final halfLifeMs =
              math.max(1, halfLifeForType(c.typeName).inMilliseconds);
          final ageMs = math.max(0, nowMs - c.lastAccessMs);
          final recencyFactor = math.pow(2, -ageMs / halfLifeMs).toDouble();
          boosted = c.relevance * (1 + recencyWeight * recencyFactor);
        } else {
          final frequencyFactor = 1 + math.log(1 + c.accessCount);
          boosted = c.relevance * frequencyFactor;
        }
        scored.add((c, i, boosted));
      }
      scored.sort((a, b) {
        final byScore = b.$3.compareTo(a.$3); // boosted score descending
        if (byScore != 0) return byScore;
        // Tiebreak on the usage column the strategy boosts by, descending.
        final byUsage = ranking == RecallRanking.recencyBoosted
            ? b.$1.lastAccessMs.compareTo(a.$1.lastAccessMs)
            : b.$1.accessCount.compareTo(a.$1.accessCount);
        if (byUsage != 0) return byUsage;
        return a.$2.compareTo(b.$2); // stable: original index ascending
      });
      return [for (final s in scored) s.$1.item];

    case RecallRanking.oldest:
      final indexed = _indexed(candidates);
      indexed.sort((a, b) {
        final byTime =
            a.$1.lastAccessMs.compareTo(b.$1.lastAccessMs); // ascending
        if (byTime != 0) return byTime;
        final byRel = b.$1.relevance.compareTo(a.$1.relevance); // desc tiebreak
        if (byRel != 0) return byRel;
        return a.$2.compareTo(b.$2);
      });
      return [for (final e in indexed) e.$1.item];

    case RecallRanking.coldest:
      final indexed = _indexed(candidates);
      indexed.sort((a, b) {
        final byCount =
            a.$1.accessCount.compareTo(b.$1.accessCount); // ascending
        if (byCount != 0) return byCount;
        final byTime =
            a.$1.lastAccessMs.compareTo(b.$1.lastAccessMs); // ascending
        if (byTime != 0) return byTime;
        final byRel = b.$1.relevance.compareTo(a.$1.relevance); // desc tiebreak
        if (byRel != 0) return byRel;
        return a.$2.compareTo(b.$2);
      });
      return [for (final e in indexed) e.$1.item];
  }
}

/// Pairs each candidate with its original input index for use as the
/// final, stability-preserving sort tiebreak.
List<(RankingCandidate<T>, int)> _indexed<T>(
  List<RankingCandidate<T>> candidates,
) =>
    [for (var i = 0; i < candidates.length; i++) (candidates[i], i)];
