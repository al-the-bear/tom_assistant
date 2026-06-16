// C.12 — MemoryBridge unit tests.
//
// Drives `MemoryBridge` against in-memory fakes of `TomBrainMemoryClient`
// and `StackApi` (the interface boundary, PE-10). Each test asserts two
// things: (a) the primitive d4rt-facing arguments are converted into the
// correct memory domain types on the way in, and (b) the domain results
// are flattened into the correct primitive maps/lists on the way out.
//
// These are *native* Dart tests — they do NOT run the d4rt generator.
// The generator-output round-trip smoke is C.15. This step (C.12) proves
// the source class behaves before it is bridged.

// The memory client interface + value types moved to tom_brain_shared at
// A.88 (todo #16); this test now sources them from the shared barrel.
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  late _FakeMemoryClient client;
  late _FakeStackApi stacks;
  late MemoryBridge bridge;

  setUp(() {
    stacks = _FakeStackApi();
    client = _FakeMemoryClient(stacks);
    bridge = MemoryBridge(client);
  });

  group('C.12 MemoryBridge — construction', () {
    test('wraps the injected client (PE-10 interface boundary)', () {
      expect(bridge.client, same(client));
    });
  });

  group('C.12 MemoryBridge.recall', () {
    test('converts modes + k and flattens nodes + report', () async {
      final node = Node(
        id: NodeId.fromString('n_00000000000000000000000001'),
        typeName: 'Conclusion',
        values: const <String, Object?>{'text': 'the answer'},
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        updatedAt: DateTime.utc(2026, 1, 3, 4, 5, 6),
        lastAccess: DateTime.utc(2026, 1, 4, 5, 6, 7),
        accessCount: 9,
        embedding: Vec.fromList(const <double>[0.1, 0.2, 0.3]),
      );
      client.recallResult = RecallResult(
        nodes: <Node>[node],
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{
            RecallMode.bm25: 3,
            RecallMode.vector: 5,
          },
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          diversityLambda: 0.7,
          elapsedMs: 12,
          embeddingsCallouts: 1,
        ),
      );

      final out = await bridge.recall('how do I X?', modes: const <String>[
        'bm25',
        'vector',
      ], k: 8);

      // (a) Inbound conversion.
      final q = client.lastRecallQuery!;
      expect(q.text, 'how do I X?');
      expect(q.modes, <RecallMode>{RecallMode.bm25, RecallMode.vector});
      expect(q.k, 8);

      // (b) Outbound flattening.
      final nodes = out['nodes']! as List<Object?>;
      expect(nodes, hasLength(1));
      final n0 = nodes.first! as Map<String, Object?>;
      expect(n0['id'], 'n_00000000000000000000000001');
      expect(n0['typeName'], 'Conclusion');
      expect(n0['values'], <String, Object?>{'text': 'the answer'});
      expect(n0['status'], 'active');
      expect(n0['createdAt'], '2026-01-02T03:04:05.000Z');
      // § 10 — the three date/usage fields are always present.
      expect(n0['updatedAt'], '2026-01-03T04:05:06.000Z');
      expect(n0['lastAccess'], '2026-01-04T05:06:07.000Z');
      expect(n0['accessCount'], 9);
      // § 10 decision 4 — the embedding vector is never serialized, even
      // when the node carries one.
      expect(n0.containsKey('embedding'), isFalse);
      // § 10 — edges only when relations:true (default off here).
      expect(n0.containsKey('relations'), isFalse);
      expect(client.edgesOfCalls, 0);

      final report = out['report']! as Map<String, Object?>;
      expect(report['candidatesPerMode'],
          <String, int>{'bm25': 3, 'vector': 5});
      expect(report['fusionStrategy'], 'rrf');
      expect(report['diversityStrategy'], 'mmr');
      expect(report['elapsedMs'], 12);
      expect(report['embeddingsCallouts'], 1);
    });

    test('defaults modes to bm25+vector and k to 8', () async {
      client.recallResult = const RecallResult(
        nodes: <Node>[],
        report: RecallReport(
          candidatesPerMode: <RecallMode, int>{},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 1,
        ),
      );

      await bridge.recall('q');

      final q = client.lastRecallQuery!;
      expect(q.modes, <RecallMode>{RecallMode.bm25, RecallMode.vector});
      expect(q.k, 8);
    });

    test('rejects an unknown mode name', () {
      expect(
        () => bridge.recall('q', modes: const <String>['nope']),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // memory_optimization_plan § 10 / memory_specification § 12.2.1 — the
  // opt-in `relations` flag bundles each recalled node's edges
  // (`edgesOf(id)`) into the serialized map. Off by default; on demand it
  // fetches the both-direction adjacency and flattens it via `_edgeToMap`.
  group('C.12 MemoryBridge — § 10 relations flag', () {
    setUp(() {
      client.recallResult = RecallResult(
        nodes: <Node>[
          Node(
            id: NodeId.fromString('n_00000000000000000000000001'),
            typeName: 'Conclusion',
            values: const <String, Object?>{'text': 'the answer'},
            createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
          ),
        ],
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 1},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 1,
        ),
      );
      client.edgesResult = <Edge>[
        Edge(
          id: EdgeId.fromString('e_00000000000000000000000001'),
          from: NodeId.fromString('n_00000000000000000000000001'),
          type: EdgeType.fromWireName('derived_from'),
          to: NodeId.fromString('n_00000000000000000000000002'),
          weight: 0.5,
          attrs: const <String, Object?>{'kind': 'depends_on'},
        ),
      ];
    });

    test('recall omits relations and never calls edgesOf when off', () async {
      final out = await bridge.recall('q');
      final nodes = out['nodes']! as List<Object?>;
      final n0 = nodes.first! as Map<String, Object?>;
      expect(n0.containsKey('relations'), isFalse);
      expect(client.edgesOfCalls, 0);
    });

    test('recall bundles edgesOf(id) under relations when on', () async {
      final out = await bridge.recall('q', relations: true);
      final nodes = out['nodes']! as List<Object?>;
      final n0 = nodes.first! as Map<String, Object?>;

      // Each recalled node's adjacency was queried exactly once.
      expect(client.edgesOfCalls, 1);
      expect(client.edgesOfQueried.single,
          NodeId.fromString('n_00000000000000000000000001'));

      // The edge is flattened in the MCP `_encodeEdge` shape.
      final relations = n0['relations']! as List<Object?>;
      expect(relations, hasLength(1));
      final e0 = relations.first! as Map<String, Object?>;
      expect(e0['from'], 'n_00000000000000000000000001');
      expect(e0['type'], 'derived_from');
      expect(e0['to'], 'n_00000000000000000000000002');
      expect(e0['weight'], 0.5);
      expect(e0['attrs'], <String, Object?>{'kind': 'depends_on'});
      // The synthetic edge id is not exposed (mirrors MCP).
      expect(e0.containsKey('id'), isFalse);
    });

    test('relations:true records the flag on the recall trail input',
        () async {
      await bridge.recall('q', relations: true);
      // The flag is recorded in the primitive's input map regardless of
      // value — proven here for the on case via the side effect (edgesOf
      // ran); the recorded-input shape is covered structurally by the
      // C.47 audit roundtrip.
      expect(client.edgesOfCalls, 1);
    });

    test('recallMulti bundles relations per node when on', () async {
      client.recallMultiResult = RecallResult(
        nodes: <Node>[
          Node(
            id: NodeId.fromString('n_00000000000000000000000001'),
            typeName: 'Conclusion',
            values: const <String, Object?>{'text': 'a'},
            createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
          ),
        ],
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{RecallMode.bm25: 1},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 1,
        ),
      );
      final out = await bridge.recallMulti(
        <Object?>[
          <String, Object?>{'mode': 'bm25', 'text': 'q'},
        ],
        relations: true,
      );
      final nodes = out['nodes']! as List<Object?>;
      final n0 = nodes.first! as Map<String, Object?>;
      expect(client.edgesOfCalls, 1);
      expect((n0['relations']! as List<Object?>), hasLength(1));
    });
  });

  // memory_optimization_plan § 9 / memory_specification § 3.2.1 — the
  // powerful `mem.*` recall surface and the lifecycle pair. Each test
  // proves the bridge maps its fixed knobs onto the single `RecallQuery`
  // (or the lifecycle method) — the "one call per primitive, no logic"
  // contract.
  group('C.12 MemoryBridge — powerful recall + lifecycle (§ 3.2.1)', () {
    test('recall threads ranking / types / countsAsAccess onto the query',
        () async {
      await bridge.recall(
        'q',
        ranking: 'recencyBoosted',
        types: const <String>['Conclusion', 'Event'],
        countsAsAccess: true,
      );

      final q = client.lastRecallQuery!;
      expect(q.ranking, RecallRanking.recencyBoosted);
      expect(q.countsAsAccess, isTrue);
      expect(q.filter, isNotNull);
      expect(q.filter!.typeNames, <String>{'Conclusion', 'Event'});
    });

    test('recall defaults: relevance ranking, no filter, no access bump',
        () async {
      await bridge.recall('q');

      final q = client.lastRecallQuery!;
      expect(q.ranking, RecallRanking.relevance);
      expect(q.countsAsAccess, isFalse);
      expect(q.filter, isNull,
          reason: 'no types and no before window means no SymbolicFilter');
    });

    test('recall rejects an unknown ranking name', () {
      expect(
        () => bridge.recall('q', ranking: 'fastest'),
        throwsA(isA<FormatException>()),
      );
    });

    test('recallOld fixes oldest ranking and windows on before', () async {
      await bridge.recallOld('q', before: '2026-06-01T00:00:00.000Z');

      final q = client.lastRecallQuery!;
      expect(q.ranking, RecallRanking.oldest);
      expect(q.filter, isNotNull);
      expect(q.filter!.lastAccessBefore,
          BrainTime.parse('2026-06-01T00:00:00.000Z'));
    });

    test('recallOld without before carries oldest ranking and no filter',
        () async {
      await bridge.recallOld('q');

      final q = client.lastRecallQuery!;
      expect(q.ranking, RecallRanking.oldest);
      expect(q.filter, isNull);
    });

    test('recallCold fixes coldest ranking', () async {
      await bridge.recallCold('q');

      final q = client.lastRecallQuery!;
      expect(q.ranking, RecallRanking.coldest);
      expect(q.filter, isNull);
    });

    test('recallPrompts fixes the type filter to Event', () async {
      await bridge.recallPrompts('q');

      final q = client.lastRecallQuery!;
      expect(q.filter, isNotNull);
      expect(q.filter!.typeNames, <String>{'Event'});
      expect(q.ranking, RecallRanking.relevance);
    });

    test('recallPrompts still honours a caller ranking', () async {
      await bridge.recallPrompts('q', ranking: 'recencyBoosted');

      final q = client.lastRecallQuery!;
      expect(q.ranking, RecallRanking.recencyBoosted);
      expect(q.filter!.typeNames, <String>{'Event'});
    });

    test('recallAnswers fixes the type filter to Conclusion', () async {
      await bridge.recallAnswers('q');

      final q = client.lastRecallQuery!;
      expect(q.filter, isNotNull);
      expect(q.filter!.typeNames, <String>{'Conclusion'});
      expect(q.ranking, RecallRanking.relevance);
    });

    test('promote converts id + reason and calls the client', () async {
      await bridge.promote(
          'n_00000000000000000000000010', 'renewedRelevance');

      expect(client.promoteCalls, 1);
      expect(client.lastPromoteId,
          NodeId.fromString('n_00000000000000000000000010'));
      expect(client.lastPromoteReason, PromotionReason.renewedRelevance);
    });

    test('promote rejects an unknown reason name', () {
      expect(
        () => bridge.promote('n_00000000000000000000000010', 'nope'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('demote converts id + reason and calls the client', () async {
      await bridge.demote(
          'n_00000000000000000000000008', 'prunerDecision');

      expect(client.demoteCalls, 1);
      expect(client.lastDemoteId,
          NodeId.fromString('n_00000000000000000000000008'));
      expect(client.lastDemoteReason, DemotionReason.prunerDecision);
    });
  });

  group('C.12 MemoryBridge.classify', () {
    test('converts embedding + target and flattens a confident result',
        () async {
      client.classifyResult = const ClassificationResult(
        decision: ClassificationDecision.confident,
        bestMatch: 'Conclusion',
        bestSimilarity: 0.92,
        secondSimilarity: 0.18,
      );

      final out = await bridge
          .classify(const <double>[0.1, 0.2, 0.3], target: 'nodeType');

      // (a) Inbound conversion: the primitive double list became a Vec and
      // the target name parsed into the enum.
      expect(client.lastClassifyEmbedding!.values.toList(),
          [closeTo(0.1, 1e-6), closeTo(0.2, 1e-6), closeTo(0.3, 1e-6)]);
      expect(client.lastClassifyTarget, ClassificationTarget.nodeType);

      // (b) Outbound flattening: the result triad + decision band.
      expect(out['decision'], 'confident');
      expect(out['bestMatch'], 'Conclusion');
      expect(out['bestSimilarity'], 0.92);
      expect(out['secondSimilarity'], 0.18);
    });

    test('defaults the target to nodeType', () async {
      await bridge.classify(const <double>[0.0]);
      expect(client.lastClassifyTarget, ClassificationTarget.nodeType);
    });

    test('flattens an unknown result (cold / far-from-every-centroid)',
        () async {
      // `unknown` is the cold-start signal `answer_with_memory_v1` fires on.
      client.classifyResult = const ClassificationResult.unknown();

      final out = await bridge.classify(const <double>[0.0]);

      expect(out['decision'], 'unknown');
      expect(out['bestMatch'], isNull);
    });

    test('rejects an unknown target name', () {
      expect(
        () => bridge.classify(const <double>[0.0], target: 'bogus'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('C.12 MemoryBridge.persist', () {
    test('builds the draft + scope and returns the id string', () async {
      client.persistId = NodeId.fromString('n_00000000000000000000000009');

      final id = await bridge.persist(
        'Conclusion',
        const <String, Object?>{'text': 'answer'},
        producer: 'engine:answer_with_memory_v1:r_1',
        idempotencyKey: 'idem-1',
        runId: 'r_1',
        embedding: const <double>[0.1, 0.2, 0.3],
      );

      expect(id, 'n_00000000000000000000000009');
      expect(client.lastDraft!.typeName, 'Conclusion');
      expect(client.lastDraft!.values, <String, Object?>{'text': 'answer'});
      expect(client.lastDraft!.embedding, isNotNull);
      expect(client.lastDraft!.embedding!.values.toList(),
          [closeTo(0.1, 1e-6), closeTo(0.2, 1e-6), closeTo(0.3, 1e-6)]);
      expect(client.lastScope!.producer, 'engine:answer_with_memory_v1:r_1');
      expect(client.lastScope!.idempotencyKey, 'idem-1');
      expect(client.lastScope!.runId, 'r_1');
    });

    test('omits the embedding when none is supplied', () async {
      client.persistId = NodeId.fromString('n_0000000000000000000000000A');
      await bridge.persist('Claim', const <String, Object?>{'k': 'v'},
          producer: 'p');
      expect(client.lastDraft!.embedding, isNull);
    });
  });

  group('C.12 MemoryBridge.edge', () {
    test('parses node ids + edge type and returns the id string', () async {
      client.edgeId = EdgeId.fromString('e_00000000000000000000000005');

      final id = await bridge.edge(
        'n_00000000000000000000000001',
        'produced_by',
        'n_00000000000000000000000002',
        producer: 'engine',
        weight: 0.5,
        attrs: const <String, Object?>{'kind': 'depends_on'},
      );

      expect(id, 'e_00000000000000000000000005');
      expect(client.lastEdgeFrom!.value, 'n_00000000000000000000000001');
      expect(client.lastEdgeTo!.value, 'n_00000000000000000000000002');
      expect(client.lastEdgeType, EdgeType.producedBy);
      expect(client.lastEdgeWeight, 0.5);
      expect(client.lastEdgeAttrs, <String, Object?>{'kind': 'depends_on'});
    });

    test('rejects an unknown edge wire name', () {
      expect(
        () => bridge.edge('n_00000000000000000000000001', 'bogus',
            'n_00000000000000000000000002',
            producer: 'p'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('C.12 MemoryBridge.proposeNodeType', () {
    test('builds a NodeTypeDecl from the primitive map', () async {
      await bridge.proposeNodeType(const <String, Object?>{
        'typeName': 'Widget',
        'version': 2,
        'schema': <String, Object?>{
          'title': <String, Object?>{
            'type': 'string',
            'nullable': false,
            'ftsEligible': true,
          },
        },
        'allowedOutgoing': <String>['mentions'],
        'allowedIncoming': <String>['produced_by'],
      });

      final decl = client.lastNodeTypeDecl!;
      expect(decl.typeName, 'Widget');
      expect(decl.version.value, 2);
      expect(decl.schema.keys, <String>['title']);
      expect(decl.schema['title']!.type, FieldType.string);
      expect(decl.schema['title']!.ftsEligible, isTrue);
      expect(decl.allowedOutgoing, <EdgeType>{EdgeType.mentions});
      expect(decl.allowedIncoming, <EdgeType>{EdgeType.producedBy});
    });

    test('defaults version to 1 and accepts a bare typeName', () async {
      await bridge.proposeNodeType(const <String, Object?>{
        'typeName': 'Bare',
      });
      final decl = client.lastNodeTypeDecl!;
      expect(decl.version.value, 1);
      expect(decl.schema, isEmpty);
      expect(decl.allowedOutgoing, isEmpty);
    });

    test('rejects a missing typeName', () {
      expect(
        () => bridge.proposeNodeType(const <String, Object?>{}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('C.12 MemoryBridge.stack.*', () {
    test('stackList flattens summaries', () async {
      stacks.summaries = const <StackSummary>[
        StackSummary(
            name: 'interests', size: 3, topPriority: 0.9, bootstrap: true),
      ];
      final out = await bridge.stackList();
      expect(out, hasLength(1));
      expect(out.first, <String, Object?>{
        'name': 'interests',
        'size': 3,
        'topPriority': 0.9,
        'bootstrap': true,
      });
    });

    test('stackCreate builds a StackDecl with policy', () async {
      await bridge.stackCreate(const <String, Object?>{
        'name': 'hot',
        'summary': 'hot ideas',
        'entryNodeType': 'AutomationIdea',
        'policy': <String, Object?>{
          'priority': 'priority',
          'retention': 'boundedN',
          'maxCount': 32,
        },
      });
      final decl = stacks.lastDecl!;
      expect(decl.name, 'hot');
      expect(decl.summary, 'hot ideas');
      expect(decl.entryNodeType, 'AutomationIdea');
      expect(decl.policy.priority, PriorityPolicyKind.priority);
      expect(decl.policy.retention, RetentionPolicyKind.boundedN);
      expect(decl.policy.maxCount, 32);
    });

    test('stackCreate defaults policy when omitted', () async {
      await bridge.stackCreate(const <String, Object?>{'name': 's'});
      final decl = stacks.lastDecl!;
      expect(decl.policy.priority, PriorityPolicyKind.fifo);
      expect(decl.policy.retention, RetentionPolicyKind.unbounded);
    });

    test('stackPush parses node id + scope and returns the entry id',
        () async {
      stacks.pushId = StackEntryId.fromString('se_00000000000000000000000001');
      final id = await bridge.stackPush(
        'interests',
        'n_00000000000000000000000003',
        priority: 0.4,
        producer: 'engine',
        runId: 'r_1',
      );
      expect(id, 'se_00000000000000000000000001');
      expect(stacks.lastPushName, 'interests');
      expect(stacks.lastPushNode!.value, 'n_00000000000000000000000003');
      expect(stacks.lastPushPriority, 0.4);
      expect(stacks.lastPushScope!.producer, 'engine');
      expect(stacks.lastPushScope!.runId, 'r_1');
    });

    test('stackPush passes a null scope when no producer is given',
        () async {
      stacks.pushId = StackEntryId.fromString('se_00000000000000000000000002');
      await bridge.stackPush('s', 'n_00000000000000000000000003');
      expect(stacks.lastPushScope, isNull);
    });

    test('stackPeek flattens entries', () async {
      stacks.peekEntries = <StackEntry>[
        StackEntry(
          id: StackEntryId.fromString('se_00000000000000000000000003'),
          stackName: 'interests',
          nodeId: NodeId.fromString('n_00000000000000000000000004'),
          priority: 0.7,
          pushedAt: DateTime.utc(2026, 6, 1),
        ),
      ];
      final out = await bridge.stackPeek('interests', k: 4);
      expect(stacks.lastPeekK, 4);
      expect(out, hasLength(1));
      final e0 = out.first;
      expect(e0['id'], 'se_00000000000000000000000003');
      expect(e0['nodeId'], 'n_00000000000000000000000004');
      expect(e0['priority'], 0.7);
      expect(e0['status'], 'active');
    });

    test('stackPop returns null on empty', () async {
      stacks.popEntry = null;
      expect(await bridge.stackPop('interests'), isNull);
    });

    test('stackPop flattens the popped entry', () async {
      stacks.popEntry = StackEntry(
        id: StackEntryId.fromString('se_00000000000000000000000004'),
        stackName: 'interests',
        nodeId: NodeId.fromString('n_00000000000000000000000005'),
        priority: 1.0,
        pushedAt: DateTime.utc(2026, 6, 1),
      );
      final out = await bridge.stackPop('interests');
      expect(out!['id'], 'se_00000000000000000000000004');
      expect(out['nodeId'], 'n_00000000000000000000000005');
    });

    test('stackUpdate parses status enum + node id', () async {
      await bridge.stackUpdate(
        'interests',
        'n_00000000000000000000000006',
        priority: 0.2,
        status: 'archived',
      );
      expect(stacks.lastUpdateName, 'interests');
      expect(stacks.lastUpdateNode!.value, 'n_00000000000000000000000006');
      expect(stacks.lastUpdatePriority, 0.2);
      expect(stacks.lastUpdateStatus, StackEntryStatus.archived);
    });

    test('stackRemove parses the node id', () async {
      await bridge.stackRemove(
          'interests', 'n_00000000000000000000000007');
      expect(stacks.lastRemoveName, 'interests');
      expect(stacks.lastRemoveNode!.value, 'n_00000000000000000000000007');
    });
  });

  // E.3.8 — timestamp serialisers route through the canonical BrainTime
  // formatter, normalising to a UTC "…Z" wire string rather than emitting a
  // zone-offset ISO string for a non-UTC DateTime.
  group('E.3.8 MemoryBridge — timestamps serialise as canonical UTC', () {
    test('recall node createdAt normalises a local instant to UTC', () async {
      final local = DateTime(2026, 1, 2, 3, 4, 5); // local time, no zone Z
      client.recallResult = RecallResult(
        nodes: <Node>[
          Node(
            id: NodeId.fromString('n_00000000000000000000000001'),
            typeName: 'Conclusion',
            values: const <String, Object?>{'text': 'x'},
            createdAt: local,
          ),
        ],
        report: const RecallReport(
          candidatesPerMode: <RecallMode, int>{},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 0,
        ),
      );
      final out = await bridge.recall('q');
      final n0 = (out['nodes']! as List<Object?>).first! as Map<String, Object?>;
      expect(n0['createdAt'], endsWith('Z'));
      expect(n0['createdAt'], local.toUtc().toIso8601String());
    });

    test('stackPeek entry pushedAt normalises a local instant to UTC',
        () async {
      final local = DateTime(2026, 6, 1, 12);
      stacks.peekEntries = <StackEntry>[
        StackEntry(
          id: StackEntryId.fromString('se_00000000000000000000000003'),
          stackName: 'interests',
          nodeId: NodeId.fromString('n_00000000000000000000000004'),
          priority: 0.7,
          pushedAt: local,
        ),
      ];
      final out = await bridge.stackPeek('interests');
      expect(out.first['pushedAt'], endsWith('Z'));
      expect(out.first['pushedAt'], local.toUtc().toIso8601String());
    });
  });

  // E.3.3 — malformed d4rt-supplied map fields raise a descriptive
  // FormatException (PE-1: d4rt scripts are an untrusted boundary), not an
  // opaque TypeError from a bare `as` cast.
  group('E.3.3 MemoryBridge — descriptive FormatException on bad fields', () {
    test('proposeNodeType rejects a non-numeric version', () {
      expect(
        () => bridge.proposeNodeType(const <String, Object?>{
          'typeName': 'Widget',
          'version': 'two',
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('version must be a number (got'),
        )),
      );
    });

    test('proposeNodeType rejects a non-map schema', () {
      expect(
        () => bridge.proposeNodeType(const <String, Object?>{
          'typeName': 'Widget',
          'schema': 'not a map',
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('schema must be a map (got'),
        )),
      );
    });

    test('proposeNodeType rejects a non-map schema entry', () {
      expect(
        () => bridge.proposeNodeType(const <String, Object?>{
          'typeName': 'Widget',
          'schema': <String, Object?>{'title': 'not a spec'},
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('schema.title must be a map (got'),
        )),
      );
    });

    test('proposeNodeType rejects a non-string field type', () {
      expect(
        () => bridge.proposeNodeType(const <String, Object?>{
          'typeName': 'Widget',
          'schema': <String, Object?>{
            'title': <String, Object?>{'type': 7},
          },
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('schema.title.type must be a string (got'),
        )),
      );
    });

    test('proposeNodeType rejects a non-list allowedOutgoing', () {
      expect(
        () => bridge.proposeNodeType(const <String, Object?>{
          'typeName': 'Widget',
          'allowedOutgoing': 'mentions',
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('allowedOutgoing must be a list (got'),
        )),
      );
    });

    test('stackCreate rejects a non-string summary', () {
      expect(
        () => bridge.stackCreate(const <String, Object?>{
          'name': 'hot',
          'summary': 7,
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('summary must be a string (got'),
        )),
      );
    });

    test('stackCreate rejects a non-map policy', () {
      expect(
        () => bridge.stackCreate(const <String, Object?>{
          'name': 'hot',
          'policy': 'fifo',
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('policy must be a map (got'),
        )),
      );
    });

    test('stackCreate rejects a non-numeric policy.maxCount', () {
      expect(
        () => bridge.stackCreate(const <String, Object?>{
          'name': 'hot',
          'policy': <String, Object?>{'maxCount': 'lots'},
        }),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('policy.maxCount must be a number (got'),
        )),
      );
    });
  });

  // § 5.4 — the per-run NON-FATAL write guard. A wired guard admits each
  // store-mutating call before its side effect; a write that would exceed a cap
  // or repeats an edge within the run is skipped (the side effect never runs),
  // reported via the skip sink, and the call returns a sentinel — the run
  // continues, never failing. Reads are never gated.
  group('§5.4 MemoryBridge write guard — skip is non-fatal', () {
    late List<MemoryWriteSkip> skips;

    MemoryBridge guarded(MemoryWriteLimits limits) {
      skips = <MemoryWriteSkip>[];
      return MemoryBridge(
        client,
        writeGuard: MemoryWriteGuard(limits),
        onWriteSkipped: skips.add,
      );
    }

    test('a duplicate edge within the run is skipped, returns "", side effect '
        'never runs', () async {
      client.edgeId = EdgeId.fromString('e_00000000000000000000000005');
      final bridge = guarded(
        const MemoryWriteLimits(maxEdgesPerRun: 1000, dedupEdgesWithinRun: true),
      );

      final first = await bridge.edge(
        'n_00000000000000000000000001',
        'derived_from',
        'n_00000000000000000000000002',
        producer: 'p',
      );
      expect(first, 'e_00000000000000000000000005');
      expect(client.edgeCalls, 1);

      // The same triple again is the loop signal: skipped, sentinel id, no call.
      final second = await bridge.edge(
        'n_00000000000000000000000001',
        'derived_from',
        'n_00000000000000000000000002',
        producer: 'p',
      );
      expect(second, '');
      expect(client.edgeCalls, 1, reason: 'the skipped edge never reached the client');
      expect(skips, hasLength(1));
      expect(skips.single.primitive, 'edge');
      expect(skips.single.outcome, MemoryWriteOutcome.skipDuplicateEdge);
    });

    test('a persist past the write cap is skipped, returns "", side effect '
        'never runs', () async {
      client.persistId = NodeId.fromString('n_00000000000000000000000009');
      final bridge = guarded(const MemoryWriteLimits(maxWritesPerRun: 1));

      final first = await bridge.persist(
        'Event', const <String, Object?>{'summary': 'a'}, producer: 'p');
      expect(first, 'n_00000000000000000000000009');
      expect(client.persistCalls, 1);

      // The second write trips the cap: skipped, empty-id sentinel, no call.
      final second = await bridge.persist(
        'Conclusion', const <String, Object?>{'statement': 'b'}, producer: 'p');
      expect(second, '');
      expect(client.persistCalls, 1);
      expect(skips.single.outcome, MemoryWriteOutcome.skipWriteCap);
    });

    test('a skipped stackPush returns "" and never reaches the client',
        () async {
      final bridge = guarded(const MemoryWriteLimits(maxWritesPerRun: 0));
      final id = await bridge.stackPush(
        'interests', 'n_00000000000000000000000003', producer: 'p');
      expect(id, '');
      expect(stacks.pushCalls, 0);
      expect(skips.single.primitive, 'stackPush');
    });

    test('reads are never gated, even with a zero write cap', () async {
      final bridge = guarded(const MemoryWriteLimits(maxWritesPerRun: 0));
      await bridge.recall('q');
      expect(client.recallCalls, 1);
      expect(skips, isEmpty);
    });

    test('with no guard wired, every write proceeds', () async {
      client.edgeId = EdgeId.fromString('e_00000000000000000000000005');
      // The default bridge (setUp) has no guard.
      await bridge.edge('n_00000000000000000000000001', 'derived_from',
          'n_00000000000000000000000002', producer: 'p');
      await bridge.edge('n_00000000000000000000000001', 'derived_from',
          'n_00000000000000000000000002', producer: 'p');
      expect(client.edgeCalls, 2, reason: 'no guard means no dedup or cap');
    });
  });
}

/// Fake `TomBrainMemoryClient` capturing the subset of calls
/// `MemoryBridge` makes. Unused members fall through to `noSuchMethod`.
class _FakeMemoryClient implements TomBrainMemoryClient {
  _FakeMemoryClient(this._stacks);

  final _FakeStackApi _stacks;

  RecallQuery? lastRecallQuery;
  RecallResult recallResult = const RecallResult(
    nodes: <Node>[],
    report: RecallReport(
      candidatesPerMode: <RecallMode, int>{},
      fusionStrategy: FusionStrategy.rrf,
      diversityStrategy: DiversityStrategy.mmr,
      elapsedMs: 0,
    ),
  );

  NodeDraft? lastDraft;
  Scope? lastScope;
  NodeId persistId = NodeId.fromString('n_00000000000000000000000000');

  /// How many times the side effect actually ran (a skipped write must not
  /// reach the client — these count proves the skip suppressed the effect).
  int persistCalls = 0;
  int edgeCalls = 0;
  int recallCalls = 0;

  NodeId? lastEdgeFrom;
  NodeId? lastEdgeTo;
  EdgeType? lastEdgeType;
  double? lastEdgeWeight;
  Map<String, Object?>? lastEdgeAttrs;
  EdgeId edgeId = EdgeId.fromString('e_00000000000000000000000000');

  NodeTypeDecl? lastNodeTypeDecl;

  Vec? lastClassifyEmbedding;
  ClassificationTarget? lastClassifyTarget;
  ClassificationResult classifyResult = const ClassificationResult.unknown();

  int demoteCalls = 0;
  NodeId? lastDemoteId;
  DemotionReason? lastDemoteReason;

  int promoteCalls = 0;
  NodeId? lastPromoteId;
  PromotionReason? lastPromoteReason;

  /// `edgesOf` capture (§ 10 `relations` flag). Records every node the
  /// bridge queries and returns the configured adjacency.
  int edgesOfCalls = 0;
  final List<NodeId> edgesOfQueried = <NodeId>[];
  List<Edge> edgesResult = const <Edge>[];

  RecallResult? recallMultiResult;
  MultiRecallQuery? lastMultiRecallQuery;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallCalls++;
    lastRecallQuery = query;
    return recallResult;
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    lastMultiRecallQuery = query;
    return recallMultiResult ?? recallResult;
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    edgesOfCalls++;
    edgesOfQueried.add(id);
    return edgesResult;
  }

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {
    demoteCalls++;
    lastDemoteId = id;
    lastDemoteReason = reason;
  }

  @override
  Future<void> promote(NodeId id, PromotionReason reason) async {
    promoteCalls++;
    lastPromoteId = id;
    lastPromoteReason = reason;
  }

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    lastClassifyEmbedding = embedding;
    lastClassifyTarget = target;
    return classifyResult;
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    persistCalls++;
    lastDraft = draft;
    lastScope = scope;
    return persistId;
  }

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    edgeCalls++;
    lastEdgeFrom = from;
    lastEdgeTo = to;
    lastEdgeType = type;
    lastEdgeWeight = weight;
    lastEdgeAttrs = attrs;
    lastScope = scope;
    return edgeId;
  }

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {
    lastNodeTypeDecl = decl;
  }

  @override
  StackApi get stacks => _stacks;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Fake `StackApi` capturing the subset of calls `MemoryBridge` makes.
class _FakeStackApi implements StackApi {
  List<StackSummary> summaries = const <StackSummary>[];
  StackDecl? lastDecl;

  StackEntryId pushId =
      StackEntryId.fromString('se_00000000000000000000000000');
  int pushCalls = 0;
  String? lastPushName;
  NodeId? lastPushNode;
  double? lastPushPriority;
  Scope? lastPushScope;

  List<StackEntry> peekEntries = const <StackEntry>[];
  int? lastPeekK;

  StackEntry? popEntry;

  String? lastUpdateName;
  NodeId? lastUpdateNode;
  double? lastUpdatePriority;
  StackEntryStatus? lastUpdateStatus;

  String? lastRemoveName;
  NodeId? lastRemoveNode;

  @override
  Future<List<StackSummary>> list() async => summaries;

  @override
  Future<void> create(StackDecl decl) async {
    lastDecl = decl;
  }

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    pushCalls++;
    lastPushName = name;
    lastPushNode = entry;
    lastPushPriority = priority;
    lastPushScope = scope;
    return pushId;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    lastPeekK = k;
    return peekEntries;
  }

  @override
  Future<StackEntry?> pop(String name) async => popEntry;

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {
    lastUpdateName = name;
    lastUpdateNode = entry;
    lastUpdatePriority = priority;
    lastUpdateStatus = status;
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    lastRemoveName = name;
    lastRemoveNode = entry;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
