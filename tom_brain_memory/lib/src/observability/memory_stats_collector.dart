// MemoryStatsCollector — assembles a `MemoryStats` snapshot from
// pluggable source callbacks (spec § 16; Plan step A.85).
//
// The stats surface (`TomBrainMemoryClient.stats()`) is composed of
// slices owned by different subsystems:
//
//   - `nodeCountByType`           — SQLite `nodes` table (live rows
//                                   only, grouped by `type_name`).
//   - `edgeCountByType`           — SQLite `edges` table grouped by
//                                   `edge_type`.
//   - `stackSizes`                — `StackApi` per-stack entry count.
//   - `trailCount` / `trailBytes` — `SqliteTrailStore` summary plus
//                                   the JSONL on-disk byte total.
//   - `recallLatencyPerMode`      — `RecallLatencyTracker.snapshot()`.
//   - `classificationConfidenceHistogram`
//                                 — `ClassificationConfidenceTracker.snapshot()`.
//   - `migrationProgress`         — `MigrationApi.status()` per
//                                   migration → `processed / total`.
//
// None of those sources can be reached without crossing a layer
// boundary; baking the queries into one monolith would create import
// cycles and make the collector untestable. Instead the collector
// accepts each slice as a function tear-off. The composition root
// (`SqliteTomBrainMemory` once it lands) wires the tear-offs to the
// real subsystems; tests wire deterministic fakes.
//
// Design choices:
//
//   - **Pluggable per-slice sources.** Each slice is an optional
//     callable. Absent slices contribute their empty / zero default
//     (`<String, int>{}`, `0`, …). A future subsystem can add a new
//     slice by extending `MemoryStats` and the collector — call sites
//     that don't supply it keep working.
//
//   - **Async by default.** Several sources (DB COUNT(*)) may need
//     to await the SQLite isolate or do an FS stat. The signature is
//     `Future<…> Function()` so callers can either return synchronous
//     values via `Future.value(...)` or schedule real I/O.
//
//   - **Parallel slice fetch.** The collector runs every source in
//     parallel via `Future.wait` — the slices are independent. Total
//     latency = max(slice latency), not sum.
//
//   - **Errors propagate.** A slice that throws fails the whole
//     `snapshot()` call. We do not partial-populate: an operator
//     looking at "node count = 0 / stack count = 7" should not be
//     left wondering whether 0 means "empty" or "DB unreadable". The
//     composition root may wrap the call in a try/catch and surface
//     a `WARN` line, but the bare collector does not paper over
//     failures.

import '../api/memory_stats.dart';

/// Signature for a slice source returning `Map<String, int>`.
typedef IntMapSource = Future<Map<String, int>> Function();

/// Signature for a slice source returning a single integer
/// (`trailCount`, `trailBytes`).
typedef IntSource = Future<int> Function();

/// Signature for the recall-latency slice. Synchronous because the
/// tracker is in-memory; we still wrap in a `Future` for symmetry.
typedef LatencyMapSource =
    Future<Map<String, LatencyHistogram>> Function();

/// Signature for the migration-progress slice. Returns
/// `migrationId → progress ∈ [0, 1]`.
typedef DoubleMapSource = Future<Map<String, double>> Function();

/// Assembles `MemoryStats` from per-slice source callbacks.
///
/// One collector per open `SqliteTomBrainMemory`. Composition root
/// constructs it with the per-subsystem tear-offs; tests construct
/// it with deterministic fakes (or omit sources entirely to assert
/// the empty-default behaviour).
final class MemoryStatsCollector {
  final IntMapSource? _nodeCounts;
  final IntMapSource? _edgeCounts;
  final IntMapSource? _stackSizes;
  final IntSource? _trailCount;
  final IntSource? _trailBytes;
  final LatencyMapSource? _recallLatency;
  final IntMapSource? _classificationConfidence;
  final DoubleMapSource? _migrationProgress;

  /// Constructs a collector. Every source is optional; omitted slices
  /// contribute their empty / zero default to the snapshot.
  ///
  /// The composition root supplies every source; tests typically
  /// supply a subset to exercise one slice at a time.
  const MemoryStatsCollector({
    IntMapSource? nodeCounts,
    IntMapSource? edgeCounts,
    IntMapSource? stackSizes,
    IntSource? trailCount,
    IntSource? trailBytes,
    LatencyMapSource? recallLatency,
    IntMapSource? classificationConfidence,
    DoubleMapSource? migrationProgress,
  })  : _nodeCounts = nodeCounts,
        _edgeCounts = edgeCounts,
        _stackSizes = stackSizes,
        _trailCount = trailCount,
        _trailBytes = trailBytes,
        _recallLatency = recallLatency,
        _classificationConfidence = classificationConfidence,
        _migrationProgress = migrationProgress;

  /// Returns a fresh `MemoryStats` snapshot.
  ///
  /// Every source registered at construction is invoked in parallel;
  /// missing sources contribute their empty/zero default. A source
  /// that throws fails the whole call — see file header for rationale.
  Future<MemoryStats> snapshot() async {
    final results = await Future.wait<Object?>(<Future<Object?>>[
      _nodeCounts?.call() ?? Future<Map<String, int>>.value(<String, int>{}),
      _edgeCounts?.call() ?? Future<Map<String, int>>.value(<String, int>{}),
      _stackSizes?.call() ?? Future<Map<String, int>>.value(<String, int>{}),
      _trailCount?.call() ?? Future<int>.value(0),
      _trailBytes?.call() ?? Future<int>.value(0),
      _recallLatency?.call() ??
          Future<Map<String, LatencyHistogram>>.value(
              <String, LatencyHistogram>{}),
      _classificationConfidence?.call() ??
          Future<Map<String, int>>.value(<String, int>{}),
      _migrationProgress?.call() ??
          Future<Map<String, double>>.value(<String, double>{}),
    ]);

    return MemoryStats(
      nodeCountByType: Map<String, int>.unmodifiable(
          results[0] as Map<String, int>),
      edgeCountByType: Map<String, int>.unmodifiable(
          results[1] as Map<String, int>),
      stackSizes:
          Map<String, int>.unmodifiable(results[2] as Map<String, int>),
      trailCount: results[3] as int,
      trailBytes: results[4] as int,
      recallLatencyPerMode: Map<String, LatencyHistogram>.unmodifiable(
          results[5] as Map<String, LatencyHistogram>),
      classificationConfidenceHistogram: Map<String, int>.unmodifiable(
          results[6] as Map<String, int>),
      migrationProgress: Map<String, double>.unmodifiable(
          results[7] as Map<String, double>),
    );
  }
}
