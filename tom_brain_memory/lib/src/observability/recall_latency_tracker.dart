// RecallLatencyTracker — per-mode p50/p95 latency aggregator that
// feeds the `recallLatencyPerMode` slice of `MemoryStats` (spec § 16;
// Plan step A.85).
//
// The recall executor (`retrieval/recall_executor.dart`) already
// measures `elapsedMs` for every call and threads it into the
// `RecallReport`. That number is per-call; the stats surface needs
// the *distribution* over a recent window. This file owns that
// aggregation.
//
// Design choices:
//
//   - **Per-mode buffers.** The four modes (BM25, vector, graph-walk,
//     symbolic) are tracked independently because they have very
//     different shapes (BM25 is fast and bounded; vector swings with
//     embedding cost; graph-walk depends on seed-set size). One
//     blended histogram would hide that.
//
//   - **Bounded ring buffer.** Default 256 samples / mode keeps the
//     snapshot O(N log N) on N=256 and the steady-state memory
//     footprint constant regardless of how long the brain has been
//     running. When the buffer is full, a new sample evicts the
//     oldest — a sliding window over the most recent activity, which
//     is what an operator wants to see ("is recall currently fast")
//     more than a forever-average ("was recall ever fast").
//
//   - **Nearest-rank percentile.** Sort the live samples, index by
//     `ceil(p * N) - 1`. This is the simplest correct percentile for
//     small N; no interpolation, no off-by-one near the edges. A
//     histogram-bucket approach would be more memory-efficient at very
//     large N but is overkill for 256.
//
//   - **String-keyed snapshot.** `MemoryStats.recallLatencyPerMode`
//     uses `Map<String, LatencyHistogram>` to keep the stats surface
//     stable across components that don't import the memory
//     subsystem. The tracker translates `RecallMode → mode.name` on
//     `snapshot()`.
//
//   - **Empty mode → `LatencyHistogram.zero`.** No samples → no
//     histogram entry. Consumers reading `stats.recallLatencyPerMode`
//     for a never-exercised mode get `LatencyHistogram.zero` only if
//     they query the tracker via `snapshotFor(mode)`; the bulk
//     `snapshot()` omits empty modes (matches the
//     `RecallReport.candidatesPerMode` convention of "present only
//     when relevant").

import 'dart:collection';

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show nearestRankPercentile;

import '../api/memory_stats.dart';
import '../retrieval/recall_query.dart' show RecallMode;

/// Per-mode latency aggregator producing p50 / p95 snapshots for
/// `MemoryStats.recallLatencyPerMode` (spec § 16).
final class RecallLatencyTracker {
  /// Maximum samples retained per mode. New samples beyond this
  /// capacity evict the oldest in FIFO order.
  final int _capacity;

  /// One bounded ring per mode. Keyed by `RecallMode` so the tracker
  /// stays type-safe internally; the public snapshot translates to
  /// `String` for the cross-component stats surface.
  final Map<RecallMode, ListQueue<int>> _buffers =
      <RecallMode, ListQueue<int>>{};

  /// Constructs a tracker with a per-mode capacity. Default 256 is the
  /// agreed window — see file header.
  RecallLatencyTracker({int capacity = 256}) : _capacity = capacity {
    assert(capacity > 0, 'RecallLatencyTracker capacity must be positive');
  }

  /// Per-mode buffer capacity. Exposed for tests that need to assert
  /// eviction behaviour.
  int get capacity => _capacity;

  /// Records one sample for [mode] in milliseconds.
  ///
  /// Negative or zero samples are accepted (a sub-millisecond recall
  /// rounded to 0 is still a sample). The composition root translates
  /// `RecallReport.elapsedMs` directly.
  void record(RecallMode mode, int elapsedMs) {
    final buf = _buffers.putIfAbsent(
      mode,
      () => ListQueue<int>(),
    );
    if (buf.length >= _capacity) {
      buf.removeFirst();
    }
    buf.addLast(elapsedMs);
  }

  /// Returns the per-mode snapshot keyed by `mode.name`.
  ///
  /// Modes with no samples are omitted (consumers should treat a
  /// missing key as `LatencyHistogram.zero` — same convention as
  /// `RecallReport.candidatesPerMode`).
  Map<String, LatencyHistogram> snapshot() {
    final out = <String, LatencyHistogram>{};
    for (final entry in _buffers.entries) {
      if (entry.value.isEmpty) continue;
      out[entry.key.name] = _percentiles(entry.value);
    }
    return Map<String, LatencyHistogram>.unmodifiable(out);
  }

  /// Returns the snapshot for a single mode, or
  /// `LatencyHistogram.zero` when the mode has never been recorded.
  LatencyHistogram snapshotFor(RecallMode mode) {
    final buf = _buffers[mode];
    if (buf == null || buf.isEmpty) return LatencyHistogram.zero;
    return _percentiles(buf);
  }

  /// Current sample count for [mode]; 0 when the mode has never been
  /// recorded. Exposed for tests and operator-facing tooling that
  /// wants to know how stable the percentiles are.
  int sampleCount(RecallMode mode) => _buffers[mode]?.length ?? 0;

  /// Computes p50 / p95 over [samples] using nearest-rank.
  ///
  /// `nearest-rank` indexes the sorted array at `ceil(p * N) - 1`
  /// (`max(0, …)` to guard the empty case, although the caller never
  /// passes an empty queue here). For N=1 both percentiles return the
  /// single sample, which is the correct "we have one data point"
  /// behaviour.
  static LatencyHistogram _percentiles(ListQueue<int> samples) {
    // Callers (`snapshot`/`snapshotFor`) only reach here on a non-empty
    // buffer, which is the precondition `nearestRankPercentile` requires.
    final sorted = List<int>.from(samples)..sort();
    return LatencyHistogram(
      p50Ms: nearestRankPercentile(sorted, 0.50).toDouble(),
      p95Ms: nearestRankPercentile(sorted, 0.95).toDouble(),
    );
  }
}
