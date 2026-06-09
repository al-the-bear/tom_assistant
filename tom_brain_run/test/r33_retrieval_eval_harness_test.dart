// R.33 — the retrieval eval harness (Plan-2 extension step #33; spec § 23.8).
//
// Two layers of coverage:
//
//   1. The harness *logic* — strategy-set → `MemoryRetrievalConfig`
//      resolution, the five-phase pipeline, metric scoring, the metric ×
//      strategy-set matrix, determinism, and the no-mutation (drop-always)
//      guarantee — driven through a deterministic `_AffinityEnvironment`
//      double whose `query` ranks the seeded corpus by a fixture affinity
//      table read off the *resolved* config's enabled strategies + weights.
//      This is what makes `naive` / `hyde` / `semantic` / `full` produce
//      distinct scores and a deliberately weakened weight set show a
//      measurable drop, deterministically.
//
//   2. The production `ProcedureEngineEvalEnvironment` — its store-facing
//      behaviour (provision / seed / drop through the per-profile binding's
//      registry, and the `EvalSeedDoc` → `NodeDraft` mapping) against a
//      compact fake memory, plus the recall-map parsing (`evalIdsFromRecall`)
//      that recovers the seeded `evalId`s the real `retrieve_for_prompt_v1`
//      conductor returns. The conductor↔`retrievalConfig` contract itself is
//      owned and covered by `h30_retrieval_conductor_test.dart` in the
//      base-first package.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, NodeId, Scope;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart'
    show SmokeSubstrate;

