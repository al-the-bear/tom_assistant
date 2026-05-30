// Mmr — Maximal Marginal Relevance diversifier
// (Plan step A.58, spec § 6.2 — "MMR is the default diversifier,
// λ = 0.7 by default").
//
// What this file owns:
//
//   - A pure, generic function `mmrDiversify<T>` that takes a list of
//     ranked candidates (each carrying a base **relevance** score) and
//     a caller-supplied **similarity** function over the candidate
//     type, and selects up to `k` items by iteratively maximising:
//
//         mmr(c) = λ · relevance(c)
//                  − (1 − λ) · max_{s ∈ selected} similarity(c, s)
//
//   - The default smoothing constant `kDefaultMmrLambda = 0.7`,
//     matching `DiversityPolicy.defaultMmr.lambda` and the spec
//     value in `memory_specification.md` § 6.2.
//
// What this file does NOT own:
//
//   - The relevance score itself. Callers provide it. In the recall
//     pipeline (A.59) the relevance score is the fused RRF score from
//     `rrf.dart`; for tests and reuse, any non-negative double works.
//   - The similarity function itself. Callers provide it. In the
//     recall pipeline the similarity is cosine distance over node
//     embeddings (when present) with a BM25-score fallback for nodes
//     without embeddings (spec § 6.2). The pure function deliberately
//     does not know about embeddings, NodeIds, or fallbacks — those
//     are wiring concerns that belong in A.59.
//   - The fusion stage (RRF). MMR consumes the fused output; the
//     fusion math lives in `rrf.dart`.
//   - Any I/O, SQLite touch, or clock observation.
//
// Algorithm (textbook MMR; Carbonell & Goldstein 1998):
//
//   1. Start with an empty `selected` list and an `unselected` view
//      of the input candidates.
//   2. While `|selected| < k` and `unselected` is non-empty:
//        a. For each c in `unselected` compute:
//             score(c) = λ · relevance(c)
//                        − (1 − λ) · max_{s ∈ selected} sim(c, s)
//           When `selected` is empty the max-term is treated as 0,
//           so the first pick is the candidate with the highest
//           `λ · relevance(c)` — equivalent to picking by relevance
//           alone, which is what every MMR reference implementation
//           does.
//        b. Move the argmax to `selected`. Ties (equal MMR score)
//           are broken by ascending input-list position — the
//           earlier candidate wins. Together with the input
//           ordering already being deterministic upstream (RRF is
//           deterministic; tests pass in deterministic lists), this
//           makes the whole pipeline deterministic.
//   3. Return `selected` in pick order.
//
// Complexity:
//
//   - O(k · n) MMR-score computations, each of which is O(|selected|)
//     similarity calls — i.e. O(k² · n) similarity calls in the worst
//     case. For the spec's working sizes (n ≤ a few hundred, k ≤ 50)
//     this is well below any wall-clock budget. We cache per-
//     unselected-candidate the running `maxSimilarityToSelected` so we
//     only invoke `similarity` against the **newly added** item each
//     round; that drops the call count to O(k · n).
//
// Edge cases (refusal table):
//
//   - `candidates` empty: returns `const []`. Symmetric with `rrfFuse`.
//   - `k <= 0`: returns `const []`. There is nothing to select.
//   - `k >= candidates.length`: MMR still applies — the **order** is
//     re-arranged for diversity even when nothing is discarded. This
//     is the textbook behaviour and matters because callers downstream
//     (the LLM re-rank hook in A.59, the assistant's prompt builder)
//     may truncate again at a lower budget.
//   - `lambda` outside `[0, 1]`: throws `ArgumentError`. The MMR
//     formula is only meaningful inside that range. We refuse rather
//     than silently produce a confusing score.
//   - `lambda == 0.0`: pure diversity. After the first pick (by
//     relevance, since `selected` is empty), every subsequent pick
//     minimises the similarity sum to already-selected items.
//   - `lambda == 1.0`: pure relevance. Equivalent to ranking by
//     `relevance` descending, with input-position tie-break.
//   - `relevance` negative: allowed. The math still works; we don't
//     police caller score semantics.
//   - `similarity` returning NaN or Infinity: undefined. Callers are
//     expected to provide a well-defined similarity in `[0, 1]` (or
//     at least a bounded real). We do not insert defensive `isNaN`
//     guards because the cost on every comparison would dominate the
//     algorithm for no observed bug.

