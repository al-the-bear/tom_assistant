// plan_v1 — the planning-loop procedure acceptance suite
// (Todo 8 / G-P2, G-P4, G-P6; `planning_specification.md` § 4.1, § 4.7, § 10).
//
// `plan_v1` is the real planning loop — a d4rt procedure (no `tom_brain_planning`
// project). It:
//
//   1. classifies the goal (`planner`) into a `PlanKind`;
//   2. decomposes it into steps with inline dependency markers (`decomposer`);
//   3. orders the steps / flags an unorderable graph (`estimator`);
//   4. critiques the graph (`plan_evaluator`) → `accept` commits, `revise`
//      re-enters the loop;
//   5. on accept persists a `Plan` node + its `PlanStep` nodes, `part_of`
//      step→plan edges, and `part_of[kind=depends_on]` dependency edges, and
//      emits a `PlanningEvent` trail through the `note(...)` primitive;
//   6. on a shaking event (observation + existing plan id) re-plans surgically
//      via `re_planner` — new replacement steps, `superseded_by` edges from the
//      steps the revision replaces (structural, never destructive — hard
//      principle 6).
//
// The procedure is loaded from the real `scripts/system/` store so the test
// exercises the shipped artifact through the engine, with a stub memory that
// records every persist + edge (with edge attrs, so the `depends_on` marker is
// observable) and a role-scripted substrate (canned planner / decomposer /
// estimator / evaluator / re-planner outputs) so the post-conditions are
// observable.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        NodeId,
        StackEntryId,
        TrailId,
        Vec,
        dependsOnEdgeKind,
        planningEventKinds;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'stub_prompt_resolver.dart';

/// Maps each migrated `assist_user.plan.*` prompt id to the planning role its
/// stage runs under, so the role-keyed `_ScriptedSubstrate` still distinguishes
/// the five stages now that the procedure resolves prompts through `sub.run`.
const Map<String, String> _planRoleById = <String, String>{
  'assist_user.plan.classify': 'planner',
  'assist_user.plan.decompose': 'decomposer',
  'assist_user.plan.order': 'estimator',
  'assist_user.plan.evaluate': 'plan_evaluator',
  'assist_user.plan.replan': 're_planner',
};