void main() {
  group('R.33 — retrieval eval harness logic (double environment)', () {
    // ── Fixture ────────────────────────────────────────────────────
    //
    // Five corpus docs, one labelled query whose relevant set is {d1, d2, d3}
    // and whose `mustRankTop` is d1. The affinity table assigns a per-strategy
    // signal to each doc; the double scores a doc as Σ weight·affinity over the
    // resolved config's *enabled* strategies. The four named sets enable
    // different strategies (and `semantic_weak` zeroes one weight), so they
    // rank the corpus differently → distinct metric scores.
    const fixtureYaml = '''
profile: eval_throwaway
k: 3
metrics: [precision@k, recall@k, mrr, ndcg]
corpus:
  - { id: d1, kind: conclusion, text: "nightly rsync to the NAS" }
  - { id: d2, kind: conclusion, text: "cron schedules the job" }
  - { id: d3, kind: conclusion, text: "restic encrypts the backup" }
  - { id: d4, kind: event,      text: "unrelated calendar note" }
  - { id: d5, kind: event,      text: "another unrelated note" }
queries:
  - prompt: "how do I automate backups?"
    expect:
      mustInclude: [d1, d2, d3]
      mustRankTop: d1
strategySets:
  - { name: naive,    only: [vector.prompt] }
  - { name: hyde,     only: [vector.prompt, vector.hypothetical_answers] }
  - { name: semantic, only: [vector.prompt, graphWalk.seed_from_concepts] }
  - { name: full,     all: true }
  - name: semantic_weak
    only: [vector.prompt, graphWalk.seed_from_concepts]
    weights: { graphWalk.seed_from_concepts: 0.0 }
''';

    // The affinity table the double scores by: path → evalId → affinity.
    // Only the four paths the named sets distinguish on carry signal; every
    // other (catalogue) strategy contributes 0, so `all: true` is dominated by
    // these four plus the noise path `bm25.prompt_terms` (which favours the
    // irrelevant d4).
    const affinity = <String, Map<String, double>>{
      'vector.prompt': <String, double>{
        'd1': 0.5,
        'd2': 0.9,
        'd3': 0.4,
        'd4': 0.8,
        'd5': 0.2,
      },
      'vector.hypothetical_answers': <String, double>{
        'd1': 0.6,
        'd2': 0.0,
        'd3': 0.9,
        'd4': 0.0,
        'd5': 0.1,
      },
      'graphWalk.seed_from_concepts': <String, double>{
        'd1': 1.0,
        'd2': 0.2,
        'd3': 0.5,
        'd4': 0.0,
        'd5': 0.0,
      },
      'bm25.prompt_terms': <String, double>{
        'd1': 0.0,
        'd2': 0.0,
        'd3': 0.0,
        'd4': 1.0,
        'd5': 0.0,
      },
    };

    late RetrievalEvalConfig config;
    setUp(() {
      config = RetrievalEvalConfig.fromYamlString(fixtureYaml);
    });

    test('the five-phase pipeline runs end-to-end on a fixture corpus', () async {
      final env = _AffinityEnvironment(affinity);
      final report = await RetrievalEvalHarness(env).run(config);

      // provision → seed → query (per set) → drop all happened in order.
      expect(env.log.first, 'provision:eval_throwaway');
      expect(env.log, contains('seed:eval_throwaway:5'));
      expect(env.log.where((e) => e.startsWith('query:')).length,
          config.strategySets.length); // one query × five sets
      expect(env.log.last, 'drop:eval_throwaway');

      // The matrix is fully populated: one cell per (set, metric).
      for (final set in config.strategySets) {
        for (final metric in config.metrics) {
          expect(report.cells[set.name], contains(metric));
        }
      }
    });

    test('naive / hyde / semantic / full produce distinct nDCG scores',
        () async {
      final env = _AffinityEnvironment(affinity);
      final report = await RetrievalEvalHarness(env).run(config);

      final scores = <double>{
        for (final name in <String>['naive', 'hyde', 'semantic', 'full'])
          report.score(name, ndcgMetric),
      };
      // Four named sets → four pairwise-distinct nDCG values.
      expect(scores, hasLength(4),
          reason: 'the four strategy sets must order the corpus differently; '
              'matrix:\n${report.toMatrixString()}');

      // The semantic set, which alone surfaces the must-rank-top d1 first,
      // achieves a perfect nDCG; the naive baseline does not.
      expect(report.score('semantic', ndcgMetric), closeTo(1.0, 1e-9));
      expect(report.score('naive', ndcgMetric), lessThan(1.0));
    });

    test('a deliberately weakened weight set shows a measurable metric drop',
        () async {
      final env = _AffinityEnvironment(affinity);
      final report = await RetrievalEvalHarness(env).run(config);

      // `semantic_weak` is `semantic` with the concept-seed weight zeroed —
      // the high-signal strategy that lifted d1 to the top no longer counts,
      // so the fused ranking collapses to the naive baseline and nDCG drops.
      final semantic = report.score('semantic', ndcgMetric);
      final weakened = report.score('semantic_weak', ndcgMetric);
      expect(weakened, lessThan(semantic));
      expect(weakened, closeTo(report.score('naive', ndcgMetric), 1e-9));
    });

    test('re-running on a fresh profile is deterministic', () async {
      final first = await RetrievalEvalHarness(_AffinityEnvironment(affinity))
          .run(config);
      final second = await RetrievalEvalHarness(_AffinityEnvironment(affinity))
          .run(config);
      expect(first, equals(second));
      expect(first.toMatrixString(), equals(second.toMatrixString()));
    });

    test('the harness drops the profile even when a query phase throws',
        () async {
      final env = _AffinityEnvironment(affinity, throwOnQuery: true);
      await expectLater(
        RetrievalEvalHarness(env).run(config),
        throwsA(isA<StateError>()),
      );
      // drop still ran: no live store left mutated (throwaway profile only).
      expect(env.log.last, 'drop:eval_throwaway');
      expect(env.droppedProfiles, contains('eval_throwaway'));
    });
  });

  group('R.33 — evalIdsFromRecall recovers seeded ids from the recall map', () {
    test('reads the ordered string evalIds out of recall["nodes"]', () {
      final recall = <String, Object?>{
        'nodes': <Object?>[
          <String, Object?>{
            'id': 'n1',
            'values': <String, Object?>{'evalId': 'd3', 'text': 'a'},
          },
          <String, Object?>{
            'id': 'n2',
            'values': <String, Object?>{'evalId': 'd1', 'text': 'b'},
          },
        ],
      };
      expect(evalIdsFromRecall(recall), <String>['d3', 'd1']);
    });

    test('skips nodes without a string evalId, tolerates malformed shapes', () {
      final recall = <String, Object?>{
        'nodes': <Object?>[
          <String, Object?>{'values': <String, Object?>{'evalId': 'd1'}},
          <String, Object?>{'values': <String, Object?>{'no': 'evalId'}},
          'not-a-node',
          <String, Object?>{'values': <String, Object?>{'evalId': 42}},
        ],
      };
      expect(evalIdsFromRecall(recall), <String>['d1']);
      expect(evalIdsFromRecall(null), isEmpty);
      expect(evalIdsFromRecall(<String, Object?>{}), isEmpty);
      expect(evalIdsFromRecall('nope'), isEmpty);
    });
  });

  group('R.33 — evalDocToDraft maps a corpus doc to a seedable NodeDraft', () {
    test('carries evalId in values and capitalises the kind to a typeName', () {
      final draft = evalDocToDraft(const EvalSeedDoc(
        evalId: 'd1',
        kind: 'conclusion',
        text: 'rsync to NAS',
        at: '2026-06-01T00:00:00Z',
        about: <String>['Backups'],
      ));
      expect(draft.typeName, 'Conclusion');
      expect(draft.values['evalId'], 'd1');
      expect(draft.values['text'], 'rsync to NAS');
      expect(draft.values['at'], '2026-06-01T00:00:00Z');
      expect(draft.values['about'], <String>['Backups']);
    });
  });

  group('R.33 — ProcedureEngineEvalEnvironment store-facing lifecycle', () {
    test('provision creates, seed persists drafts, drop deletes the profile',
        () async {
      final memory = _LifecycleMemory();
      // A real (never-invoked) engine so the binding is the production shape.
      final engine = ProcedureEngine(
        resolver: ProcedureResolver(const <LoadedProcedure>[]),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(SmokeSubstrate()),
      );
      final env = ProcedureEngineEvalEnvironment(
        bind: (_) async => EvalProfileBinding(memory: memory, engine: engine),
      );

      const profile = 'eval_lifecycle';
      await env.provision(profile);
      await env.seed(profile, const <EvalSeedDoc>[
        EvalSeedDoc(evalId: 'k1', kind: 'conclusion', text: 'rsync to NAS'),
        EvalSeedDoc(evalId: 'k2', kind: 'event', text: 'a calendar note'),
      ]);
      await env.drop(profile);

      final registry = memory.registry;
      expect(registry.created, contains(profile));
      expect(registry.dropped, contains(profile));
      expect(memory.persisted, hasLength(2));
      expect(
        memory.persisted.map((d) => d.values['evalId']),
        <String>['k1', 'k2'],
      );
      expect(
        memory.persisted.map((d) => d.typeName),
        <String>['Conclusion', 'Event'],
      );
    });
  });
}