/// Default MMR lambda.
///
/// Matches `DiversityPolicy.defaultMmr.lambda` and `memory_specification.md`
/// § 6.2. λ = 1.0 → pure relevance; λ = 0.0 → pure diversity.
const double kDefaultMmrLambda = 0.7;

/// One input row to [mmrDiversify].
///
/// Carries the candidate item alongside its base relevance score so
/// MMR can compute `λ · relevance(c) − (1 − λ) · maxSim`.
///
/// The candidate type `T` is opaque to MMR. In the recall pipeline
/// (A.59) callers wrap each `RrfFusedCandidate` into an `MmrInput`
/// with `relevance = fused RRF score` and pass a similarity callback
/// that knows how to dereference the `NodeId` to an embedding.
final class MmrInput<T> {
  /// The item being ranked. Opaque to MMR — only the [similarity]
  /// callback in [mmrDiversify] interprets it.
  final T item;

  /// Base relevance score for this item. Higher = more relevant.
  /// Typically the upstream fused score (RRF in the recall pipeline)
  /// but any double is accepted.
  final double relevance;

  const MmrInput({required this.item, required this.relevance});

  @override
  String toString() =>
      'MmrInput(item: $item, relevance: ${relevance.toStringAsFixed(6)})';
}

/// One selected row in the output of [mmrDiversify].
///
/// Carries the item, the inputs that went into its MMR score, the
/// final MMR score, and the pick-order index so consumers can debug
/// or surface "why was this picked" in the `RecallReport` (A.59)
/// without re-running the MMR math.
final class MmrSelected<T> {
  /// The selected item.
  final T item;

  /// The base relevance score the caller supplied in [MmrInput.relevance].
  final double relevance;

  /// `max_{s ∈ selectedBefore} similarity(item, s)` at the moment
  /// `item` was picked. 0.0 for the first pick (when nothing was
  /// selected yet).
  final double maxSimilarityToSelected;

  /// The MMR score at the moment of selection:
  ///
  ///   λ · relevance − (1 − λ) · maxSimilarityToSelected
  ///
  /// Stored so callers don't have to recompute when annotating a
  /// `RecallReport` (A.59) or a debugging trail (memory trails,
  /// memory_specification.md § 9).
  final double mmrScore;

  /// 0-indexed pick order: the first item picked has
  /// `selectionOrder == 0`.
  final int selectionOrder;

  const MmrSelected({
    required this.item,
    required this.relevance,
    required this.maxSimilarityToSelected,
    required this.mmrScore,
    required this.selectionOrder,
  });

  @override
  String toString() => 'MmrSelected(order: $selectionOrder, item: $item, '
      'rel: ${relevance.toStringAsFixed(6)}, '
      'maxSim: ${maxSimilarityToSelected.toStringAsFixed(6)}, '
      'mmr: ${mmrScore.toStringAsFixed(6)})';
}

