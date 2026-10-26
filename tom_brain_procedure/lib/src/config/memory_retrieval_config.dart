// MemoryRetrievalConfig — the typed `memory_retrieval/` config family
// (Extension H, step #31; `tom_brain_procedure_specification.md`
// § 23.4).
//
// § 23.4 defines a *family* of files, not a single document:
//
//   memory_retrieval/
//     defaults.yml          # the shared strategy catalogue + fusion /
//                           #   diversity / rerank / budget / profile /
//                           #   selection blocks
//     memory_mcp.yml        # NON-LLM surface overlay (LLM strategy ⇒ load error)
//     brain_mcp.yml         # any-strategy surface overlay
//     access.yml            # the in-process access prompt path overlay
//     call_types/<type>.yml # optional per-call-type overlays
//
// Resolution is a **deep merge `defaults ← surface ← call_type`** (later
// wins per strategy/field); a missing block/strategy/field is never an error
// — it falls through to `defaults.yml`, and an absent `defaults.yml` field to
// the documented constant. This class owns those constants ([_defaultsMap]),
// the merge ([resolveYaml]), and the typed projection.
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node leaks into a `MemoryRetrievalConfig`; mutation of
// the on-disk text goes through the AST-preserving `TomYamlConfigWriter`. The
// typed model is read-only — it never re-serialises a document.
//
// ── The conductor projection ([toConductorMap]) ─────────────────────
//
// The `retrieve_for_prompt_v1` conductor (§ 23.2) is a sandboxed d4rt script
// that cannot read files; it consults an injected `retrievalConfig` plain
// map. The fine-grained § 23.4 catalogue (~20 named strategies) is coarser at
// the conductor: the conductor owns two inline seeds (`vector.prompt`,
// `bm25.prompt_terms`) it builds directly, and four `recall_*` sub-procedures
// it dispatches as a unit. [toConductorMap] therefore projects the catalogue
// onto that surface: an inline-seed entry per inline strategy, and a
// per-sub-procedure gate that is on iff **any** of the catalogue strategies
// that sub-procedure realises is enabled. The strategy → sub-procedure
// grouping is documented on [_subProcedureStrategies]; catalogue strategies
// with no conductor home yet (e.g. `vector.keyphrases`) are carried for
// documentation and future wiring and do not affect any gate — so enabling
// one never removes a candidate (the § 23.4 "pure superset" property holds).

library;

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show YamlConfigReader, loadYamlAsMap;

import 'memory_retrieval_config_invalid.dart';

/// One strategy's settings in the § 23.4 catalogue.
///
/// A strategy is `enabled` or not; a scored strategy carries a fusion
/// [weight] and an optional per-seed cap [k]. An **LLM strategy** carries a
/// [role] (the substrate role that computes its seeds) — its presence is the
/// structural LLM marker [isLlm] that the memory MCP surface forbids (§ 23.7).
/// Any role-specific extras (`maxQuestions`, `samplesPerQuestion`, `depth`, …)
/// are preserved verbatim in [params] as a plain `Map<String, Object?>`.
final class StrategyConfig {
  /// Builds a strategy entry. [enabled] is the only required field; the rest
  /// default to "absent" (the catalogue's documented constant supplies them).
  const StrategyConfig({
    required this.enabled,
    this.weight,
    this.k,
    this.role,
    this.params = const <String, Object?>{},
  });

  /// Whether this strategy contributes seeds.
  final bool enabled;

  /// Fusion weight (RRF). `null` when the strategy is not a scored seed.
  final double? weight;

  /// Per-seed candidate cap. `null` to use the memory-side default.
  final int? k;

  /// The substrate role that computes this strategy's seeds, or `null` for a
  /// non-LLM strategy. Its presence is the LLM marker.
  final String? role;

  /// Role-specific extras, preserved verbatim. Always a plain map.
  final Map<String, Object?> params;

  /// Whether this is an LLM-bearing strategy (carries a [role]).
  bool get isLlm => role != null;