// ── A deterministic affinity-scoring environment double ──────────────
//
// Scores each seeded doc as Σ over the resolved config's *enabled* strategies
// of `weight · affinity[path][evalId]`, ranks descending (ties broken by
// evalId ascending for determinism), and returns the ranked evalIds. Reading
// the resolved `MemoryRetrievalConfig` is what couples the score to the
// strategy set under test.
final class _AffinityEnvironment implements RetrievalEvalEnvironment {
  _AffinityEnvironment(this.affinity, {this.throwOnQuery = false});

  final Map<String, Map<String, double>> affinity;
  final bool throwOnQuery;

  final List<String> log = <String>[];
  final List<String> droppedProfiles = <String>[];
  final List<EvalSeedDoc> _seeded = <EvalSeedDoc>[];

  @override
  Future<void> provision(String profile) async {
    log.add('provision:$profile');
  }

  @override
  Future<void> seed(String profile, List<EvalSeedDoc> docs) async {
    _seeded
      ..clear()
      ..addAll(docs);
    log.add('seed:$profile:${docs.length}');
  }

  @override
  Future<List<String>> query(
    String profile,
    String prompt,
    MemoryRetrievalConfig config,
  ) async {
    log.add('query:$profile');
    if (throwOnQuery) {
      throw StateError('query phase failed (deliberate)');
    }
    final scored = <(String, double)>[
      for (final doc in _seeded) (doc.evalId, _scoreDoc(doc.evalId, config)),
    ]..sort((a, b) {
        final byScore = b.$2.compareTo(a.$2);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    return <String>[for (final entry in scored) entry.$1];
  }

  @override
  Future<void> drop(String profile) async {
    droppedProfiles.add(profile);
    log.add('drop:$profile');
  }

  double _scoreDoc(String evalId, MemoryRetrievalConfig config) {
    var score = 0.0;
    for (final family in config.strategies.entries) {
      for (final strat in family.value.entries) {
        if (!strat.value.enabled) continue;
        final path = '${family.key}.${strat.key}';
        final weight = strat.value.weight ?? 1.0;
        final a = affinity[path]?[evalId] ?? 0.0;
        score += weight * a;
      }
    }
    return score;
  }
}

// ── A compact memory fake for the store-facing lifecycle test ────────
//
// Implements only the surface `ProcedureEngineEvalEnvironment` touches in
// provision / seed / drop — the `profiles` registry and `persist` — and lets
// every other `TomBrainMemory` member fall through `noSuchMethod` (none are
// reached because `query` is not exercised here; the never-invoked engine is
// built only to give the binding its production shape).
class _LifecycleMemory implements TomBrainMemory {
  final _FakeProfileRegistry registry = _FakeProfileRegistry();
  final List<NodeDraft> persisted = <NodeDraft>[];

  @override
  MemoryProfileRegistry get profiles => registry;

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    persisted.add(draft);
    return NodeId.generate();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Records the profiles created / dropped against it.
class _FakeProfileRegistry implements MemoryProfileRegistry {
  final List<String> created = <String>[];
  final List<String> dropped = <String>[];

  @override
  Future<List<String>> list() async => List<String>.of(created);

  @override
  Future<bool> exists(String name) async => created.contains(name);

  @override
  Future<void> createProfile(String name) async => created.add(name);

  @override
  Future<void> dropProfile(String name) async => dropped.add(name);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
