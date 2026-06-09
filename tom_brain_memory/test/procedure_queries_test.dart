// Todo 7 (G-PR4) — typed procedure queries
// (`procedure_specification.md` § 7.3, § 9.2, § 10.3).
//
// These drive the three queries against a recording fake of
// `TomBrainMemoryClient`, so the *composition* logic is pinned host-independent
// (no vec0 binary needed): which `RecallQuery` each query builds, how the
// re-rank orders / thresholds / limits, how the run history orders by
// `startedAt`, and how the revision-chain walk follows `superseded_by` both
// ways and returns oldest → newest. The live recall pipeline itself is covered
// by the real-store conformance suite.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show ProcedureRerankWeights;
import 'package:test/test.dart';

void main() {
  group('CandidateProceduresFor', () {
    test('recalls Procedure-typed nodes over bm25+vector and re-ranks', () async {
      final fake = _FakeClient();
      final request = Vec.fromList(<double>[1, 0, 0]);
      // Three retrievable procedures with different intent embeddings.
      final near = _procedure(
        name: 'near_v1',
        status: 'active',
        successRate: 0.9,
        embedding: Vec.fromList(<double>[1, 0, 0]), // cosine 1.0
      );
      final mid = _procedure(
        name: 'mid_v1',
        status: 'preferred',
        successRate: 0.5,
        embedding: Vec.fromList(<double>[0.7, 0.7, 0]), // cosine ~0.707
      );
      final far = _procedure(
        name: 'far_v1',
        status: 'active',
        successRate: 0.1,
        embedding: Vec.fromList(<double>[0, 1, 0]), // cosine 0
      );
      fake.nextRecall = _recallOf(<Node>[far, mid, near]);

      final ranked = await CandidateProceduresFor(
        text: 'answer the prompt',
        embedding: request,
        available: CapabilitySet.fromIterable(const <String>['recall', 'llm']),
      ).execute(fake, now: DateTime.utc(2026, 6, 1));

      // The recall the query issued: Procedure-typed, bm25 + vector.
      final q = fake.lastRecall!;
      expect(q.modes, containsAll(<RecallMode>[RecallMode.bm25, RecallMode.vector]));
      expect(q.filter!.typeNames, <String>{procedureNodeTypeName});

      // Re-rank orders near > mid > far (similarity + success rate agree here).
      expect(ranked.map((r) => r.procedure.name).toList(),
          <String>['near_v1', 'mid_v1', 'far_v1']);
      expect(ranked.first.embeddingSimilarity, closeTo(1.0, 1e-6));
      expect(ranked.last.embeddingSimilarity, closeTo(0.0, 1e-6));
    });

    test('excludes non-retrievable (authored/draft/demoted) candidates',
        () async {
      final fake = _FakeClient();
      fake.nextRecall = _recallOf(<Node>[
        _procedure(name: 'a_v1', status: 'active'),
        _procedure(name: 'd_v1', status: 'draft'),
        _procedure(name: 'x_v1', status: 'demoted'),
        _procedure(name: 'u_v1'), // no status
      ]);

      final ranked = await CandidateProceduresFor(
        text: 'q',
        available: const CapabilitySet(<String>{}),
      ).execute(fake, now: DateTime.utc(2026, 6, 1));

      expect(ranked.map((r) => r.procedure.name), <String>['a_v1']);
    });

    test('applies the minScore threshold and the limit', () async {
      final fake = _FakeClient();
      fake.nextRecall = _recallOf(<Node>[
        for (var i = 0; i < 5; i++)
          _procedure(name: 'p$i', status: 'active', successRate: 0.2 * i),
      ]);

      // weight everything on success rate so the score == successRate, making
      // the threshold easy to reason about.
      const weights = ProcedureRerankWeights(
        embedding: 0,
        requiresOverlap: 0,
        successRate: 1,
        recency: 0,
      );
      final ranked = await CandidateProceduresFor(
        text: 'q',
        available: const CapabilitySet(<String>{}),
        weights: weights,
        minScore: 0.5,
        limit: 2,
      ).execute(fake, now: DateTime.utc(2026, 6, 1));

      // successRate 0.8 (p4) and 0.6 (p3) clear 0.5; 0.4/0.2/0.0 do not.
      // limit 2 keeps the top two.
      expect(ranked.map((r) => r.procedure.name), <String>['p4', 'p3']);
    });

    test('throws when given neither text nor embedding', () async {
      expect(
        () => CandidateProceduresFor(available: const CapabilitySet(<String>{}))
            .execute(_FakeClient()),
        throwsArgumentError,
      );
    });
  });

  group('ProcedureRunsOf', () {
    test('symbolic-filters runs by procedureId and orders newest first',
        () async {
      final fake = _FakeClient();
      fake.nextRecall = _recallOf(<Node>[
        _run(runId: 'r1', startedAt: '2026-05-01T10:00:00.000Z'),
        _run(runId: 'r3', startedAt: '2026-05-03T10:00:00.000Z'),
        _run(runId: 'r2', startedAt: '2026-05-02T10:00:00.000Z'),
      ]);

      final runs = await const ProcedureRunsOf('answer_with_memory_v1')
          .execute(fake);

      final q = fake.lastRecall!;
      expect(q.modes, <RecallMode>{RecallMode.symbolic});
      expect(q.filter!.typeNames, <String>{procedureRunNodeTypeName});
      expect(q.filter!.attributes, <AttrClause>[
        AttrClause('procedureId', SymbolicOp.eq, 'answer_with_memory_v1'),
      ]);
      expect(runs.map((r) => r.runId), <String>['r3', 'r2', 'r1']);
    });

    test('honours the limit, keeping the newest', () async {
      final fake = _FakeClient();
      fake.nextRecall = _recallOf(<Node>[
        for (var d = 1; d <= 5; d++)
          _run(runId: 'r$d', startedAt: '2026-05-0${d}T10:00:00.000Z'),
      ]);

      final runs =
          await const ProcedureRunsOf('p', limit: 2).execute(fake);
      expect(runs.map((r) => r.runId), <String>['r5', 'r4']);
    });
  });

  group('ProcedureRevisionChain', () {
    test('walks superseded_by both ways and returns oldest → newest', () async {
      // Chain a → b → c, anchored at b.
      final a = _procedure(name: 'p_v1', status: 'demoted', revision: 1);
      final b = _procedure(name: 'p_v2', status: 'demoted', revision: 2);
      final c = _procedure(name: 'p_v3', status: 'active', revision: 3);

      final fake = _FakeClient()
        ..nodes = {a.id: a, b.id: b, c.id: c}
        ..supersededByOutgoing = {a.id: b.id, b.id: c.id}
        ..supersededByIncoming = {c.id: b.id, b.id: a.id};

      final chain = await ProcedureRevisionChain(b.id).execute(fake);

      expect(chain.map((p) => p.name),
          <String>['p_v1', 'p_v2', 'p_v3']);
      expect(chain.map((p) => p.revision), <int?>[1, 2, 3]);
    });

    test('a single-revision procedure is its own one-element chain', () async {
      final only = _procedure(name: 'solo_v1', status: 'active', revision: 1);
      final fake = _FakeClient()..nodes = {only.id: only};

      final chain = await ProcedureRevisionChain(only.id).execute(fake);
      expect(chain.map((p) => p.name), <String>['solo_v1']);
    });

    test('an unknown anchor yields an empty chain', () async {
      final chain =
          await ProcedureRevisionChain(NodeId.generate()).execute(_FakeClient());
      expect(chain, isEmpty);
    });
  });
}