void main() {
  late _CapturingMemory memory;
  late _ScriptedSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _CapturingMemory();
    substrate = _ScriptedSubstrate();
    memoryBridge = MemoryBridge(memory);
    final prompts = StubPromptResolver(
      roleForId: (id) => _planRoleById[id] ?? 'assistant_to_user',
    );
    substrateBridge = SubstrateBridge(
      substrate,
      promptResolver: prompts.resolver,
      routeChainOf: prompts.routeChainOf,
    );
  });

  ProcedureEngine engineFor(Iterable<LoadedProcedure> procedures) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        now: () => DateTime.utc(2026, 6, 2, 12, 0, 0),
      );

  Future<ProcedureOutcome> runPlan(Map<String, Object?> args) async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    final engine = engineFor(resolver.ids.map(resolver.resolve).toList());
    return engine
        .invoke(ProcedureInvocation(procedureId: 'plan_v1', arguments: args))
        .outcome;
  }

  ({NodeId id, NodeDraft draft}) plan() =>
      memory.persistedOfType('Plan').single;

  Iterable<({NodeId id, NodeDraft draft})> steps() =>
      memory.persistedOfType('PlanStep');

  Iterable<_Edge> stepOfEdges() => memory.recordedEdges.where(
    (e) => e.type == EdgeType.partOf && e.attrs?['kind'] != dependsOnEdgeKind,
  );

  Iterable<_Edge> dependsOnEdges() => memory.recordedEdges.where(
    (e) => e.type == EdgeType.partOf && e.attrs?['kind'] == dependsOnEdgeKind,
  );

  group('G-P2 happy path — classify, decompose, order, accept', () {
    test(
      'persists an active Plan with ordered Steps + dependency edges',
      () async {
        substrate.planner = <String>['creation'];
        substrate.decomposer = <String>[
          'Build the schema\n'
              'Write the migration <- 1\n'
              'Wire the loader <- 2',
        ];
        substrate.estimator = <String>['1,2,3'];
        substrate.evaluator = <String>['accept'];

        final outcome = await runPlan(<String, Object?>{'goal': 'ship export'});

        expect(outcome.status, TrailOutcomeStatus.accepted);

        final p = plan();
        expect(p.draft.values['status'], 'active');
        expect(p.draft.values['kind'], 'creation');
        expect(p.draft.values['goal'], 'ship export');

        // Three steps, all pending, all `create` (creation-kind leaf steps).
        final stepList = steps().toList();
        expect(stepList, hasLength(3));
        for (final s in stepList) {
          expect(s.draft.values['status'], 'pending');
          expect(s.draft.values['kind'], 'create');
          expect(s.draft.values['plan_id'], p.id.value);
        }

        // Three step→plan `part_of` edges, two `depends_on` dependency edges.
        expect(stepOfEdges(), hasLength(3));
        expect(dependsOnEdges(), hasLength(2));

        // The plan id is reported and produced.
        expect(outcome.result!.output<String>('plan'), p.id.value);
        expect(outcome.result!.output<String>('status'), 'active');
        final producedBy = memory.recordedEdges.where(
          (e) => e.type == EdgeType.producedBy && e.from == p.id,
        );
        expect(producedBy, hasLength(1));
      },
    );
  });

  group('G-P2 critique re-entry — revise then accept', () {
    test(
      'a revise verdict re-enters; the second pass commits one plan',
      () async {
        substrate.planner = <String>['creation'];
        substrate.decomposer = <String>['Do the thing'];
        substrate.estimator = <String>['1'];
        // First critique rejects, second accepts.
        substrate.evaluator = <String>['revise: missing a step', 'accept'];

        final outcome = await runPlan(<String, Object?>{'goal': 'x'});

        expect(outcome.status, TrailOutcomeStatus.accepted);
        // Exactly one Plan committed (the accepted second pass), not one per
        // iteration — rejected iterations persist nothing.
        expect(memory.persistedOfType('Plan'), hasLength(1));
        expect(plan().draft.values['status'], 'active');
        // The evaluator role was consulted twice (reject, then accept).
        expect(substrate.evaluatorCalls, 2);
      },
    );
  });

  group('G-P2 unorderable — a cycle every iteration fails loudly', () {
    test(
      'no orderable graph after all iterations → errored, no Plan',
      () async {
        substrate.planner = <String>['research'];
        substrate.decomposer = <String>['A <- 2\nB <- 1'];
        substrate.estimator = <String>['cycle'];
        substrate.evaluator = <String>['accept'];

        final outcome = await runPlan(<String, Object?>{
          'goal': 'x',
          'maxIterations': 2,
        });

        // A script signals failure by throwing → the run closes errored.
        expect(outcome.status, TrailOutcomeStatus.errored);
        expect(memory.persistedOfType('Plan'), isEmpty);
      },
    );
  });

  group('G-P2 best-effort draft — exhausted but an orderable graph exists', () {
    test('a never-accepted but orderable plan is committed at draft', () async {
      substrate.planner = <String>['research'];
      substrate.decomposer = <String>['A\nB <- 1'];
      // iter0 cannot order; iter1 can — so a best-effort graph exists.
      substrate.estimator = <String>['cycle', '1,2'];
      // Never accepted.
      substrate.evaluator = <String>['revise', 'revise'];

      final outcome = await runPlan(<String, Object?>{
        'goal': 'x',
        'maxIterations': 2,
      });

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(memory.persistedOfType('Plan'), hasLength(1));
      expect(plan().draft.values['status'], 'draft');
      expect(outcome.result!.output<String>('status'), 'draft');
    });
  });

  group('G-P2 goal kinds — leaf step kind follows the plan kind', () {
    Future<void> expectStepKind(String planKind, String stepKind) async {
      substrate.planner = <String>[planKind];
      substrate.decomposer = <String>['Do the one thing'];
      substrate.estimator = <String>['1'];
      substrate.evaluator = <String>['accept'];

      final outcome = await runPlan(<String, Object?>{'goal': 'x'});
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(plan().draft.values['kind'], planKind);
      expect(steps().single.draft.values['kind'], stepKind);
    }

    test(
      'research → research steps',
      () => expectStepKind('research', 'research'),
    );
    test('decision → decide steps', () => expectStepKind('decision', 'decide'));
    test('composite → think steps', () => expectStepKind('composite', 'think'));
  });

  group('G-P4 re-planning — surgical, superseded_by, never destructive', () {
    test(
      'an observation rewrites a sub-graph and supersedes the old step',
      () async {
        final planId = NodeId.generate();
        final oldStep = NodeId.generate();
        substrate.rePlanner = <String>[
          'Re-fetch the stale source\n'
              'supersedes: ${oldStep.value}',
        ];

        final outcome = await runPlan(<String, Object?>{
          'goal': 'keep the export current',
          'plan': planId.value,
          'observation': 'the upstream export format changed',
        });

        expect(outcome.status, TrailOutcomeStatus.accepted);
        expect(outcome.result!.output<String>('status'), 'revised');

        // A replacement PlanStep was persisted under the existing plan.
        final newSteps = steps().toList();
        expect(newSteps, hasLength(1));
        expect(newSteps.single.draft.values['plan_id'], planId.value);

        // The old step is superseded by the replacement (structural retention).
        final superseded = memory.recordedEdges.where(
          (e) => e.type == EdgeType.supersededBy && e.from == oldStep,
        );
        expect(superseded, hasLength(1));
        expect(superseded.single.to, newSteps.single.id);

        // The replacement is wired into the existing plan with a step-of edge.
        expect(stepOfEdges(), hasLength(1));
        expect(stepOfEdges().single.to, planId);
      },
    );
  });

  group('G-P6 trail vocabulary — the body never drifts from the shared set', () {
    final source = File('scripts/system/plan_v1.dart').readAsStringSync();

    test('every note(...) category the body emits is a planningEventKind', () {
      final emitted = _noteCategories(source);
      expect(emitted, isNotEmpty);
      for (final category in emitted) {
        expect(
          planningEventKinds,
          contains(category),
          reason:
              '$category is not in the shared planningEventKinds vocabulary',
        );
      }
    });

    test('the depends_on edge marker literal matches the shared constant', () {
      // The sandboxed body writes the literal (it cannot import shared); pin it
      // against the constant so the two never drift.
      expect(source, contains("'$dependsOnEdgeKind'"));
    });

    test('the header declares the seven primitives the loop uses', () async {
      final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
      final resolver = await ProcedureResolver.fromStore(store);
      final loaded = resolver.resolve('plan_v1');
      expect(loaded.header.requires.toSet(), <String>{
        'recall',
        'run',
        'runProcedure',
        'embed',
        'persist',
        'edge',
        'note',
      });
    });
  });
}

