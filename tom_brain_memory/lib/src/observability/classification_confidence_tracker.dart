// ClassificationConfidenceTracker — bucketed histogram of best-
// similarity values produced by `Classifier.classify`, feeds
// `MemoryStats.classificationConfidenceHistogram` (spec § 16; Plan
// step A.85).
//
// The classifier returns a `ClassificationResult` whose
// `bestSimilarity` field carries the cosine distance against the
// nearest centroid. The stats surface needs the *shape* of that
// distribution so an operator can answer "are most classifications
// confident, or are we sitting in the borderline band?"
//
// Design choices:
//
//   - **Ten fixed buckets** spanning `[0.0, 1.0]`:
//       "0.0-0.1", "0.1-0.2", ..., "0.9-1.0"
//     Width 0.1 is the same granularity Q-A.66.3 settled on for the
//     `findUncertain` border ranges, so the histogram axis lines up
//     with the operator's mental model.
//
//   - **Half-open on the right, except the top bucket.** A sample of
//     0.1 lands in "0.1-0.2", a sample of 1.0 lands in "0.9-1.0".
//     This avoids a degenerate "1.0-1.1" bucket and keeps the bucket
//     count at exactly 10.
//
//   - **Out-of-range samples saturate.** Negative cosine values land
//     in "0.0-0.1"; values > 1.0 land in "0.9-1.0". Both are off-
//     spec (cosine on unit vectors is bounded), but we surface them
//     somewhere visible rather than dropping them silently — a sample
//     that should not exist showing up at the histogram edges is the
//     diagnostic.
//
//   - **Forever-counting.** Unlike the recall latency tracker (which
//     uses a sliding window so the operator sees "current" speed),
//     classification confidence is informative as a cumulative
//     distribution since process start — the question "how often does
//     the brain hit the uncertain band" needs the full history, not
//     just the last 256 classifications. The counts reset on process
//     restart; that's acceptable because `dream_recentroid_v1` runs
//     between sessions anyway and the operator views shape, not
//     counts.

import 'dart:collection';

/// Bucketed histogram of classification best-similarity values
/// (spec § 16; `MemoryStats.classificationConfidenceHistogram`).
///
/// One tracker per open memory store; the composition root hands its
/// `record` tear-off to the `Classifier` as an `onSimilarityComputed`
/// hook. Snapshots are read by the stats collector.
final class ClassificationConfidenceTracker {
  /// Fixed bucket labels, in order. Width 0.1; ten buckets covering
  /// `[0.0, 1.0]`. Exposed for tests and for the Forge inspector that
  /// will render the axis.
  static const List<String> bucketLabels = <String>[
    '0.0-0.1',
    '0.1-0.2',
    '0.2-0.3',
    '0.3-0.4',
    '0.4-0.5',
    '0.5-0.6',
    '0.6-0.7',
    '0.7-0.8',
    '0.8-0.9',
    '0.9-1.0',
  ];

  /// Per-bucket counters. Pre-allocated so every bucket appears in
  /// the snapshot even when its count is zero — operators reading the
  /// histogram should not have to special-case missing keys.
  final Map<String, int> _counts = LinkedHashMap<String, int>.fromIterables(
    bucketLabels,
    List<int>.filled(bucketLabels.length, 0),
  );

  /// Records one classification's best-similarity value.
  ///
  /// Out-of-range samples saturate to the nearest edge bucket
  /// (see file header). Non-finite samples (NaN, infinities) are
  /// dropped — recording them would corrupt the histogram with no
  /// signal back to the caller.
  void record(double bestSimilarity) {
    if (!bestSimilarity.isFinite) return;
    final bucket = _bucketFor(bestSimilarity);
    _counts[bucket] = _counts[bucket]! + 1;
  }

  /// Returns the histogram as an unmodifiable map.
  ///
  /// All ten buckets are present; counts are integers (zero when no
  /// sample has landed in that bucket).
  Map<String, int> snapshot() => Map<String, int>.unmodifiable(_counts);

  /// Total samples recorded across all buckets. Exposed for tests
  /// and for the Forge inspector that wants to render percentages.
  int get totalSamples => _counts.values.fold<int>(0, (a, b) => a + b);

  /// Resets every bucket to zero. Exposed for tests and for the
  /// hypothetical "session boundary" cadence in the dispatcher that
  /// may want fresh counts after a `dream_recentroid_v1` pass. Not
  /// called automatically anywhere today.
  void reset() {
    for (final label in bucketLabels) {
      _counts[label] = 0;
    }
  }

  /// Maps a sample to its bucket label.
  ///
  /// The mapping is:
  ///   x < 0.1 → "0.0-0.1" (also covers negative saturation)
  ///   0.1 ≤ x < 0.2 → "0.1-0.2"
  ///   ...
  ///   0.9 ≤ x ≤ 1.0 → "0.9-1.0" (also covers >1.0 saturation)
  static String _bucketFor(double x) {
    if (x < 0.1) return '0.0-0.1';
    if (x < 0.2) return '0.1-0.2';
    if (x < 0.3) return '0.2-0.3';
    if (x < 0.4) return '0.3-0.4';
    if (x < 0.5) return '0.4-0.5';
    if (x < 0.6) return '0.5-0.6';
    if (x < 0.7) return '0.6-0.7';
    if (x < 0.8) return '0.7-0.8';
    if (x < 0.9) return '0.8-0.9';
    return '0.9-1.0';
  }
}
