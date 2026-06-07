// Rrf — Reciprocal Rank Fusion across the per-mode candidate lists
// (Plan step A.57, spec § 6.2 — "RRF is the default fusion").
//
// What this file owns:
//
//   - A pure function `rrfFuse` that takes one ranked list of
//     `NodeId`s per `RecallMode` and returns a single ranked list of
//     `RrfFusedCandidate`s, ordered by descending RRF score.
//   - The default smoothing constant `kDefaultRrfK = 60`, matching
//     `FusionPolicy.defaultRrf.rrfK` and the value used in the
//     canonical Cormack / Clarke / Buettcher (2009) paper.
//
// What this file does NOT own:
//
//   - The per-mode candidate orderings themselves. Those come from the
//     mode executors (`Bm25Recall`, `VectorRecall`, `SymbolicRecall`,
//     and later `GraphWalkRecall`). RRF is rank-only — it never reads
//     the modes' raw scores.
//   - The weighted-fusion strategy (`FusionStrategy.weighted`). That
//     is a parallel implementation that lands when a caller actually
//     asks for it; the gate at the executor level (A.59) selects
//     between RRF and weighted based on `FusionPolicy.strategy`.
//   - Diversity (A.58 MMR) and the `RecallReport` populated at A.59.
//
// Formula (spec § 6.2):
//
//   score(d) = Σ_modes 1 / (k_rrf + rank_mode(d))
//
//   - `rank_mode(d)` is the **1-indexed** position of `d` in that
//     mode's list. (Position 0 in the input list corresponds to rank
//     1; position 1 to rank 2; and so on.) The 1-indexed convention
//     matches the original paper and avoids a division-by-zero when
//     `k_rrf` happens to be set to 0 for an experiment.
//   - The sum runs over only the modes in which `d` appears. A node
//     present in three modes accumulates three contributions; a node
//     present in one mode accumulates one. The mode-count is itself a
//     soft form of agreement-weighting that we get for free.
//
// Determinism:
//
//   - Within a single mode's list, a `NodeId` appearing more than once
//     uses its **first** (best) rank; later occurrences are ignored.
//     Mode executors are not expected to produce duplicates, but the
//     fusion stage refuses to be fragile if one slips through.
//   - The output is sorted by descending score. Ties are broken by
//     ascending `NodeId.compareTo` (lexicographic on the full
//     `n_<ULID>` string), so two runs against the same inputs always
//     produce the same ordering.
//
// Edge cases (refusal table):
//
//   - `rankedLists` empty or all lists empty: returns `const []`. The
//     mode-executor invariant is that an empty result is a normal
//     outcome (no SQL issued, no failure), so the fused result is
//     legitimately empty too.
//   - `kRrf` < 1: throws `ArgumentError`. The formula is
//     well-defined for `k_rrf = 0` only when ranks start at 1 (which
//     they do here), but `k_rrf < 0` is meaningless. We refuse rather
//     than silently produce confusing scores.
//   - `cap` <= 0 (when non-null): returns `const []`. Symmetric with
//     the mode executors' `perModeK <= 0` refusal.

import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, RecallMode;

// ─── Multi-seed weighted fusion (§ 6.5, Extension H) ────────────────
//
// `rrfFuse` (below) fuses per-**mode** lists with equal weight — the
// agreement-weighting is implicit in the mode count. Multi-seed recall
// (`recallMulti`) fuses per-**seed** lists, and each seed carries an
// explicit `weight`, so it needs a parallel primitive whose
// contribution per list is scaled:
//
//   score(d) = Σ_seeds weight_seed · 1 / (k_rrf + rank_seed(d))
//
// The output carries per-seed ranks (keyed by the seed's index in the
// `MultiRecallQuery.seeds` list) so the `RecallProvenanceEntry`
// surfaced to the caller can name which seeds found each node without
// re-running the math. Determinism and the edge-case refusals match
// `rrfFuse`.

/// Default RRF smoothing constant.
///
/// Matches `FusionPolicy.defaultRrf.rrfK` and the value Cormack,
/// Clarke and Buettcher (2009) used in the original RRF paper. Larger
/// `k` flattens the contribution curve (everyone gets roughly the
/// same score); smaller `k` concentrates weight on the top of each
/// mode's list.
const int kDefaultRrfK = 60;

/// One row in the fused output of [rrfFuse].
///
/// Carries the contribution map alongside the fused score so the A.59
/// `RecallReport` wiring and any caller debugging surface can attribute
/// the score back to its per-mode source ranks without re-running the
/// fusion math.
final class RrfFusedCandidate {
  /// The node this row scores.
  final NodeId nodeId;