/// Selects up to [k] items from [candidates] using Maximal Marginal
/// Relevance with smoothing constant [lambda].
///
/// Contract:
///
///   * [candidates] — input list, in upstream rank order. Read but
///     never mutated. Earlier list position = better upstream rank;
///     used only as the deterministic tie-break when two candidates
///     would produce the same MMR score.
///   * [similarity] — symmetric, bounded similarity function over the
///     item type. Typically in `[0, 1]` (cosine over normalised
///     embeddings; or BM25-score fallback rescaled into `[0, 1]`).
///     Called with two distinct items from [candidates]; never called
///     against an item with itself.
///   * [k] — maximum number of items to return. `<= 0` returns empty.
///     Values larger than `candidates.length` are clamped silently —
///     MMR still applies, so the output is a diversified **reordering**
///     of the full input.
///   * [lambda] — MMR smoothing. Must lie in `[0, 1]`. Defaults to
///     [kDefaultMmrLambda]. Throws [ArgumentError] when out of range.
///   * Returns an unmodifiable list in pick order (highest MMR first).
///
/// The function is **pure**: no I/O, no clock, no random. Two calls
/// with equal inputs and an equal [similarity] function always return
/// equal outputs. Determinism extends across tie cases via the input-
/// position tie-break.
List<MmrSelected<T>> mmrDiversify<T>({
  required List<MmrInput<T>> candidates,
  required double Function(T a, T b) similarity,
  required int k,
  double lambda = kDefaultMmrLambda,
}) {
  if (lambda < 0.0 || lambda > 1.0) {
    throw ArgumentError.value(lambda, 'lambda', 'must be in [0, 1]');
  }
  if (k <= 0) return const [];
  if (candidates.isEmpty) return const [];

  // We do not mutate the caller's list. We track per-index state in
  // parallel arrays keyed by the input-list position. `selectedAt[i]`
  // becomes non-null when input `i` is selected; until then, the
  // candidate is in the unselected pool.
  final n = candidates.length;
  final picked = List<bool>.filled(n, false);

  // `maxSimToSelected[i]` is the running maximum similarity from
  // input `i` to any already-selected item. Starts at 0 (selected
  // pool empty). After each pick, we update only against the newly-
  // selected item — that is the O(k · n) similarity-call total.
  final maxSimToSelected = List<double>.filled(n, 0.0);

  // The MMR score at the time each candidate was picked.
  // Recorded into the output rows so consumers don't recompute.
  final result = <MmrSelected<T>>[];
  final cap = k > n ? n : k;

  for (var picksDone = 0; picksDone < cap; picksDone++) {
    var bestIndex = -1;
    var bestMmr = double.negativeInfinity;

    for (var i = 0; i < n; i++) {
      if (picked[i]) continue;
      final relevance = candidates[i].relevance;
      final maxSim = maxSimToSelected[i];
      final mmr = lambda * relevance - (1.0 - lambda) * maxSim;

      // Strict `>` makes the earlier input-position win on ties, which
      // is the documented deterministic tie-break.
      if (mmr > bestMmr) {
        bestMmr = mmr;
        bestIndex = i;
      }
    }

    // `bestIndex == -1` would mean every unselected candidate had MMR
    // == negativeInfinity, which is unreachable: relevance is a real
    // number and similarity is bounded, so MMR is always a real
    // number. We still defend against the impossible by breaking the
    // loop rather than producing a malformed pick.
    if (bestIndex < 0) break;

    picked[bestIndex] = true;
    result.add(
      MmrSelected<T>(
        item: candidates[bestIndex].item,
        relevance: candidates[bestIndex].relevance,
        maxSimilarityToSelected: maxSimToSelected[bestIndex],
        mmrScore: bestMmr,
        selectionOrder: picksDone,
      ),
    );

    // Update every remaining unselected candidate's
    // `maxSimToSelected` against the freshly-picked item only.
    // We never re-evaluate against the older selected set, which is
    // why the structure is O(k · n) similarity calls and not
    // O(k² · n).
    final justPicked = candidates[bestIndex].item;
    for (var i = 0; i < n; i++) {
      if (picked[i]) continue;
      final sim = similarity(candidates[i].item, justPicked);
      if (sim > maxSimToSelected[i]) {
        maxSimToSelected[i] = sim;
      }
    }
  }

  return List<MmrSelected<T>>.unmodifiable(result);
}
