// RetrievalEvalConfig — the parsed `retrieval_eval.yaml` that drives the
// retrieval eval harness (Plan-2 extension step #33;
// `tom_brain_procedure_prototype_specification.md` § 23.8).
//
// § 23.8 defines a single document with five sections:
//
//   profile:       the throwaway profile the harness provisions → drops.
//   corpus:        the labelled fixture documents (each carries a logical
//                  `id` the queries' expectations reference).
//   queries:       the labelled prompts (each with an `expect` block).
//   metrics:       which scores the matrix reports.
//   k:             the rank cutoff the `@k` metrics use.
//   strategySets:  the named retrieval configurations to compare.
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node ever leaks into a `RetrievalEvalConfig`. The model
// is read-only — it never re-serialises a document.

import 'package:tom_core_agentic/tom_core_agentic.dart' show loadYamlAsMap;

/// Thrown when a `retrieval_eval.yaml` document is structurally invalid.
class RetrievalEvalConfigException implements Exception {
  RetrievalEvalConfigException(this.message, {this.path});

  /// What went wrong.
  final String message;

  /// The dotted location of the offending field, when known.
  final String? path;

  @override
  String toString() => path == null
      ? 'RetrievalEvalConfigException: $message'
      : 'RetrievalEvalConfigException at $path: $message';
}

/// One labelled fixture document in the eval corpus (§ 23.8 `corpus`).
final class EvalCorpusItem {
  const EvalCorpusItem({
    required this.id,
    required this.kind,
    required this.text,
    this.at,
    this.about = const <String>[],
  });

  /// The logical label the query expectations reference (`mustInclude` /
  /// `mustRankTop`). Distinct from any store-assigned node id, so an eval is
  /// store-agnostic and repeatable across fresh profiles.
  final String id;

  /// The node kind (`event`, `claim`, `concept`, `conclusion`, …). Maps to a
  /// memory node type when seeded.
  final String kind;

  /// The document text — what gets embedded / indexed on seed.
  final String text;

  /// Optional event timestamp (ISO-8601), carried into the node values.
  final String? at;

  /// Optional Concept names this item is about (claim edges), carried into
  /// the node values.
  final List<String> about;
}

/// What a query expects of the ranked results (§ 23.8 `queries[].expect`).
final class EvalExpectation {
  const EvalExpectation({
    this.mustInclude = const <String>[],
    this.mustRankTop,
  });

  /// The corpus ids that should appear in the ranked result (the relevant
  /// set for precision / recall / MRR / nDCG).
  final List<String> mustInclude;

  /// The single corpus id that should rank first — the highest-gain item for
  /// nDCG. `null` when the query does not pin a top result.
  final String? mustRankTop;
}

/// One labelled prompt in the eval (§ 23.8 `queries`).
final class EvalQuery {
  const EvalQuery({required this.prompt, required this.expect});

  /// The prompt fed through `retrieve_for_prompt_v1`.
  final String prompt;

  /// The labelled expectation scored against the ranked result.
  final EvalExpectation expect;
}

/// One named retrieval configuration to compare (§ 23.8 `strategySets`).
///
/// Exactly one of [all], a non-empty [only], or a non-empty [add] selects the
/// enabled strategies; [weights] then optionally retunes named fusion weights
/// (the "deliberately weakened weight set" lever). The three selectors map to
/// `MemoryRetrievalConfig`:
///
///   * `only: [paths]`  → `defaults().withOnly(paths)`.
///   * `add:  [paths]`  → `defaults().withOnly(['vector.prompt', ...paths])`
///     (the naive baseline plus the added strategies).
///   * `all: true`      → every catalogue strategy enabled.
final class StrategySetSpec {
  const StrategySetSpec({
    required this.name,
    this.only = const <String>[],
    this.add = const <String>[],
    this.all = false,
    this.weights = const <String, double>{},
  });

  /// The matrix column name.
  final String name;

  /// `only` selector — the exact dotted strategy paths to enable.
  final List<String> only;

  /// `add` selector — strategy paths to enable on top of the naive baseline.
  final List<String> add;

  /// `all` selector — enable every catalogue strategy.
  final bool all;

  /// Optional fusion-weight overrides keyed by dotted strategy path.
  final Map<String, double> weights;
}

/// The fully-parsed `retrieval_eval.yaml` (§ 23.8).
final class RetrievalEvalConfig {
  const RetrievalEvalConfig({
    required this.profile,
    required this.corpus,
    required this.queries,
    required this.metrics,
    required this.k,
    required this.strategySets,
  });

  /// The throwaway profile the harness provisions, seeds, queries, and drops.
  final String profile;

  /// The labelled fixture corpus.
  final List<EvalCorpusItem> corpus;

  /// The labelled queries.
  final List<EvalQuery> queries;

  /// The metrics the matrix reports (canonical ids: `precision@k`,
  /// `recall@k`, `mrr`, `ndcg`).
  final List<String> metrics;

  /// The `@k` rank cutoff.
  final int k;

  /// The named retrieval configurations to compare.
  final List<StrategySetSpec> strategySets;

  /// Parses a `retrieval_eval.yaml` document.
  factory RetrievalEvalConfig.fromYamlString(String yamlText) {
    final doc = loadYamlAsMap(
      yamlText,
      rootPath: 'retrieval_eval',
      errorFactory: (m) => RetrievalEvalConfigException(m),
    );
    return RetrievalEvalConfig.fromYamlMap(doc);
  }

  /// Builds a config from an already-parsed plain [doc].
  factory RetrievalEvalConfig.fromYamlMap(Map<String, Object?> doc) {
    final profile = _requireString(doc['profile'], 'profile');
    final k = _optionalInt(doc['k'], 'k') ?? 5;
    return RetrievalEvalConfig(
      profile: profile,
      corpus: _parseCorpus(doc['corpus']),
      queries: _parseQueries(doc['queries']),
      metrics: _parseMetrics(doc['metrics']),
      k: k,
      strategySets: _parseStrategySets(doc['strategySets']),
    );
  }