/// Extracts every `note('<category>'` literal the body emits.
Set<String> _noteCategories(String source) {
  final out = <String>{};
  final re = RegExp(r"note\(\s*'([^']+)'");
  for (final m in re.allMatches(source)) {
    out.add(m.group(1)!);
  }
  return out;
}

typedef _Edge = ({
  NodeId from,
  EdgeType type,
  NodeId to,
  Map<String, Object?>? attrs,
});

// ── A persist + edge capturing `TomBrainMemory` ─────────────────────────────
//
// Returns a configurable (empty by default) recall, assigns a fresh id to every
// persisted node and records the (id, draft) pair, records every edge's
// (from, type, to, attrs) — attrs included so the `depends_on` marker is
// observable — and models enough of the store for the run recorder's trail +
// stack writes to succeed. Mirrors the author-loop double, extended with edge
// attrs.
class _CapturingMemory implements TomBrainMemory {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  final List<({NodeId id, NodeDraft draft})> persisted =
      <({NodeId id, NodeDraft draft})>[];

  final List<_Edge> recordedEdges = <_Edge>[];

  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  ClassificationResult classifyResult = const ClassificationResult.unknown();

  Iterable<({NodeId id, NodeDraft draft})> persistedOfType(String typeName) =>
      persisted.where((p) => p.draft.typeName == typeName);

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async => recallResult;

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      recallResult;

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
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      createdAt: DateTime.now().toUtc(),
    );
    persisted.add((id: id, draft: draft));
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
  }) async {
    recordedEdges.add((from: from, type: type, to: to, attrs: attrs));
    return EdgeId.generate();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ── A role-scripted `TomBrainSubstrateClient` ───────────────────────────────
//
// Branches on `LlmCall.roleId`: each planning role draws the next canned output
// from its own queue. A drained queue repeats its last entry, so a loop that
// calls a role one more time than scripted still terminates. `evaluatorCalls`
// counts the critique calls so a re-entry test can assert the loop iterated.
class _ScriptedSubstrate implements TomBrainSubstrateClient {
  List<String> planner = <String>['composite'];
  List<String> decomposer = <String>['Do the thing'];
  List<String> estimator = <String>['1'];
  List<String> evaluator = <String>['accept'];
  List<String> rePlanner = <String>['Replacement step'];

  int _plannerIdx = 0;
  int _decomposerIdx = 0;
  int _estimatorIdx = 0;
  int _evaluatorIdx = 0;
  int _rePlannerIdx = 0;

  int evaluatorCalls = 0;

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    final String text;
    switch (call.roleId) {
      case 'planner':
        text = _next(planner, _plannerIdx++);
      case 'decomposer':
        text = _next(decomposer, _decomposerIdx++);
      case 'estimator':
        text = _next(estimator, _estimatorIdx++);
      case 'plan_evaluator':
        evaluatorCalls++;
        text = _next(evaluator, _evaluatorIdx++);
      case 're_planner':
        text = _next(rePlanner, _rePlannerIdx++);
      default:
        text = 'ok';
    }
    return Stream<LlmEvent>.fromIterable(<LlmEvent>[
      LlmTextDelta(text),
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

  static String _next(List<String> queue, int index) =>
      index < queue.length ? queue[index] : queue.last;

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
    vec: Vec(Float32List.fromList(<double>[0.0])),
    modelIdentity: const EmbeddingModelIdentity(
      providerId: 'p',
      modelId: 'm',
      dims: 1,
      normalized: true,
    ),
  );

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
