// RetrievalEvalReport — the metric × strategy-set matrix the harness emits
// (Plan-2 extension step #33; spec § 23.8 `score`).
//
// One cell per (strategy set, metric): the metric's mean over the eval's
// queries under that strategy set. The report is a pure value — value
// equality + a stable [toMatrixString] — so the harness's "re-running on a
// fresh profile is deterministic" obligation is checked by comparing two
// reports for equality.

import 'dart:math' as math;

/// The fused result of a retrieval eval: a [strategySetNames] × [metrics]
/// matrix of mean scores.
final class RetrievalEvalReport {
  RetrievalEvalReport({
    required this.strategySetNames,
    required this.metrics,
    required Map<String, Map<String, double>> cells,
  }) : cells = Map<String, Map<String, double>>.unmodifiable(<String,
            Map<String, double>>{
          for (final entry in cells.entries)
            entry.key: Map<String, double>.unmodifiable(
              Map<String, double>.of(entry.value),
            ),
        });

  /// The matrix columns, in declaration order.
  final List<String> strategySetNames;

  /// The matrix rows, in declaration order.
  final List<String> metrics;

  /// `strategySetName → metric → mean score`. Unmodifiable.
  final Map<String, Map<String, double>> cells;

  /// The mean [metric] under [strategySet], or `0.0` when the cell is absent.
  double score(String strategySet, String metric) =>
      cells[strategySet]?[metric] ?? 0.0;

  /// The distinct mean scores recorded for [metric] across every strategy set
  /// (used to assert that `naive` / `hyde` / `semantic` / `full` differ).
  Set<double> distinctScoresFor(String metric) => <double>{
        for (final name in strategySetNames) score(name, metric),
      };

  /// A fixed-width matrix rendering: metrics down the rows, strategy sets
  /// across the columns. Deterministic given equal inputs.
  String toMatrixString() {
    const metricColWidth = 12;
    final colWidth = math.max(
      10,
      strategySetNames.fold<int>(0, (w, n) => math.max(w, n.length)) + 2,
    );
    final buf = StringBuffer();
    buf.write('metric'.padRight(metricColWidth));
    for (final name in strategySetNames) {
      buf.write(name.padLeft(colWidth));
    }
    buf.writeln();
    for (final metric in metrics) {
      buf.write(metric.padRight(metricColWidth));
      for (final name in strategySetNames) {
        buf.write(score(name, metric).toStringAsFixed(4).padLeft(colWidth));
      }
      buf.writeln();
    }
    return buf.toString();
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! RetrievalEvalReport) return false;
    if (!_listEquals(strategySetNames, other.strategySetNames)) return false;
    if (!_listEquals(metrics, other.metrics)) return false;
    if (cells.length != other.cells.length) return false;
    for (final entry in cells.entries) {
      final otherRow = other.cells[entry.key];
      if (otherRow == null) return false;
      if (entry.value.length != otherRow.length) return false;
      for (final cell in entry.value.entries) {
        if (otherRow[cell.key] != cell.value) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(strategySetNames),
        Object.hashAll(metrics),
        cells.length,
      );

  @override
  String toString() =>
      'RetrievalEvalReport(${strategySetNames.length} sets × '
      '${metrics.length} metrics)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