  static List<EvalCorpusItem> _parseCorpus(Object? raw) {
    final list = _requireList(raw, 'corpus');
    return <EvalCorpusItem>[
      for (var i = 0; i < list.length; i++)
        _parseCorpusItem(list[i], 'corpus[$i]'),
    ];
  }

  static EvalCorpusItem _parseCorpusItem(Object? raw, String path) {
    final map = _requireMap(raw, path);
    return EvalCorpusItem(
      id: _requireString(map['id'], '$path.id'),
      kind: _requireString(map['kind'], '$path.kind'),
      text: _requireString(map['text'], '$path.text'),
      at: _optionalString(map['at'], '$path.at'),
      about: _stringList(map['about'], '$path.about'),
    );
  }

  static List<EvalQuery> _parseQueries(Object? raw) {
    final list = _requireList(raw, 'queries');
    return <EvalQuery>[
      for (var i = 0; i < list.length; i++)
        _parseQuery(list[i], 'queries[$i]'),
    ];
  }

  static EvalQuery _parseQuery(Object? raw, String path) {
    final map = _requireMap(raw, path);
    final expectRaw = map['expect'];
    final expect = expectRaw == null
        ? const EvalExpectation()
        : _parseExpectation(expectRaw, '$path.expect');
    return EvalQuery(
      prompt: _requireString(map['prompt'], '$path.prompt'),
      expect: expect,
    );
  }

  static EvalExpectation _parseExpectation(Object? raw, String path) {
    final map = _requireMap(raw, path);
    return EvalExpectation(
      mustInclude: _stringList(map['mustInclude'], '$path.mustInclude'),
      mustRankTop: _optionalString(map['mustRankTop'], '$path.mustRankTop'),
    );
  }

  static List<String> _parseMetrics(Object? raw) {
    if (raw == null) {
      return const <String>['precision@k', 'recall@k', 'mrr', 'ndcg'];
    }
    return _stringList(raw, 'metrics');
  }

  static List<StrategySetSpec> _parseStrategySets(Object? raw) {
    final list = _requireList(raw, 'strategySets');
    return <StrategySetSpec>[
      for (var i = 0; i < list.length; i++)
        _parseStrategySet(list[i], 'strategySets[$i]'),
    ];
  }

  static StrategySetSpec _parseStrategySet(Object? raw, String path) {
    final map = _requireMap(raw, path);
    final name = _requireString(map['name'], '$path.name');
    final only = _stringList(map['only'], '$path.only');
    final add = _stringList(map['add'], '$path.add');
    final all = _optionalBool(map['all'], '$path.all') ?? false;
    final selectors = <String>[
      if (only.isNotEmpty) 'only',
      if (add.isNotEmpty) 'add',
      if (all) 'all',
    ];
    if (selectors.length > 1) {
      throw RetrievalEvalConfigException(
        'a strategy set must use exactly one of only / add / all '
        '(got ${selectors.join(", ")})',
        path: path,
      );
    }
    if (selectors.isEmpty) {
      throw RetrievalEvalConfigException(
        'a strategy set must use one of only / add / all',
        path: path,
      );
    }
    return StrategySetSpec(
      name: name,
      only: only,
      add: add,
      all: all,
      weights: _weightMap(map['weights'], '$path.weights'),
    );
  }

  // ── primitive coercions ─────────────────────────────────────────────

  static String _requireString(Object? value, String path) {
    if (value is String && value.isNotEmpty) return value;
    throw RetrievalEvalConfigException(
      'expected a non-empty string (got ${value.runtimeType})',
      path: path,
    );
  }

  static String? _optionalString(Object? value, String path) {
    if (value == null) return null;
    if (value is String) return value;
    throw RetrievalEvalConfigException(
      'expected a string (got ${value.runtimeType})',
      path: path,
    );
  }

  static int? _optionalInt(Object? value, String path) {
    if (value == null) return null;
    if (value is int) return value;
    throw RetrievalEvalConfigException(
      'expected an int (got ${value.runtimeType})',
      path: path,
    );
  }

  static bool? _optionalBool(Object? value, String path) {
    if (value == null) return null;
    if (value is bool) return value;
    throw RetrievalEvalConfigException(
      'expected a bool (got ${value.runtimeType})',
      path: path,
    );
  }

  static List<Object?> _requireList(Object? value, String path) {
    if (value is List<Object?>) return value;
    if (value is List) return value.cast<Object?>();
    throw RetrievalEvalConfigException(
      'expected a list (got ${value.runtimeType})',
      path: path,
    );
  }

  static Map<String, Object?> _requireMap(Object? value, String path) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return value.map((k, v) => MapEntry('$k', v));
    }
    throw RetrievalEvalConfigException(
      'expected a map (got ${value.runtimeType})',
      path: path,
    );
  }

  static List<String> _stringList(Object? value, String path) {
    if (value == null) return const <String>[];
    final list = _requireList(value, path);
    return <String>[
      for (var i = 0; i < list.length; i++)
        _requireString(list[i], '$path[$i]'),
    ];
  }

  static Map<String, double> _weightMap(Object? value, String path) {
    if (value == null) return const <String, double>{};
    final map = _requireMap(value, path);
    final out = <String, double>{};
    for (final entry in map.entries) {
      final v = entry.value;
      if (v is num) {
        out[entry.key] = v.toDouble();
      } else {
        throw RetrievalEvalConfigException(
          'weight must be a number (got ${v.runtimeType})',
          path: '$path.${entry.key}',
        );
      }
    }
    return out;
  }
}
