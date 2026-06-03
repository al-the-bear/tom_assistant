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
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
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

  NodeId? lastEdgeFrom;
  NodeId? lastEdgeTo;
  EdgeType? lastEdgeType;
  double? lastEdgeWeight;
  Map<String, Object?>? lastEdgeAttrs;
  EdgeId edgeId = EdgeId.fromString('e_00000000000000000000000000');

  NodeTypeDecl? lastNodeTypeDecl;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    lastRecallQuery = query;
    return recallResult;
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
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
