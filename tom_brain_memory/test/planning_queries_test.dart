// Todo 8 (G-P5) — typed planning queries
// (`planning_specification.md` § 7.4, § 10, G-P5).
//
// These drive the four planning reads against a recording fake of
// `TomBrainMemoryClient`, so the *composition* logic is pinned host-independent
// (no vec0 binary): which `RecallQuery` each builds, how `OpenPlansFor` filters
// to open plans, how `StepsBlockedBy` reads incoming `part_of[kind=depends_on]`
// edges, how `PlanStepsInOrder` topo-sorts via the domain-free `orderPlanSteps`
// and surfaces a cycle, and how `SupersededHistoryOf` delegates to the shared
// chain walk. The live recall pipeline itself is covered by the real-store
// conformance suite.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('OpenPlansFor', () {
    test('symbolic-scans Plan nodes when no text/embedding, keeps open only',
        () async {
      final fake = _FakeClient()
        ..nextRecall = _recallOf(<Node>[
          _plan(goal: 'draft plan', status: 'draft'),
          _plan(goal: 'active plan', status: 'active'),
          _plan(goal: 'done plan', status: 'completed'),
          _plan(goal: 'no status'),
        ]);

      final plans = await const OpenPlansFor().execute(fake);

      final q = fake.lastRecall!;
      expect(q.modes, <RecallMode>{RecallMode.symbolic});
      expect(q.filter!.typeNames, <String>{planNodeTypeName});
      expect(plans.map((p) => p.goal), <String>['draft plan', 'active plan']);
    });

    test('uses bm25+vector when goal text is supplied', () async {
      final fake = _FakeClient()
        ..nextRecall = _recallOf(<Node>[_plan(goal: 'x', status: 'active')]);

      await const OpenPlansFor(goalText: 'build the thing').execute(fake);

      final q = fake.lastRecall!;
      expect(q.modes, containsAll(<RecallMode>[RecallMode.bm25, RecallMode.vector]));
      expect(q.text, 'build the thing');
    });

    test('honours the limit, keeping the first open plans', () async {
      final fake = _FakeClient()
        ..nextRecall = _recallOf(<Node>[
          for (var i = 0; i < 5; i++) _plan(goal: 'g$i', status: 'active'),
        ]);

      final plans = await const OpenPlansFor(limit: 2).execute(fake);
      expect(plans.map((p) => p.goal), <String>['g0', 'g1']);
    });
  });

  group('StepsBlockedBy', () {
    test('reads incoming part_of[kind=depends_on] edges and returns dependents',
        () async {
      // x and y both depend on dep; z is an unrelated part_of (no kind marker).
      final dep = _step(description: 'dependency');
      final x = _step(description: 'dependent x');
      final y = _step(description: 'dependent y');
      final z = _step(description: 'plain child');
      final fake = _FakeClient()
        ..nodes = {dep.id: dep, x.id: x, y.id: y, z.id: z}
        ..incoming[dep.id] = <Edge>[
          _partOf(x.id, dep.id, dependsOn: true),
          _partOf(y.id, dep.id, dependsOn: true),
          _partOf(z.id, dep.id, dependsOn: false),
        ];

      final blocked = await StepsBlockedBy(dep.id).execute(fake);

      expect(
        blocked.map((s) => s.description).toSet(),
        <String>{'dependent x', 'dependent y'},
      );
    });

    test('a step nothing depends on blocks nothing', () async {
      final leaf = _step(description: 'leaf');
      final fake = _FakeClient()..nodes = {leaf.id: leaf};
      final blocked = await StepsBlockedBy(leaf.id).execute(fake);
      expect(blocked, isEmpty);
    });
  });

  group('PlanStepsInOrder', () {
    test('topo-sorts steps deps-first within the plan', () async {
      final plan = NodeId.generate();
      // c depends on b, b depends on a → order a, b, c.
      final a = _step(description: 'a', planId: plan.value);
      final b = _step(description: 'b', planId: plan.value);
      final c = _step(description: 'c', planId: plan.value);
      final fake = _FakeClient()
        ..nextRecall = _recallOf(<Node>[c, a, b])
        ..nodes = {a.id: a, b.id: b, c.id: c}
        ..outgoing[c.id] = <Edge>[_partOf(c.id, b.id, dependsOn: true)]
        ..outgoing[b.id] = <Edge>[_partOf(b.id, a.id, dependsOn: true)];

      final result = await PlanStepsInOrder(plan).execute(fake);

      final q = fake.lastRecall!;
      expect(q.filter!.typeNames, <String>{planStepNodeTypeName});
      expect(q.filter!.attributes, <AttrClause>[
        AttrClause('plan_id', SymbolicOp.eq, plan.value),
      ]);
      expect(result.ordered.map((s) => s.description), <String>['a', 'b', 'c']);
      expect(result.hasCycle, isFalse);
      expect(result.cyclic, isEmpty);
    });

    test('surfaces a dependency cycle in cyclic, not ordered', () async {
      final plan = NodeId.generate();
      final a = _step(description: 'a', planId: plan.value);
      final b = _step(description: 'b', planId: plan.value);
      final fake = _FakeClient()
        ..nextRecall = _recallOf(<Node>[a, b])
        ..nodes = {a.id: a, b.id: b}
        ..outgoing[a.id] = <Edge>[_partOf(a.id, b.id, dependsOn: true)]
        ..outgoing[b.id] = <Edge>[_partOf(b.id, a.id, dependsOn: true)];

      final result = await PlanStepsInOrder(plan).execute(fake);

      expect(result.hasCycle, isTrue);
      expect(result.ordered, isEmpty);
      expect(result.cyclic.map((s) => s.description).toSet(), <String>{'a', 'b'});
    });
  });

  group('SupersededHistoryOf', () {
    test('returns the revision chain oldest → newest as PlanViews', () async {
      final v1 = _plan(goal: 'v1', status: 'superseded');
      final v2 = _plan(goal: 'v2', status: 'superseded');
      final v3 = _plan(goal: 'v3', status: 'active');
      final fake = _FakeClient()
        ..nodes = {v1.id: v1, v2.id: v2, v3.id: v3}
        ..supersededByOutgoing = {v1.id: v2.id, v2.id: v3.id}
        ..supersededByIncoming = {v3.id: v2.id, v2.id: v1.id};

      final history = await SupersededHistoryOf(v2.id).execute(fake);
      expect(history.map((p) => p.goal), <String>['v1', 'v2', 'v3']);
    });
  });
}