  /// A copy with [enabled] and/or [weight] overridden; every other field is
  /// preserved. Passing `weight` retunes the strategy's RRF fusion weight
  /// without touching its enablement, role, or params — the lever an eval
  /// harness pulls to model a "deliberately weakened" weight set (§ 23.8).
  StrategyConfig copyWith({bool? enabled, double? weight}) => StrategyConfig(
        enabled: enabled ?? this.enabled,
        weight: weight ?? this.weight,
        k: k,
        role: role,
        params: params,
      );

  @override
  bool operator ==(Object other) =>
      other is StrategyConfig &&
      other.enabled == enabled &&
      other.weight == weight &&
      other.k == k &&
      other.role == role &&
      _sameParams(other.params, params);

  @override
  int get hashCode => Object.hash(enabled, weight, k, role, params.length);

  static bool _sameParams(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
    }
    return true;
  }
}

/// The retrieval slice of the per-prompt budget (§ 23.4, § 5.4).
final class RetrievalBudget {
  const RetrievalBudget({
    this.maxLlmCalls = 12,
    this.maxRecallCalls = 64,
    this.wallClockMs = 20000,
    this.k = 24,
  });

  /// Cap on retrieval-time PAID substrate calls (free/local not debited).
  final int maxLlmCalls;

  /// Cap on the `memory.recall` fan-out.
  final int maxRecallCalls;

  /// Wall-clock allowance for the whole retrieval.
  final int wallClockMs;

  /// Final memories assembled into the answer prompt (the post-fusion cap).
  final int k;
}

/// Fusion settings (§ 23.3): RRF with smoothing constant [rrfK].
final class FusionSettings {
  const FusionSettings({this.method = 'rrf', this.rrfK = 60});

  /// Fusion method name (`rrf`).
  final String method;

  /// RRF smoothing constant.
  final int rrfK;
}

/// Diversity settings (§ 23.3): MMR with relevance/diversity trade-off
/// [lambda].
final class DiversitySettings {
  const DiversitySettings({this.method = 'mmr', this.lambda = 0.7});

  /// Diversity method name (`mmr`).
  final String method;

  /// MMR lambda — 1.0 favours relevance, 0.0 favours diversity.
  final double lambda;
}

/// Optional LLM re-rank settings (§ 23.3). The re-rank itself is a deferred
/// prototype extension; only its configuration is modelled here.
final class RerankSettings {
  const RerankSettings({
    this.enabled = false,
    this.role = 'retrieval_reranker',
    this.keepTop = 12,
  });

  /// Whether a re-rank pass runs after fusion.
  final bool enabled;

  /// The substrate role that performs the re-rank.
  final String role;

  /// How many of the fused top results are handed to the re-ranker.
  final int keepTop;
}

/// History-driven profile-selection settings (§ 23.6).
final class SelectionSettings {
  const SelectionSettings({
    this.enabled = false,
    this.role = 'profile_selector',
    this.defaultProfile = 'default',
    this.useHistory = true,
    this.recheckEveryNTurns = 5,
    this.inconclusiveThreshold = 0.5,
  });

  /// Whether the surface runs profile selection at all.
  final bool enabled;

  /// The substrate role that picks the profile.
  final String role;

  /// The profile used when selection is off or inconclusive.
  final String defaultProfile;

  /// Whether the selector is fed the full conversation history.
  final bool useHistory;

  /// How often an inconclusive selection is re-checked, in turns.
  final int recheckEveryNTurns;

  /// Confidence floor below which a pick is treated as inconclusive.
  final double inconclusiveThreshold;
}

/// The fully-resolved `memory_retrieval/` configuration for one surface.
final class MemoryRetrievalConfig {
  const MemoryRetrievalConfig({
    required this.profile,
    required this.budget,
    required this.fusion,
    required this.diversity,
    required this.rerank,
    required this.strategies,
    required this.selection,
  });

  /// The active memory profile (§ 23.5).
  final String profile;

  /// The retrieval budget slice.
  final RetrievalBudget budget;

  /// Fusion (RRF) settings.
  final FusionSettings fusion;

  /// Diversity (MMR) settings.
  final DiversitySettings diversity;

