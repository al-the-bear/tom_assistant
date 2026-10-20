// H.31 — the `memory_retrieval/` config family + the conductor wiring
// (plan step #31; spec § 23.4).
//
// Step #31 adds the typed `MemoryRetrievalConfig` (the § 23.4 strategy
// catalogue: per-strategy enabled/weight/k/role/params, the
// fusion/diversity/rerank/budget/profile/selection blocks) loaded through
// the canonical plain-map loader (no `YamlMap` leak) and mutated via the
// AST-preserving writer, plus the `retrieve_for_prompt_v1` conductor
// consulting an injected `retrievalConfig` so the enabled strategies drive
// which seeds and sub-procedures run, and the fusion/diversity/budget knobs
// flow into `recallMulti`.
//
// This suite pins the four Test-clause obligations of plan step #31:
//
//   1. `only: [vector.prompt]` reproduces today's naive recall byte-for-byte
//      — exactly one vector seed over the prompt, no sub-procedures.
//   2. enabling more strategies only adds candidates (a pure superset).
//   3. a missing block defaults without error.
//   4. weights (and rrfK / lambda / final-k) flow into the fused
//      `MultiRecallQuery`.
//
// The model half is black-box over the public config surface; the conductor
// half loads the shipped `scripts/system/` artifacts through the real
// store+resolver (mirroring h30) and injects a `retrievalConfig` argument.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        MultiRecallQuery,
        NodeId,
        RecallMode,
        StackEntryId,
        TrailId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show YamlConfigWriter;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  // ── Model surface ─────────────────────────────────────────────────

  group('H.31-model defaults mirror § 23.4', () {
    test('defaults() carries the catalogue constants', () {
      final cfg = MemoryRetrievalConfig.defaults();
      expect(cfg.profile, 'default');
      expect(cfg.budget.k, 24);
      expect(cfg.budget.maxLlmCalls, 12);
      expect(cfg.budget.maxRecallCalls, 64);
      expect(cfg.budget.wallClockMs, 20000);
      expect(cfg.fusion.rrfK, 60);
      expect(cfg.diversity.lambda, 0.7);
      expect(cfg.rerank.enabled, isFalse);
      expect(cfg.rerank.role, 'retrieval_reranker');
      expect(cfg.rerank.keepTop, 12);

      final prompt = cfg.strategy('vector', 'prompt')!;
      expect(prompt.enabled, isTrue);
      expect(prompt.weight, 1.0);
      expect(prompt.k, 12);
      expect(prompt.isLlm, isFalse);

      final hyde = cfg.strategy('vector', 'hypothetical_answers')!;
      expect(hyde.enabled, isTrue);
      expect(hyde.role, 'hypothesis_writer');
      expect(hyde.isLlm, isTrue);

      expect(cfg.selection.enabled, isFalse);
      expect(cfg.selection.recheckEveryNTurns, 5);
    });
  });

  group('H.31-model the plain-map loader never leaks a YamlMap', () {
    test('every map/list in the parsed config is a plain typed collection', () {
      final cfg = MemoryRetrievalConfig.fromYamlString('''
profile: focused
strategies:
  vector:
    prompt: { enabled: true, weight: 1.0, k: 12 }
    hypothetical_answers: { enabled: true, role: hypothesis_writer, samplesPerQuestion: 2 }
''');
      // `params` is declared `Map<String, Object?>` — a leaked YamlMap is
      // `Map<dynamic, dynamic>` and would fail this typed `isA`.
      final hyde = cfg.strategy('vector', 'hypothetical_answers')!;
      expect(hyde.params, isA<Map<String, Object?>>());
      expect(hyde.params['samplesPerQuestion'], 2);
      // The conductor view is fully plain, too.
      _assertPlain(cfg.toConductorMap());
    });
  });

  group('H.31-model a missing block defaults without error (Test #3)', () {
    test('a near-empty document falls through to the documented defaults', () {
      final cfg = MemoryRetrievalConfig.fromYamlString('profile: focused\n');
      expect(cfg.profile, 'focused');
      // Everything not named falls to defaults — no throw.
      expect(cfg.budget.k, 24);
      expect(cfg.fusion.rrfK, 60);
      expect(cfg.diversity.lambda, 0.7);
      expect(cfg.strategy('vector', 'prompt')!.enabled, isTrue);
    });
  });

  group(
    'H.31-model resolve is a deep merge (defaults <- surface <- callType)',
    () {
      test(
        'a thin overlay narrows only the named field; the rest survives',
        () {
          const surface = '''
strategies:
  vector:
    hypothetical_answers: { enabled: false }
''';
          final cfg = MemoryRetrievalConfig.resolveYaml(<String>[surface]);
          // The overlay disabled one strategy …
          expect(
            cfg.strategy('vector', 'hypothetical_answers')!.enabled,
            isFalse,
          );
          // … and everything else fell through to defaults.
          expect(cfg.strategy('vector', 'prompt')!.enabled, isTrue);
          expect(
            cfg.strategy('vector', 'hypothetical_answers')!.role,
            'hypothesis_writer',
          );
        },
      );

      test('a later layer wins over an earlier one per field', () {
        const surface = 'fusion: { rrfK: 70 }\n';
        const callType = 'fusion: { rrfK: 90 }\n';
        final cfg = MemoryRetrievalConfig.resolveYaml(<String>[
          surface,
          callType,
        ]);
        expect(cfg.fusion.rrfK, 90);
      });
    },
  );

  group('H.31-model withOnly disables all but the named strategies', () {
    test('only vector.prompt stays enabled; weight/k are preserved', () {
      final cfg = MemoryRetrievalConfig.defaults().withOnly(['vector.prompt']);
      expect(cfg.strategy('vector', 'prompt')!.enabled, isTrue);
      expect(cfg.strategy('vector', 'prompt')!.weight, 1.0);
      expect(cfg.strategy('vector', 'prompt')!.k, 12);
      expect(cfg.strategy('vector', 'hypothetical_answers')!.enabled, isFalse);
      expect(cfg.strategy('bm25', 'prompt_terms')!.enabled, isFalse);
      expect(cfg.strategy('symbolic', 'scope_filter')!.enabled, isFalse);
    });
  });

  group('H.31-model withWeights retunes named strategy weights only', () {
    test(
      'a named strategy is retuned; enablement and others are untouched',
      () {
        final base = MemoryRetrievalConfig.defaults();
        final cfg = base.withWeights(<String, double>{
          'vector.prompt': 0.01,
          'graphWalk.seed_from_concepts': 0.0,
        });

        // The named weights moved …
        expect(cfg.strategy('vector', 'prompt')!.weight, 0.01);
        expect(cfg.strategy('graphWalk', 'seed_from_concepts')!.weight, 0.0);
        // … enablement is preserved (withWeights never flips a strategy) …
        expect(cfg.strategy('vector', 'prompt')!.enabled, isTrue);
        expect(
          cfg.strategy('graphWalk', 'seed_from_concepts')!.enabled,
          isTrue,
        );
        // … and an unnamed strategy keeps its default weight.
        expect(
          cfg.strategy('vector', 'hypothetical_answers')!.weight,
          base.strategy('vector', 'hypothetical_answers')!.weight,
        );
      },
    );

    test(
      'an unknown path is ignored; the retuned weight reaches the conductor',
      () {
        final cfg = MemoryRetrievalConfig.defaults().withWeights(
          <String, double>{'vector.prompt': 0.25, 'no.such_strategy': 9.0},
        );
        final seeds = cfg.toConductorMap()['seeds'] as Map<String, Object?>;
        final vp = seeds['vector.prompt'] as Map<String, Object?>;
        expect(vp['weight'], 0.25);
      },
    );

    test('StrategyConfig.copyWith can override weight in isolation', () {
      const sc = StrategyConfig(enabled: true, weight: 1.0, k: 8);
      final tuned = sc.copyWith(weight: 0.5);
      expect(tuned.weight, 0.5);
      expect(tuned.enabled, isTrue);
      expect(tuned.k, 8);
    });
  });

  group('H.31-model the non-LLM constraint is enforceable', () {
    test('hasEnabledLlmStrategy is true when an LLM strategy is on', () {
      expect(MemoryRetrievalConfig.defaults().hasEnabledLlmStrategy, isTrue);
    });

    test(
      'a non-LLM-only config passes checkNonLlm; an LLM one is rejected',
      () {
        final nonLlm = MemoryRetrievalConfig.defaults().withOnly([
          'vector.prompt',
          'bm25.prompt_terms',
          'symbolic.scope_filter',
        ]);
        expect(nonLlm.hasEnabledLlmStrategy, isFalse);
        expect(nonLlm.checkNonLlm, returnsNormally);

        expect(
          MemoryRetrievalConfig.defaults().checkNonLlm,
          throwsA(
            isA<MemoryRetrievalConfigInvalid>().having(
              (e) => e.code,
              'code',
              'retrieval.config.llm_in_memory',
            ),
          ),
        );
      },
    );
  });

  group(
    'H.31-model the AST-preserving writer round-trips through the loader',
    () {
      test('a surgical set keeps comments and re-parses to the new value', () {
        const src = '''
# memory_retrieval defaults
fusion: { rrfK: 60 }   # RRF smoothing constant
diversity: { lambda: 0.7 }
''';
        final writer = YamlConfigWriter(src);
        writer.set(['fusion', 'rrfK'], 80);

        // Comment preserved (AST surgery, not a re-serialize) …
        expect(writer.source, contains('# RRF smoothing constant'));
        // … and the new value re-parses through the plain-map loader.
        final reparsed = MemoryRetrievalConfig.fromYamlString(writer.source);
        expect(reparsed.fusion.rrfK, 80);
        expect(reparsed.diversity.lambda, 0.7);
      });
    },
  );

  group(
    'H.31-model toConductorMap projects the catalogue for the conductor',
    () {
      test('defaults() maps inline seeds + sub-procedure gates', () {
        final m = MemoryRetrievalConfig.defaults().toConductorMap();
        final seeds = m['seeds'] as Map<String, Object?>;
        final vp = seeds['vector.prompt'] as Map<String, Object?>;
        expect(vp['enabled'], isTrue);
        expect(vp['weight'], 1.0);
        expect(vp['k'], 12);

        final subs = m['subProcedures'] as Map<String, Object?>;
        // HyDE strategies on in defaults ⇒ recall_hyde_v1 dispatched.
        expect(subs['recall_hyde_v1'], isTrue);
        // Both lexical LLM strategies off in defaults ⇒ recall_lexical_v1 off.
        expect(subs['recall_lexical_v1'], isFalse);
        // scope_filter / type_filter_by_classify on ⇒ symbolic + semantic on.
        expect(subs['recall_symbolic_v1'], isTrue);
        expect(subs['recall_semantic_v1'], isTrue);

        expect((m['fusion'] as Map)['rrfK'], 60);
        expect((m['diversity'] as Map)['lambda'], 0.7);
        expect((m['budget'] as Map)['k'], 24);
      });
    },
  );

  // ── The shipped example `memory_retrieval/` family ────────────────

  group(
    'H.31-example the shipped memory_retrieval/ family loads & resolves',
    () {
      String read(String name) =>
          File('memory_retrieval/$name').readAsStringSync();

      test(
        'defaults.yml documents every catalogue strategy (Verify clause)',
        () {
          final cfg = MemoryRetrievalConfig.fromYamlString(
            read('defaults.yml'),
          );
          // The example must carry every strategy in the § 23.4 catalogue — the
          // same set the documented `defaults()` constant carries.
          final expected = MemoryRetrievalConfig.defaults();
          for (final family in expected.strategies.entries) {
            for (final name in family.value.keys) {
              expect(
                cfg.strategy(family.key, name),
                isNotNull,
                reason: 'defaults.yml is missing ${family.key}.$name',
              );
            }
          }
          // And the documented constants flow through verbatim.
          expect(cfg.strategy('vector', 'prompt')!.weight, 1.0);
          expect(cfg.fusion.rrfK, 60);
          expect(cfg.budget.k, 24);
        },
      );

      test('memory_mcp.yml resolves to a non-LLM-only config (§ 23.7)', () {
        final cfg = MemoryRetrievalConfig.resolveYaml(<String>[
          read('defaults.yml'),
          read('memory_mcp.yml'),
        ]);
        expect(cfg.hasEnabledLlmStrategy, isFalse);
        expect(cfg.checkNonLlm, returnsNormally);
      });

      test('brain_mcp.yml resolves to an LLM-bearing config', () {
        final cfg = MemoryRetrievalConfig.resolveYaml(<String>[
          read('defaults.yml'),
          read('brain_mcp.yml'),
        ]);
        expect(cfg.hasEnabledLlmStrategy, isTrue);
        expect(cfg.rerank.enabled, isTrue);
        expect(cfg.strategy('bm25', 'llm_query_terms')!.enabled, isTrue);
      });

      test('access.yml resolves and turns profile selection on', () {
        final cfg = MemoryRetrievalConfig.resolveYaml(<String>[
          read('defaults.yml'),
          read('access.yml'),
        ]);
        expect(cfg.selection.enabled, isTrue);
        expect(cfg.strategy('vector', 'hypothetical_answers')!.enabled, isTrue);
      });

      test('the optional call_types overlay applies last', () {
        final cfg = MemoryRetrievalConfig.resolveYaml(<String>[
          read('defaults.yml'),
          read('brain_mcp.yml'),
          read('call_types/retrieval_reranker.yml'),
        ]);
        // The call-type layer stripped the expensive seeds …
        expect(cfg.strategy('vector', 'questions')!.enabled, isFalse);
        expect(
          cfg.strategy('graphWalk', 'seed_from_concepts')!.enabled,
          isFalse,
        );
        // … and tightened the re-rank.
        expect(cfg.rerank.enabled, isTrue);
        expect(cfg.rerank.keepTop, 8);
      });
    },
  );

  // ── Conductor wiring ──────────────────────────────────────────────

  group('H.31-conductor', () {
    late _RetrievalMemory memory;
    late _RoleSubstrate substrate;
    late MemoryBridge memoryBridge;
    late SubstrateBridge substrateBridge;

    setUp(() {
      memory = _RetrievalMemory();
      substrate = _RoleSubstrate();
      memoryBridge = MemoryBridge(memory);
      substrateBridge = SubstrateBridge(substrate);
    });

    ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
        ProcedureEngine(
          resolver: ProcedureResolver(procedures),
          memory: memory,
          memoryBridge: memoryBridge,
          substrateBridge: substrateBridge,
          now: () => DateTime.utc(2026, 6, 7, 12, 0, 0),
        );

    Future<ProcedureEngine> retrievalEngine() async {
      final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
      final resolver = await ProcedureResolver.fromStore(store);
      return engineFor(<LoadedProcedure>[
        resolver.resolve('retrieve_for_prompt_v1'),
        resolver.resolve('recall_hyde_v1'),
        resolver.resolve('recall_lexical_v1'),
        resolver.resolve('recall_semantic_v1'),
        resolver.resolve('recall_symbolic_v1'),
      ]);
    }

    Future<ProcedureOutcome> retrieve(
      String text, {
      Object? retrievalConfig,
    }) async {
      final engine = await retrievalEngine();
      final args = <String, Object?>{'text': text};
      if (retrievalConfig != null) args['retrievalConfig'] = retrievalConfig;
      return engine
          .invoke(
            ProcedureInvocation(
              procedureId: 'retrieve_for_prompt_v1',
              arguments: args,
            ),
          )
          .outcome;
    }

    test(
      'Test #1 — only:[vector.prompt] reproduces naive recall byte-for-byte',
      () async {
        final cfg = MemoryRetrievalConfig.defaults().withOnly([
          'vector.prompt',
        ]);

        final outcome = await retrieve(
          'how do I automate backups?',
          retrievalConfig: cfg.toConductorMap(),
        );

        expect(outcome.status, TrailOutcomeStatus.accepted);
        final query = memory.lastMultiRecallQuery!;
        // Exactly one seed — a vector seed over the prompt, weight 1.0, k 12.
        expect(query.seeds, hasLength(1));
        expect(query.seeds.single.mode, RecallMode.vector);
        expect(query.seeds.single.text, 'how do I automate backups?');
        expect(query.seeds.single.weight, 1.0);
        expect(query.seeds.single.k, 12);
        // No sub-procedure ran — only the conductor itself. The recorder
        // writes two `ProcedureRun` nodes per run (§ 8): a `status: running`
        // marker at start and the authoritative final node at completion. So
        // the conductor alone persists exactly 2, and zero sub-procedures means
        // no further pair — the proof that `only:[vector.prompt]` skipped the
        // whole fan-out.
        expect(memory.procedureRunPersists, 2);
        // Fusion / diversity / final-k are the documented defaults.
        expect(query.fusion.rrfK, 60);
        expect(query.diversity.lambda, 0.7);
        expect(query.k, 24);
      },
    );

    test('Test #2 — enabling more strategies only adds candidates', () async {
      final base = MemoryRetrievalConfig.defaults().withOnly(['vector.prompt']);
      await retrieve(
        'how do I automate backups?',
        retrievalConfig: base.toConductorMap(),
      );
      final baseSeedCount = memory.lastMultiRecallQuery!.seeds.length;

      // Add a second inline strategy: strictly more seeds, never fewer.
      final more = MemoryRetrievalConfig.defaults().withOnly([
        'vector.prompt',
        'bm25.prompt_terms',
      ]);
      await retrieve(
        'how do I automate backups?',
        retrievalConfig: more.toConductorMap(),
      );
      final moreSeedCount = memory.lastMultiRecallQuery!.seeds.length;

      expect(moreSeedCount, greaterThan(baseSeedCount));
      // The original vector seed is still present (pure superset).
      expect(
        memory.lastMultiRecallQuery!.seeds.any(
          (s) => s.mode == RecallMode.vector,
        ),
        isTrue,
      );
    });

    test('Test #3 — a missing config block defaults without error', () async {
      // A sparse conductor map with no budget/fusion/diversity blocks.
      final sparse = <String, Object?>{
        'seeds': <String, Object?>{
          'vector.prompt': <String, Object?>{
            'enabled': true,
            'weight': 1.0,
            'k': 12,
          },
        },
      };

      final outcome = await retrieve(
        'how do I automate backups?',
        retrievalConfig: sparse,
      );

      expect(outcome.status, TrailOutcomeStatus.accepted);
      final query = memory.lastMultiRecallQuery!;
      expect(query.seeds, hasLength(1));
      // Missing fusion/diversity/budget ⇒ the documented defaults.
      expect(query.fusion.rrfK, 60);
      expect(query.diversity.lambda, 0.7);
      expect(query.k, 24);
    });

    test(
      'Test #4 — weights, rrfK, lambda and final-k flow into the query',
      () async {
        final cfg = MemoryRetrievalConfig.fromYamlString('''
fusion: { rrfK: 99 }
diversity: { lambda: 0.25 }
budget: { k: 7 }
strategies:
  vector:
    prompt: { enabled: true, weight: 2.5, k: 5 }
''').withOnly(['vector.prompt']);

        await retrieve(
          'how do I automate backups?',
          retrievalConfig: cfg.toConductorMap(),
        );

        final query = memory.lastMultiRecallQuery!;
        expect(query.seeds.single.weight, 2.5);
        expect(query.seeds.single.k, 5);
        expect(query.fusion.rrfK, 99);
        expect(query.diversity.lambda, 0.25);
        expect(query.k, 7);
      },
    );

    test(
      'no retrievalConfig ⇒ legacy full fan-out (h30 parity preserved)',
      () async {
        final outcome = await retrieve('how do I automate backups?');

        expect(outcome.status, TrailOutcomeStatus.accepted);
        expect(memory.lastMultiRecallQuery!.seeds, isNotEmpty);
        // Conductor + four sub-procedures each persist a run (PE-4).
        expect(memory.procedureRunPersists, greaterThanOrEqualTo(5));
      },
    );
  });
}