// ─── Node builders ──────────────────────────────────────────────────────────

Node _plan({required String goal, String? status}) => Node(
      id: NodeId.generate(),
      typeName: planNodeTypeName,
      createdAt: DateTime.utc(2026, 1, 1),
      values: <String, Object?>{'goal': goal, 'status': ?status},
    );

Node _step({required String description, String? planId}) => Node(
      id: NodeId.generate(),
      typeName: planStepNodeTypeName,
      createdAt: DateTime.utc(2026, 1, 1),
      values: <String, Object?>{'description': description, 'plan_id': ?planId},
    );

RecallResult _recallOf(List<Node> nodes) => RecallResult(
      nodes: nodes,
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 0,
      ),
    );

Edge _partOf(NodeId from, NodeId to, {required bool dependsOn}) => Edge(
      id: EdgeId.generate(),
      from: from,
      type: EdgeType.partOf,
      to: to,
      attrs: dependsOn
          ? <String, Object?>{'kind': dependsOnEdgeKind}
          : const <String, Object?>{},
    );

// ─── Recording fake of the client contract ────────────────────────────────────

class _FakeClient implements TomBrainMemoryClient {
  RecallResult? nextRecall;
  RecallQuery? lastRecall;

  Map<NodeId, Node> nodes = <NodeId, Node>{};
  Map<NodeId, List<Edge>> outgoing = <NodeId, List<Edge>>{};
  Map<NodeId, List<Edge>> incoming = <NodeId, List<Edge>>{};
  Map<NodeId, NodeId> supersededByOutgoing = <NodeId, NodeId>{};
  Map<NodeId, NodeId> supersededByIncoming = <NodeId, NodeId>{};

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    lastRecall = query;
    return nextRecall ?? _recallOf(const <Node>[]);
  }

  @override
  Future<Node?> get(NodeId id) async => nodes[id];

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async =>
      <Node>[for (final id in ids) if (nodes[id] != null) nodes[id]!];

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    List<Edge> pool;
    if (direction == EdgeDirection.outgoing) {
      pool = <Edge>[
        ...?outgoing[id],
        if (supersededByOutgoing[id] case final to?)
          _superseded(id, to),
      ];
    } else if (direction == EdgeDirection.incoming) {
      pool = <Edge>[
        ...?incoming[id],
        if (supersededByIncoming[id] case final from?)
          _superseded(from, id),
      ];
    } else {
      pool = <Edge>[...?outgoing[id], ...?incoming[id]];
    }
    if (types == null) return pool;
    return pool.where((e) => types.contains(e.type)).toList();
  }

  Edge _superseded(NodeId from, NodeId to) => Edge(
        id: EdgeId.generate(),
        from: from,
        type: EdgeType.supersededBy,
        to: to,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeClient does not implement ${invocation.memberName}; the typed '
        'planning queries only use recall / get / getMany / edgesOf.',
      );
}