  /// Optional LLM re-rank settings.
  final RerankSettings rerank;

  /// The strategy catalogue: `family → name → StrategyConfig`.
  final Map<String, Map<String, StrategyConfig>> strategies;

  /// Profile-selection settings.
  final SelectionSettings selection;

  /// The documented-default configuration (§ 23.4 `defaults.yml`).
  factory MemoryRetrievalConfig.defaults() => _fromCompleteMap(_defaultsMap());

  /// Looks up one strategy by [family] and [name], or `null` when absent.
  StrategyConfig? strategy(String family, String name) =>
      strategies[family]?[name];

  /// Whether any **enabled** strategy is LLM-bearing (carries a `role:`), or
  /// the re-rank (which uses a role) is enabled. This is the structural test
  /// the non-LLM memory surface (§ 23.7) must fail closed on.
  bool get hasEnabledLlmStrategy {
    if (rerank.enabled) return true;
    for (final family in strategies.values) {
      for (final sc in family.values) {
        if (sc.enabled && sc.isLlm) return true;
      }
    }
    return false;
  }

  /// Asserts this config enables no LLM strategy — the constraint the memory
  /// MCP server (§ 23.7) is held to. Throws
  /// [MemoryRetrievalConfigInvalid.llmInMemory] (wire code
  /// `retrieval.config.llm_in_memory`) naming the first offender.
  void checkNonLlm() {
    if (rerank.enabled) {
      throw const MemoryRetrievalConfigInvalid.llmInMemory(
        're-rank uses an LLM role and cannot run on the memory surface',
        path: 'rerank',
      );
    }
    for (final family in strategies.entries) {
      for (final sc in family.value.entries) {
        if (sc.value.enabled && sc.value.isLlm) {
          throw MemoryRetrievalConfigInvalid.llmInMemory(
            'LLM strategy "${sc.value.role}" enabled on a non-LLM surface',
            path: 'strategies.${family.key}.${sc.key}',
          );
        }
      }
    }
  }

  /// A copy with every strategy disabled except those named `family.name` in
  /// [paths], which are enabled (their weight/k/role/params preserved).
  ///
  /// `withOnly(['vector.prompt'])` is the canonical "reproduce today's naive
  /// recall" reduction (§ 23.4): the migration is a pure superset of it.
  MemoryRetrievalConfig withOnly(List<String> paths) {
    final keep = paths.toSet();
    final next = <String, Map<String, StrategyConfig>>{};
    for (final family in strategies.entries) {
      final byName = <String, StrategyConfig>{};
      for (final sc in family.value.entries) {
        final on = keep.contains('${family.key}.${sc.key}');
        byName[sc.key] = sc.value.copyWith(enabled: on);
      }
      next[family.key] = byName;
    }
    return MemoryRetrievalConfig(
      profile: profile,
      budget: budget,
      fusion: fusion,
      diversity: diversity,
      rerank: rerank,
      strategies: next,
      selection: selection,
    );
  }

  /// A copy with the fusion `weight` of each strategy named `family.name` in
  /// [pathWeights] retuned to the given value; every other strategy and field
  /// is preserved (enablement included). The symmetric companion to
  /// [withOnly]: where `withOnly` decides *which* strategies contribute,
  /// `withWeights` decides *how much* a contributing strategy counts in RRF
  /// fusion. A path that does not name a known strategy is ignored.
  ///
  /// This is the mechanism the retrieval eval harness (§ 23.8) uses to model a
  /// "deliberately weakened" weight set — drop a high-signal strategy's weight
  /// toward zero and the relevant nodes it used to surface sink in the fused
  /// ranking, producing a measurable metric drop.
  MemoryRetrievalConfig withWeights(Map<String, double> pathWeights) {
    final next = <String, Map<String, StrategyConfig>>{};
    for (final family in strategies.entries) {
      final byName = <String, StrategyConfig>{};
      for (final sc in family.value.entries) {
        final weight = pathWeights['${family.key}.${sc.key}'];
        byName[sc.key] =
            weight == null ? sc.value : sc.value.copyWith(weight: weight);
      }
      next[family.key] = byName;
    }
    return MemoryRetrievalConfig(
      profile: profile,
      budget: budget,
      fusion: fusion,
      diversity: diversity,
      rerank: rerank,
      strategies: next,
      selection: selection,
    );
  }