/// Recursively asserts [value] holds only plain Dart collections — never a
/// `package:yaml` node. A leaked `YamlMap`/`YamlList` is typed
/// `Map<dynamic, dynamic>` / `List<dynamic>`, so the typed `isA` below
/// fails on it.
void _assertPlain(Object? value) {
  if (value is Map) {
    expect(
      value,
      isA<Map<String, Object?>>(),
      reason: 'a non-plain map leaked into the conductor view',
    );
    for (final v in value.values) {
      _assertPlain(v);
    }
  } else if (value is List) {
    expect(
      value,
      isA<List<Object?>>(),
      reason: 'a non-plain list leaked into the conductor view',
    );
    for (final v in value) {
      _assertPlain(v);
    }
  }
}

// ── Test doubles (mirroring h30_retrieval_conductor_test.dart) ───────

class _RetrievalMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  MultiRecallQuery? lastMultiRecallQuery;
  int procedureRunPersists = 0;

  ClassificationResult classifyResult = const ClassificationResult.unknown();

  RecallResult _cannedResult() => RecallResult(
    nodes: <Node>[
      Node(
        id: NodeId.fromString('n_00000000000000000000000042'),
        typeName: 'Conclusion',
        values: const <String, Object?>{'text': 'rsync nightly to NAS'},
        createdAt: DateTime.utc(2026, 6, 1),
      ),
    ],
    report: const RecallReport(
      candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 3},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 5,
    ),
    provenance: <RecallProvenanceEntry>[
      RecallProvenanceEntry(
        nodeId: NodeId.fromString('n_00000000000000000000000042'),
        seedIndexes: const <int>[0],
        fusedScore: 0.5,
      ),
    ],
  );

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    lastMultiRecallQuery = query;
    return _cannedResult();
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async => _cannedResult();

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async => classifyResult;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    final id = TrailId.generate();
    _trails[id] = <TrailEntry>[];
    return id;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('appendTrail on an unopened trail: $id');
    }
    if (_closedTrails.contains(id)) {
      throw StateError('appendTrail on a closed trail: $id');
    }
    entries.add(entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('closeTrail on an unopened trail: $id');
    }
    entries.add(TrailEntry.outcome(outcome));
    _closedTrails.add(id);
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    final entries = _trails[id];
    if (entries == null) {
      return Stream<TrailEntry>.error(
        StateError('readTrail on an unknown trail: $id'),
      );
    }
    return Stream<TrailEntry>.fromIterable(List<TrailEntry>.of(entries));
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    if (draft.typeName == procedureRunNodeType) procedureRunPersists++;
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      createdAt: DateTime.now().toUtc(),
    );
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async => EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RoleSubstrate implements TomBrainSubstrateClient {
  final List<String> embeddedTexts = <String>[];
  bool failAll = false;

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    if (failAll) {
      return Stream<LlmEvent>.fromIterable(<LlmEvent>[
        const LlmRunFailed(
          callId: 'c',
          failure: LlmFailure(classCode: 'network', message: 'stubbed'),
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'a',
            promptHash: 'pr',
            tokensIn: 0,
            tokensOut: 0,
            retries: 0,
            wallClockMs: 1,
          ),
        ),
      ]);
    }
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      LlmTextDelta(_jsonFor(call.roleId)),
      const LlmRunCompleted(
        callId: 'c',
        report: LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'a',
          promptHash: 'pr',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 1,
        ),
      ),
    ]);
  }

  static String _jsonFor(String roleId) {
    switch (roleId) {
      case 'recall_planner':
        return '{"questions":["q1","q2"]}';
      case 'hypothesis_writer':
        return '{"answers":["ans1","ans2"]}';
      case 'query_term_writer':
        return '{"query":"backups","synonyms":["rsync"]}';
      case 'category_selector':
        return '{"node_types":["Conclusion"],"edge_types":[],'
            '"concept_names":["BackupConcept"]}';
      default:
        return 'ok';
    }
  }

  @override
  Future<EmbeddingResult> embed(String text) async {
    embeddedTexts.add(text);
    return EmbeddingResult(
      vec: Vec(Float32List.fromList(<double>[0.1, 0.2])),
      modelIdentity: const EmbeddingModelIdentity(
        providerId: 'p',
        modelId: 'm',
        dims: 2,
        normalized: true,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InMemoryStacks implements StackApi {
  final Map<String, List<StackEntry>> _stacks = <String, List<StackEntry>>{};

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    (_stacks[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: id,
        stackName: name,
        nodeId: entry,
        priority: priority,
        pushedAt: DateTime.now().toUtc(),
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final entries = _stacks[name] ?? const <StackEntry>[];
    final active = entries
        .where((e) => e.status == StackEntryStatus.active)
        .toList(growable: false);
    return active.length <= k ? active : active.sublist(0, k);
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    _stacks[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final entries = _stacks[name];
    if (entries == null || entries.isEmpty) return null;
    return entries.removeLast();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
