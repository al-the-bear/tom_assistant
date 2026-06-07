// Retrieval metrics — pure scoring functions for the eval harness
// (Plan-2 extension step #33; spec § 23.8 `metrics`).
//
// Each function scores one query's ranked result list (best-first, the values
// are corpus logical ids) against its labelled relevant set. They are pure and
// deterministic: same inputs → same output, the property the harness's
// "re-running on a fresh profile is deterministic" obligation rests on.
//
// Graded relevance (nDCG): the `mustRankTop` label, when given, carries the
// highest gain (2.0); every other member of the relevant set carries gain 1.0.
// This is what lets two strategy sets that both *recall* every relevant item
// still score differently when they *order* them differently.

import 'dart:math' as math;

/// Canonical metric ids the harness understands.
const String precisionAtKMetric = 'precision@k';
const String recallAtKMetric = 'recall@k';
const String mrrMetric = 'mrr';
const String ndcgMetric = 'ndcg';

/// All metric ids, in matrix order.
const List<String> allRetrievalMetrics = <String>[
  precisionAtKMetric,
  recallAtKMetric,
  mrrMetric,
  ndcgMetric,
];

/// Fraction of the top-[k] ranked ids that are relevant (precision@k).
///
/// Divided by the cutoff [k] (not the result length), the standard P@k: a
/// result that returns fewer than [k] items is penalised for the shortfall.
double precisionAtK(List<String> ranked, Set<String> relevant, int k) {
  if (k <= 0) return 0.0;
  final top = ranked.take(k);
  final hits = top.where(relevant.contains).length;
  return hits / k;
}

/// Fraction of the relevant set found in the top-[k] (recall@k).
double recallAtK(List<String> ranked, Set<String> relevant, int k) {
  if (relevant.isEmpty || k <= 0) return 0.0;
  final top = ranked.take(k).toSet();
  final hits = relevant.where(top.contains).length;
  return hits / relevant.length;
}

/// Reciprocal rank of the first relevant id (MRR for a single query).
///
/// `1 / rank` of the first ranked id in [relevant] (1-based), or `0.0` when no
/// relevant id appears at all.
double reciprocalRank(List<String> ranked, Set<String> relevant) {
  for (var i = 0; i < ranked.length; i++) {
    if (relevant.contains(ranked[i])) return 1.0 / (i + 1);
  }
  return 0.0;
}

/// nDCG of the top-[k] under graded relevance (see the file header).
///
/// [topLabel] is the highest-gain id (`mustRankTop`); when `null` every
/// relevant id carries gain 1.0. Returns `0.0` when the ideal DCG is zero
/// (no relevant items).
double ndcgAtK(
  List<String> ranked,
  Set<String> relevant,
  int k, {
  String? topLabel,
}) {
  double gain(String id) {
    if (topLabel != null && id == topLabel) return 2.0;
    return relevant.contains(id) ? 1.0 : 0.0;
  }

  final dcg = _dcg(<double>[
    for (final id in ranked.take(k)) gain(id),
  ]);

  // Ideal ordering: the top label first (gain 2), then the remaining
  // relevant ids (gain 1 each), truncated to k.
  final idealGains = <double>[
    if (topLabel != null && relevant.contains(topLabel)) 2.0,
    for (final id in relevant)
      if (id != topLabel) 1.0,
  ]..sort((a, b) => b.compareTo(a));
  final idcg = _dcg(idealGains.take(k).toList());

  if (idcg == 0.0) return 0.0;
  return dcg / idcg;
}

double _dcg(List<double> gains) {
  var sum = 0.0;
  for (var i = 0; i < gains.length; i++) {
    if (gains[i] == 0.0) continue;
    sum += gains[i] / (math.log(i + 2) / math.ln2);
  }
  return sum;
}

/// Scores one query's [ranked] result against [relevant] (+ optional
/// [topLabel]) for each metric id in [metrics], at cutoff [k]. Unknown metric
/// ids are skipped.
Map<String, double> scoreQuery(
  List<String> ranked,
  Set<String> relevant,
  List<String> metrics,
  int k, {
  String? topLabel,
}) {
  final out = <String, double>{};
  for (final metric in metrics) {
    switch (metric) {
      case precisionAtKMetric:
        out[metric] = precisionAtK(ranked, relevant, k);
      case recallAtKMetric:
        out[metric] = recallAtK(ranked, relevant, k);
      case mrrMetric:
        out[metric] = reciprocalRank(ranked, relevant);
      case ndcgMetric:
        out[metric] = ndcgAtK(ranked, relevant, k, topLabel: topLabel);
    }
  }
  return out;
}