  /// Projects the catalogue onto the conductor's coarser surface (see the
  /// library doc). Returns a fully-plain map the d4rt conductor reads:
  ///
  /// ```
  /// {
  ///   'seeds': {
  ///     'vector.prompt':     {'enabled': bool, 'weight': double, 'k': int},
  ///     'bm25.prompt_terms': {'enabled': bool, 'weight': double, 'k': int},
  ///   },
  ///   'subProcedures': {
  ///     'recall_hyde_v1': bool, 'recall_lexical_v1': bool,
  ///     'recall_symbolic_v1': bool, 'recall_semantic_v1': bool,
  ///   },
  ///   'fusion':    {'rrfK': int},
  ///   'diversity': {'lambda': double},
  ///   'budget':    {'k': int},
  /// }
  /// ```
  Map<String, Object?> toConductorMap() {
    final subs = <String, Object?>{};
    for (final entry in _subProcedureStrategies.entries) {
      subs[entry.key] = entry.value.any((path) {
        final parts = path.split('.');
        return strategy(parts[0], parts[1])?.enabled ?? false;
      });
    }
    return <String, Object?>{
      'seeds': <String, Object?>{
        'vector.prompt': _inlineSeed('vector', 'prompt'),
        'bm25.prompt_terms': _inlineSeed('bm25', 'prompt_terms'),
      },
      'subProcedures': subs,
      'fusion': <String, Object?>{'rrfK': fusion.rrfK},
      'diversity': <String, Object?>{'lambda': diversity.lambda},
      'budget': <String, Object?>{'k': budget.k},
    };
  }

  Map<String, Object?> _inlineSeed(String family, String name) {
    final sc = strategy(family, name);
    return <String, Object?>{
      'enabled': sc?.enabled ?? false,
      'weight': sc?.weight ?? 1.0,
      if (sc?.k != null) 'k': sc!.k,
    };
  }

  /// Parses one `memory_retrieval/` document layered over the documented
  /// defaults — a missing block/strategy/field falls through (§ 23.4).
  static MemoryRetrievalConfig fromYamlString(String yamlText) {
    final doc = loadYamlAsMap(
      yamlText,
      rootPath: 'memory_retrieval',
      errorFactory: MemoryRetrievalConfigInvalid.new,
    );
    return fromYamlMap(doc);
  }

  /// Layers an already-parsed plain [doc] over the documented defaults.
  static MemoryRetrievalConfig fromYamlMap(Map<Object?, Object?> doc) =>
      _fromCompleteMap(_deepMerge(_defaultsMap(), doc));

  /// Resolves a surface by deep-merging [layers] over the documented defaults
  /// (`defaults ← layers[0] ← layers[1] …`, later wins per field).
  static MemoryRetrievalConfig resolveYaml(List<String> layers) {
    var merged = _defaultsMap();
    for (final layer in layers) {
      final doc = loadYamlAsMap(
        layer,
        rootPath: 'memory_retrieval',
        errorFactory: MemoryRetrievalConfigInvalid.new,
      );
      merged = _deepMerge(merged, doc);
    }
    return _fromCompleteMap(merged);
  }

  // ── Building from a complete (defaults-layered) plain map ──────────

  static const YamlConfigReader _reader = YamlConfigReader(
    env: <String, String>{},
    errorFactory: MemoryRetrievalConfigInvalid.new,
  );

