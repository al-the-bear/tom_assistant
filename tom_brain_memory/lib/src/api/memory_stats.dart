// MemoryStats — point-in-time snapshot of memory observables
// (memory_specification.md § 16).
//
// `TomBrainMemory.stats()` returns one of these. The Tom Forge
// brain inspector reads them; the dispatcher uses the recall
// latency histograms to tune budgets.

/// p50 / p95 latency pair, in milliseconds.
final class LatencyHistogram {
  final double p50Ms;
  final double p95Ms;

  const LatencyHistogram({required this.p50Ms, required this.p95Ms});

  /// Zero histogram — useful for "no samples yet" returns.
  static const LatencyHistogram zero =
      LatencyHistogram(p50Ms: 0.0, p95Ms: 0.0);
}

/// Point-in-time snapshot of memory observables.
final class MemoryStats {
  /// Node count keyed by type name.
  final Map<String, int> nodeCountByType;

  /// Edge count keyed by edge wire name
  /// (`mentions`, `derived_from`, ...).
  final Map<String, int> edgeCountByType;

  /// Current size of each known stack.
  final Map<String, int> stackSizes;

  /// Total trail count and total on-disk bytes.
  final int trailCount;
  final int trailBytes;

  /// Recall latency per mode (keyed by the mode's enum name).
  final Map<String, LatencyHistogram> recallLatencyPerMode;

  /// Histogram of classification best-similarity values. Keys are
  /// bucket labels (`"0.0-0.1"`, `"0.1-0.2"`, ...).
  final Map<String, int> classificationConfidenceHistogram;

  /// Migration progress keyed by `migrationId`, value in
  /// [0.0, 1.0].
  final Map<String, double> migrationProgress;

  const MemoryStats({
    required this.nodeCountByType,
    required this.edgeCountByType,
    required this.stackSizes,
    required this.trailCount,
    required this.trailBytes,
    required this.recallLatencyPerMode,
    required this.classificationConfidenceHistogram,
    required this.migrationProgress,
  });

  /// Empty snapshot — useful as a baseline before any work has
  /// happened.
  static const MemoryStats empty = MemoryStats(
    nodeCountByType: <String, int>{},
    edgeCountByType: <String, int>{},
    stackSizes: <String, int>{},
    trailCount: 0,
    trailBytes: 0,
    recallLatencyPerMode: <String, LatencyHistogram>{},
    classificationConfidenceHistogram: <String, int>{},
    migrationProgress: <String, double>{},
  );
}