  /// The fused RRF score. Higher = more relevant. Always > 0 when
  /// the node appears in at least one mode (with rank >= 1 and
  /// `kRrf >= 0`).
  final double score;

  /// 1-indexed per-mode ranks. Only modes that returned this node
  /// are present; modes that didn't are omitted (not stored as
  /// `null`). Sorted ascending by `RecallMode.index` for stable
  /// stringification.
  final Map<RecallMode, int> perModeRanks;

  const RrfFusedCandidate({
    required this.nodeId,
    required this.score,
    required this.perModeRanks,
  });

  @override
  String toString() => 'RrfFusedCandidate(id: $nodeId, score: '
      '${score.toStringAsFixed(6)}, ranks: $perModeRanks)';
}

/// Fuses per-mode ranked candidate lists into a single ranking using
/// Reciprocal Rank Fusion.
///
/// Contract:
///
///   * [rankedLists] — one ordered list per mode. The position in
///     each list is the rank (position 0 → rank 1, position 1 →
///     rank 2, …). Lists are read but never mutated.
///   * [kRrf] — RRF smoothing constant. Must be `>= 0`. Defaults to
///     [kDefaultRrfK]. Throws [ArgumentError] when negative.
///   * [cap] — optional cap on the returned list length. `null` =
///     return everything. `<= 0` = return empty.
///   * Returns an unmodifiable, descending-score list. Ties are
///     broken by ascending `NodeId.compareTo`.
///   * Within a single mode's list, the first occurrence of a
///     `NodeId` wins; later occurrences are ignored.
///
/// The function is **pure**: no I/O, no allocation of singletons, no
/// observation of clock or random state. Two calls with equal inputs
/// always return equal outputs.
List<RrfFusedCandidate> rrfFuse({
  required Map<RecallMode, List<NodeId>> rankedLists,
  int kRrf = kDefaultRrfK,
  int? cap,
}) {
  if (kRrf < 0) {
    throw ArgumentError.value(kRrf, 'kRrf', 'must be >= 0');
  }
  if (cap != null && cap <= 0) {
    return const <RrfFusedCandidate>[];
  }
  if (rankedLists.isEmpty) return const <RrfFusedCandidate>[];

  // Accumulator keyed by the canonical NodeId string. Using the string
  // avoids relying on NodeId hashing for correctness even though the
  // equality contract on PrefixedUlidId would suffice — the string key
  // is also the natural anchor for the deterministic tie-break below.
  final scoreByNode = <String, double>{};
  final ranksByNode = <String, Map<RecallMode, int>>{};
  final nodeRefByString = <String, NodeId>{};

  // Iterate modes in enum order so the perModeRanks map insertion
  // order is deterministic.
  final modes = rankedLists.keys.toList()
    ..sort((a, b) => a.index.compareTo(b.index));

  for (final mode in modes) {
    final list = rankedLists[mode]!;
    final seenInThisMode = <String>{};
    for (var i = 0; i < list.length; i++) {
      final id = list[i];
      final key = id.value;
      if (!seenInThisMode.add(key)) {
        // Duplicate within this mode's list — keep the first (best)
        // rank, ignore the rest.
        continue;
      }
      final rank = i + 1; // 1-indexed
      final contribution = 1.0 / (kRrf + rank);
      scoreByNode.update(key, (s) => s + contribution,
          ifAbsent: () => contribution);
      (ranksByNode[key] ??= <RecallMode, int>{})[mode] = rank;
      nodeRefByString[key] ??= id;
    }
  }

  if (scoreByNode.isEmpty) return const <RrfFusedCandidate>[];

  final fused = scoreByNode.entries
      .map(
        (e) => RrfFusedCandidate(
          nodeId: nodeRefByString[e.key]!,
          score: e.value,
          perModeRanks: Map<RecallMode, int>.unmodifiable(
            ranksByNode[e.key]!,
          ),
        ),
      )
      .toList(growable: false);

  fused.sort((a, b) {
    final byScore = b.score.compareTo(a.score); // descending
    if (byScore != 0) return byScore;
    return a.nodeId.compareTo(b.nodeId); // ascending tie-break
  });

  if (cap != null && fused.length > cap) {
    return List<RrfFusedCandidate>.unmodifiable(fused.sublist(0, cap));
  }
  return List<RrfFusedCandidate>.unmodifiable(fused);
}

/// One row in the fused output of [rrfFuseSeeds].
///
/// Carries the per-seed ranks (keyed by the seed's index in the
/// `MultiRecallQuery.seeds` list) alongside the weighted fused score,
/// so the `RecallProvenanceEntry` the caller sees can attribute the
/// node back to the seeds that surfaced it.
final class SeedFusedCandidate {
  /// The node this row scores.
  final NodeId nodeId;