  static MemoryRetrievalConfig _fromCompleteMap(Map<Object?, Object?> doc) {
    final profile =
        _reader.optionalString(doc, 'profile', 'profile') ?? 'default';

    final budgetMap = _reader.optionalMap(doc, 'budget');
    final budget = RetrievalBudget(
      maxLlmCalls: _intOr(budgetMap, 'maxLlmCalls', 'budget.maxLlmCalls', 12),
      maxRecallCalls:
          _intOr(budgetMap, 'maxRecallCalls', 'budget.maxRecallCalls', 64),
      wallClockMs: _intOr(budgetMap, 'wallClockMs', 'budget.wallClockMs', 20000),
      k: _intOr(budgetMap, 'k', 'budget.k', 24),
    );

    final fusionMap = _reader.optionalMap(doc, 'fusion');
    final fusion = FusionSettings(
      method: _strOr(fusionMap, 'method', 'fusion.method', 'rrf'),
      rrfK: _intOr(fusionMap, 'rrfK', 'fusion.rrfK', 60),
    );

    final diversityMap = _reader.optionalMap(doc, 'diversity');
    final diversity = DiversitySettings(
      method: _strOr(diversityMap, 'method', 'diversity.method', 'mmr'),
      lambda: _doubleOr(diversityMap, 'lambda', 'diversity.lambda', 0.7),
    );

    final rerankMap = _reader.optionalMap(doc, 'rerank');
    final rerank = RerankSettings(
      enabled: _boolOr(rerankMap, 'enabled', 'rerank.enabled', false),
      role: _strOr(rerankMap, 'role', 'rerank.role', 'retrieval_reranker'),
      keepTop: _intOr(rerankMap, 'keepTop', 'rerank.keepTop', 12),
    );

    final selectionMap = _reader.optionalMap(doc, 'selection');
    final selection = SelectionSettings(
      enabled: _boolOr(selectionMap, 'enabled', 'selection.enabled', false),
      role: _strOr(selectionMap, 'role', 'selection.role', 'profile_selector'),
      defaultProfile:
          _strOr(selectionMap, 'default', 'selection.default', 'default'),
      useHistory:
          _boolOr(selectionMap, 'useHistory', 'selection.useHistory', true),
      recheckEveryNTurns: _intOr(
          selectionMap, 'recheckEveryNTurns', 'selection.recheckEveryNTurns', 5),
      inconclusiveThreshold: _doubleOr(selectionMap, 'inconclusiveThreshold',
          'selection.inconclusiveThreshold', 0.5),
    );

    final strategies = _parseStrategies(_reader.optionalMap(doc, 'strategies'));

    return MemoryRetrievalConfig(
      profile: profile,
      budget: budget,
      fusion: fusion,
      diversity: diversity,
      rerank: rerank,
      strategies: strategies,
      selection: selection,
    );
  }

  static const Set<String> _strategyReservedKeys = <String>{
    'enabled',
    'weight',
    'k',
    'role',
  };

  static Map<String, Map<String, StrategyConfig>> _parseStrategies(
    Map<Object?, Object?>? block,
  ) {
    final out = <String, Map<String, StrategyConfig>>{};
    if (block == null) return out;
    for (final family in block.entries) {
      final familyName = _keyString(family.key, 'strategies');
      final familyMap = family.value;
      if (familyMap is! Map<Object?, Object?>) {
        throw MemoryRetrievalConfigInvalid(
          'strategy family must be a map (got ${familyMap.runtimeType})',
          path: 'strategies.$familyName',
        );
      }
      final byName = <String, StrategyConfig>{};
      for (final strat in familyMap.entries) {
        final stratName =
            _keyString(strat.key, 'strategies.$familyName');
        final path = 'strategies.$familyName.$stratName';
        final stratMap = strat.value;
        if (stratMap is! Map<Object?, Object?>) {
          throw MemoryRetrievalConfigInvalid(
            'strategy entry must be a map (got ${stratMap.runtimeType})',
            path: path,
          );
        }
        final params = <String, Object?>{};
        for (final field in stratMap.entries) {
          final fieldName = _keyString(field.key, path);
          if (_strategyReservedKeys.contains(fieldName)) continue;
          params[fieldName] = field.value;
        }
        byName[stratName] = StrategyConfig(
          enabled:
              _reader.optionalBool(stratMap, 'enabled', '$path.enabled') ??
                  false,
          weight: _reader.optionalDouble(stratMap, 'weight', '$path.weight'),
          k: _reader.optionalInt(stratMap, 'k', '$path.k'),
          role: _reader.optionalString(stratMap, 'role', '$path.role'),
          params: params,
        );
      }
      out[familyName] = byName;
    }
    return out;
  }

