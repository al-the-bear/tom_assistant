// RetrievalEvalHarness — the five-phase retrieval eval driver (Plan-2
// extension step #33; spec § 23.8).
//
// `run(config)` drives one [RetrievalEvalEnvironment] through:
//
//   provision → seed → (query × strategySet × query) → score → drop
//
// and emits a [RetrievalEvalReport] (a metric × strategy-set matrix of mean
// scores). `drop` runs in a `finally` so the throwaway profile is always
// reset, even if a phase throws — satisfying *Verify* "the harness leaves no
// live store mutated".
//
// ── Strategy-set resolution (§ 23.8 `strategySets`) ──────────────────
//
// Each [StrategySetSpec] is projected onto a `MemoryRetrievalConfig` that the
// environment honours:
//
//   * `only: [paths]`  → `defaults().withOnly(paths)` — the exact set.
//   * `add:  [paths]`  → `defaults().withOnly(['vector.prompt', ...paths])` —
//     the naive baseline plus the added strategies.
//   * `all: true`      → `defaults().withOnly(<every catalogue path>)`.
//
// then `weights` (when present) retunes named fusion weights via
// `withWeights` — the "deliberately weakened weight set" lever.

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show MemoryRetrievalConfig;

import 'retrieval_eval_config.dart';
import 'retrieval_eval_environment.dart';
import 'retrieval_eval_report.dart';
import 'retrieval_metrics.dart';

/// Drives a [RetrievalEvalEnvironment] through the § 23.8 phase pipeline.
final class RetrievalEvalHarness {
  const RetrievalEvalHarness(this.environment);

  /// The substrate the phases run against.
  final RetrievalEvalEnvironment environment;

  /// Runs the full pipeline for [config] and returns the scored matrix.
  ///
  /// Provisions and seeds the throwaway profile once, then queries every
  /// labelled prompt under every strategy set, scores each query against its
  /// labels, and averages per (strategy set, metric). [RetrievalEvalEnvironment.drop]
  /// always runs last.
  Future<RetrievalEvalReport> run(RetrievalEvalConfig config) async {
    final cells = <String, Map<String, double>>{};
    try {
      await environment.provision(config.profile);
      await environment.seed(config.profile, _seedDocs(config));

      for (final set in config.strategySets) {
        final resolved = _resolve(set);
        cells[set.name] = await _scoreStrategySet(config, resolved);
      }
    } finally {
      await environment.drop(config.profile);
    }

    return RetrievalEvalReport(
      strategySetNames: <String>[
        for (final set in config.strategySets) set.name,
      ],
      metrics: config.metrics,
      cells: cells,
    );
  }

  /// Mean of each metric over every query, under one resolved [config].
  Future<Map<String, double>> _scoreStrategySet(
    RetrievalEvalConfig evalConfig,
    MemoryRetrievalConfig config,
  ) async {
    final sums = <String, double>{
      for (final metric in evalConfig.metrics) metric: 0.0,
    };
    for (final query in evalConfig.queries) {
      final ranked = await environment.query(
        evalConfig.profile,
        query.prompt,
        config,
      );
      final relevant = <String>{...query.expect.mustInclude};
      final topLabel = query.expect.mustRankTop;
      if (topLabel != null) relevant.add(topLabel);

      final scores = scoreQuery(
        ranked,
        relevant,
        evalConfig.metrics,
        evalConfig.k,
        topLabel: topLabel,
      );
      for (final metric in evalConfig.metrics) {
        sums[metric] = sums[metric]! + (scores[metric] ?? 0.0);
      }
    }
    final n = evalConfig.queries.length;
    return <String, double>{
      for (final metric in evalConfig.metrics)
        metric: n == 0 ? 0.0 : sums[metric]! / n,
    };
  }

  static List<EvalSeedDoc> _seedDocs(RetrievalEvalConfig config) => <EvalSeedDoc>[
        for (final item in config.corpus)
          EvalSeedDoc(
            evalId: item.id,
            kind: item.kind,
            text: item.text,
            at: item.at,
            about: item.about,
          ),
      ];

  /// Projects one [StrategySetSpec] onto a `MemoryRetrievalConfig` (see the
  /// library doc).
  static MemoryRetrievalConfig _resolve(StrategySetSpec set) {
    final base = MemoryRetrievalConfig.defaults();
    MemoryRetrievalConfig config;
    if (set.all) {
      config = base.withOnly(_allStrategyPaths(base));
    } else if (set.only.isNotEmpty) {
      config = base.withOnly(set.only);
    } else {
      config = base.withOnly(<String>['vector.prompt', ...set.add]);
    }
    if (set.weights.isNotEmpty) {
      config = config.withWeights(set.weights);
    }
    return config;
  }

  /// Every `family.name` path in the catalogue (drives `all: true`).
  static List<String> _allStrategyPaths(MemoryRetrievalConfig config) =>
      <String>[
        for (final family in config.strategies.entries)
          for (final name in family.value.keys) '${family.key}.$name',
      ];
}