// ─── Node builders ────────────────────────────────────────────────────────

Node _procedure({
  required String name,
  String? status,
  int? revision,
  num? successRate,
  String? lastRunAt,
  Vec? embedding,
}) {
  return Node(
    id: NodeId.generate(),
    typeName: procedureNodeTypeName,
    createdAt: DateTime.utc(2026, 1, 1),
    embedding: embedding,
    values: <String, Object?>{
      'name': name,
      'code': 'void main() {}',
      'status': ?status,
      'revision': ?revision,
      'successRate': ?successRate,
      'lastRunAt': ?lastRunAt,
    },
  );
}

Node _run({required String runId, required String startedAt}) {
  return Node(
    id: NodeId.generate(),
    typeName: procedureRunNodeTypeName,
    createdAt: DateTime.utc(2026, 1, 1),
    values: <String, Object?>{
      'procedureId': 'answer_with_memory_v1',
      'runId': runId,
      'status': 'succeeded',
      'startedAt': startedAt,
      'trailId': 'trail-$runId',
    },
  );
}

RecallResult _recallOf(List<Node> nodes) => RecallResult(
      nodes: nodes,
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 0,
      ),
    );

// ─── Recording fake of the client contract ─────────────────────────────────

class _FakeClient implements TomBrainMemoryClient {
  RecallResult? nextRecall;
  RecallQuery? lastRecall;

  Map<NodeId, Node> nodes = <NodeId, Node>{};
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
    final edges = <Edge>[];
    if (direction == EdgeDirection.outgoing) {
      final to = supersededByOutgoing[id];
      if (to != null) edges.add(_edge(id, to));
    } else if (direction == EdgeDirection.incoming) {
      final from = supersededByIncoming[id];
      if (from != null) edges.add(_edge(from, id));
    }
    return edges;
  }

  Edge _edge(NodeId from, NodeId to) => Edge(
        id: EdgeId.generate(),
        from: from,
        type: EdgeType.supersededBy,
        to: to,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeClient does not implement ${invocation.memberName}; the typed '
        'procedure queries only use recall / get / getMany / edgesOf.',
      );
}