  static String _keyString(Object? key, String path) {
    if (key is String) return key;
    throw MemoryRetrievalConfigInvalid(
      'key must be a string (got ${key.runtimeType})',
      path: path,
    );
  }

  static int _intOr(
      Map<Object?, Object?>? m, String key, String path, int fallback) {
    if (m == null) return fallback;
    return _reader.optionalInt(m, key, path) ?? fallback;
  }

  static double _doubleOr(
      Map<Object?, Object?>? m, String key, String path, double fallback) {
    if (m == null) return fallback;
    return _reader.optionalDouble(m, key, path) ?? fallback;
  }

  static bool _boolOr(
      Map<Object?, Object?>? m, String key, String path, bool fallback) {
    if (m == null) return fallback;
    return _reader.optionalBool(m, key, path) ?? fallback;
  }

  static String _strOr(
      Map<Object?, Object?>? m, String key, String path, String fallback) {
    if (m == null) return fallback;
    return _reader.optionalString(m, key, path) ?? fallback;
  }

  // ── Deep merge ────────────────────────────────────────────────────

  /// Deep-merges [overlay] onto [base]: a value present in both that is a map
  /// on both sides is merged recursively; otherwise [overlay] wins. Returns a
  /// fresh plain map — neither argument is mutated.
  static Map<Object?, Object?> _deepMerge(
    Map<Object?, Object?> base,
    Map<Object?, Object?> overlay,
  ) {
    final out = <Object?, Object?>{...base};
    for (final entry in overlay.entries) {
      final existing = out[entry.key];
      final incoming = entry.value;
      if (existing is Map<Object?, Object?> &&
          incoming is Map<Object?, Object?>) {
        out[entry.key] = _deepMerge(existing, incoming);
      } else {
        out[entry.key] = incoming;
      }
    }
    return out;
  }

  // ── Sub-procedure grouping (conductor projection) ─────────────────

  /// Which catalogue strategies each `recall_*` sub-procedure realises. A
  /// sub-procedure is dispatched iff **any** of its strategies is enabled.
  ///
  ///   * `recall_hyde_v1`     — the HyDE legs (questions → hypothetical
  ///                            answers, embedded as vector seeds).
  ///   * `recall_lexical_v1`  — the LLM lexical legs (query-term rewrite,
  ///                            synonym expansion).
  ///   * `recall_semantic_v1` — the concept-classification legs (the classify
  ///                            cheap path, the `category_selector` escalation,
  ///                            and the concept-seeded graph walk).
  ///   * `recall_symbolic_v1` — the pure non-LLM symbolic filters
  ///                            (scope / attribute / time window).
  ///
  /// Catalogue strategies not listed here (e.g. `vector.keyphrases`,
  /// `graphWalk.edge_type_default`) have no conductor home in the prototype;
  /// they are documented in `defaults.yml` for future wiring and do not gate
  /// any sub-procedure.
  static const Map<String, List<String>> _subProcedureStrategies =
      <String, List<String>>{
    'recall_hyde_v1': <String>[
      'vector.questions',
      'vector.hypothetical_answers',
    ],
    'recall_lexical_v1': <String>[
      'bm25.llm_query_terms',
      'bm25.synonym_expansion',
    ],
    'recall_semantic_v1': <String>[
      'symbolic.type_filter_by_classify',
      'symbolic.type_filter_by_llm',
      'graphWalk.seed_from_concepts',
      'graphWalk.seed_from_llm_picked',
    ],
    'recall_symbolic_v1': <String>[
      'symbolic.scope_filter',
      'symbolic.attr_equality',
      'symbolic.time_window',
    ],
  };

  // ── The documented-default catalogue (§ 23.4 defaults.yml) ─────────