  /// The weighted fused score. Higher = more relevant.
  final double score;

  /// Seed-index → 1-indexed rank, for the seeds that surfaced this
  /// node. Sorted ascending by seed index for stable stringification.
  final Map<int, int> seedRanks;

  const SeedFusedCandidate({
    required this.nodeId,
    required this.score,
    required this.seedRanks,
  });

  /// The seed indices that surfaced this node, ascending. Convenience
  /// over `seedRanks.keys` for provenance construction.
  List<int> get seedIndexes =>
      seedRanks.keys.toList(growable: false)..sort();

  @override
  String toString() => 'SeedFusedCandidate(id: $nodeId, score: '
      '${score.toStringAsFixed(6)}, seedRanks: $seedRanks)';
}

/// Fuses per-seed ranked candidate lists into a single ranking using
/// weighted Reciprocal Rank Fusion (§ 6.5).
///
/// Contract:
///
///   * [seedRankedLists] — one ordered list per seed, index-aligned
///     with [seedWeights]. Position in each list is the rank
///     (position 0 → rank 1, …). A seed that produced no candidates is
///     an empty list at its index — it contributes nothing and is
///     simply skipped. Lists are read but never mutated.
///   * [seedWeights] — fusion weight per seed, same length as
///     [seedRankedLists]. Each must be `>= 0`. A weight of `0.0`
///     removes the seed's contribution entirely (it neither scores nor
///     appears in any node's `seedRanks`).
///   * [kRrf] — RRF smoothing constant, `>= 0`. Throws [ArgumentError]
///     when negative.
///   * [cap] — optional cap on the returned list length. `null` =
///     everything; `<= 0` = empty.
///   * Returns an unmodifiable, descending-score list. Ties are broken
///     by ascending `NodeId.compareTo`.
///   * Within a single seed's list, the first occurrence of a `NodeId`
///     wins; later occurrences are ignored.
///
/// The function is **pure**.
List<SeedFusedCandidate> rrfFuseSeeds({
  required List<List<NodeId>> seedRankedLists,
  required List<double> seedWeights,
  int kRrf = kDefaultRrfK,
  int? cap,
}) {
  if (kRrf < 0) {
    throw ArgumentError.value(kRrf, 'kRrf', 'must be >= 0');
  }
  if (seedRankedLists.length != seedWeights.length) {
    throw ArgumentError(
      'rrfFuseSeeds: seedRankedLists (${seedRankedLists.length}) and '
      'seedWeights (${seedWeights.length}) must be the same length',
    );
  }
  for (final w in seedWeights) {
    if (w < 0) {
      throw ArgumentError.value(w, 'seedWeights', 'must be >= 0');
    }
  }
  if (cap != null && cap <= 0) {
    return const <SeedFusedCandidate>[];
  }
  if (seedRankedLists.isEmpty) return const <SeedFusedCandidate>[];

  final scoreByNode = <String, double>{};
  final ranksByNode = <String, Map<int, int>>{};
  final nodeRefByString = <String, NodeId>{};

  for (var seedIndex = 0; seedIndex < seedRankedLists.length; seedIndex++) {
    final weight = seedWeights[seedIndex];
    if (weight == 0.0) continue; // zero-weight seed contributes nothing
    final list = seedRankedLists[seedIndex];
    final seenInThisSeed = <String>{};
    for (var i = 0; i < list.length; i++) {
      final id = list[i];
      final key = id.value;
      if (!seenInThisSeed.add(key)) continue; // first (best) rank wins
      final rank = i + 1; // 1-indexed
      final contribution = weight * (1.0 / (kRrf + rank));
      scoreByNode.update(key, (s) => s + contribution,
          ifAbsent: () => contribution);
      (ranksByNode[key] ??= <int, int>{})[seedIndex] = rank;
      nodeRefByString[key] ??= id;
    }
  }

  if (scoreByNode.isEmpty) return const <SeedFusedCandidate>[];

  final fused = scoreByNode.entries
      .map(
        (e) => SeedFusedCandidate(
          nodeId: nodeRefByString[e.key]!,
          score: e.value,
          seedRanks: Map<int, int>.unmodifiable(ranksByNode[e.key]!),
        ),
      )
      .toList(growable: false);

  fused.sort((a, b) {
    final byScore = b.score.compareTo(a.score); // descending
    if (byScore != 0) return byScore;
    return a.nodeId.compareTo(b.nodeId); // ascending tie-break
  });

  if (cap != null && fused.length > cap) {
    return List<SeedFusedCandidate>.unmodifiable(fused.sublist(0, cap));
  }
  return List<SeedFusedCandidate>.unmodifiable(fused);
}
