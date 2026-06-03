// Classification — LLM-independent centroid-based classification
// (memory_specification.md § 7).
//
// `TomBrainMemory.classify` reads a Vec, compares against per-key
// centroids, and returns the best match together with the
// confidence / margin decision (§ 7.2). Updates flow only via
// `dream_recentroid_v1` calling `updateCentroid` (§ 7.3); memory
// does not auto-recompute.

/// What [TomBrainMemory.classify] is matching the input vector
/// against.
enum ClassificationTarget {
  /// Match against `NodeType` centroids.
  nodeType,

  /// Match against `Procedure` centroids — used by
  /// `classify_inbound_v1` to find the right procedure by similarity
  /// to historical accepted invocations.
  procedure,
}

/// Decision band for a classification call.
///
///   * `confident` — best similarity ≥ `minConfidence` AND
///     `bestSimilarity - secondSimilarity ≥ minMargin`. Procedures
///     accept the match.
///   * `uncertain` — best similarity is plausible but the margin to
///     the runner-up is tight. Procedures may queue the input for a
///     batch LLM classification (§ 7.4 `findUncertain`).
///   * `unknown` — best similarity is below `minConfidence`, or no
///     centroids exist yet (cold start).
enum ClassificationDecision {
  confident,
  uncertain,
  unknown,
}

/// `TomBrainMemory.classify` return value.
final class ClassificationResult {
  /// Best-matching key (e.g. `'Question'` for a node-type match, or
  /// `'research_v1'` for a procedure match). `null` for
  /// [ClassificationDecision.unknown] cold-start cases.
  final String? bestMatch;

  /// Cosine similarity against the best-match centroid.
  /// `0.0` for cold-start cases.
  final double bestSimilarity;

  /// Cosine similarity against the runner-up centroid. `0.0` when
  /// there is no runner-up (only one centroid known so far).
  final double secondSimilarity;

  /// Decision band — drives caller branching.
  final ClassificationDecision decision;

  const ClassificationResult({
    required this.decision,
    this.bestMatch,
    this.bestSimilarity = 0.0,
    this.secondSimilarity = 0.0,
  });

  /// Constructor for the cold-start case where no centroids exist
  /// for the target. Useful in tests and on `classify` returns
  /// before any centroid was registered.
  const ClassificationResult.unknown()
      : bestMatch = null,
        bestSimilarity = 0.0,
        secondSimilarity = 0.0,
        decision = ClassificationDecision.unknown;
}