  static Map<Object?, Object?> _defaultsMap() => <Object?, Object?>{
        'profile': 'default',
        'budget': <Object?, Object?>{
          'maxLlmCalls': 12,
          'maxRecallCalls': 64,
          'wallClockMs': 20000,
          'k': 24,
        },
        'fusion': <Object?, Object?>{'method': 'rrf', 'rrfK': 60},
        'diversity': <Object?, Object?>{'method': 'mmr', 'lambda': 0.7},
        'rerank': <Object?, Object?>{
          'enabled': false,
          'role': 'retrieval_reranker',
          'keepTop': 12,
        },
        'strategies': <Object?, Object?>{
          'vector': <Object?, Object?>{
            'prompt': <Object?, Object?>{
              'enabled': true,
              'weight': 1.0,
              'k': 12,
            },
            'questions': <Object?, Object?>{
              'enabled': true,
              'weight': 0.8,
              'k': 8,
              'role': 'recall_planner',
              'maxQuestions': 3,
            },
            'hypothetical_answers': <Object?, Object?>{
              'enabled': true,
              'weight': 1.2,
              'k': 8,
              'role': 'hypothesis_writer',
              'samplesPerQuestion': 1,
            },
            'keyphrases': <Object?, Object?>{
              'enabled': false,
              'weight': 0.6,
              'k': 6,
            },
            'recent_context': <Object?, Object?>{
              'enabled': true,
              'weight': 0.5,
              'k': 6,
              'turns': 4,
            },
            'prior_conclusions': <Object?, Object?>{
              'enabled': true,
              'weight': 0.5,
              'k': 6,
              'count': 5,
            },
          },
          'bm25': <Object?, Object?>{
            'prompt_terms': <Object?, Object?>{
              'enabled': true,
              'weight': 0.8,
              'k': 12,
            },
            'keyphrases': <Object?, Object?>{
              'enabled': true,
              'weight': 0.7,
              'k': 8,
            },
            'llm_query_terms': <Object?, Object?>{
              'enabled': false,
              'weight': 0.9,
              'k': 8,
              'role': 'query_term_writer',
            },
            'entity_terms': <Object?, Object?>{
              'enabled': false,
              'weight': 0.6,
              'k': 6,
            },
            'synonym_expansion': <Object?, Object?>{
              'enabled': false,
              'weight': 0.5,
              'k': 6,
              'role': 'query_term_writer',
            },
          },
          'symbolic': <Object?, Object?>{
            'type_filter_by_classify': <Object?, Object?>{
              'enabled': true,
              'weight': 0.4,
              'confidence': 0.6,
            },
            'type_filter_by_llm': <Object?, Object?>{
              'enabled': false,
              'weight': 0.5,
              'role': 'category_selector',
            },
            'time_window': <Object?, Object?>{
              'enabled': false,
              'weight': 0.3,
              'windowDays': 30,
            },
            'scope_filter': <Object?, Object?>{
              'enabled': true,
              'weight': 0.0,
            },
            'attr_equality': <Object?, Object?>{
              'enabled': false,
              'weight': 0.3,
            },
          },
          'graphWalk': <Object?, Object?>{
            'seed_from_vector_hits': <Object?, Object?>{
              'enabled': true,
              'weight': 0.7,
              'seeds': 6,
              'depth': 2,
            },
            'seed_from_concepts': <Object?, Object?>{
              'enabled': true,
              'weight': 0.8,
              'seeds': 4,
              'depth': 2,
              'confidence': 0.6,
            },
            'seed_from_llm_picked': <Object?, Object?>{
              'enabled': false,
              'weight': 0.9,
              'role': 'category_selector',
            },
            'edge_type_selection_by_llm': <Object?, Object?>{
              'enabled': false,
              'role': 'category_selector',
            },
            'edge_type_default': <Object?, Object?>{
              'enabled': true,
              'edges': <Object?>['supports', 'refines', 'contradicts', 'about'],
              'depth': 2,
            },
          },
        },
        'selection': <Object?, Object?>{
          'enabled': false,
          'role': 'profile_selector',
          'default': 'default',
          'useHistory': true,
          'recheckEveryNTurns': 5,
          'inconclusiveThreshold': 0.5,
        },
      };
}
