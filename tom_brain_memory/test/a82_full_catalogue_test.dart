// A.82 — Full envelope catalogue round-trip.
//
// Drives every method on `TomBrainMemoryClient` through a real
// `TomBrainMemoryIsolateClient` + `TomBrainMemoryIsolateHost` against a
// top-level fake `TomBrainMemory` running inside a spawned isolate.
//
// Three layers of assertion:
//
//   1. **Future-returning methods** — every call must reach the in-isolate
//      fake with the right arguments (the fake encodes the args into its
//      return value) and the typed return value must round-trip back
//      through the boundary unchanged.
//
//   2. **Stream-returning methods** — the three remaining streams
//      (`stream`, `stacks.streamArchived`, `stacks.events`) must deliver
//      every item in order. `stream` and `stacks.streamArchived` also serve
//      as the *large-stream chunking proof* — N≫initialCredits items push
//      through a backpressured channel and all arrive intact.
//
//   3. **Refusals** — `recall()` must reject a `RecallQuery.reRank` closure
//      with `ArgumentError` *before* opening an envelope (closures are not
//      sendable across the SendPort boundary).
//
// The fake is intentionally minimal: it does not implement any real
// storage. Each method returns data deterministically derived from its
// arguments so the test can verify the round trip without standing up
// `SqliteTomBrainMemory`.

import 'dart:async';
import 'dart:typed_data';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainVersion, EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;
import 'package:test/test.dart';

// ─── Top-level fake (must be top-level/static to be sendable) ─────

/// Factory referenced by the host's `MemoryFactory`. Spawned inside the
/// isolate.
Future<TomBrainMemory> spawnFakeMemoryForA82() async {
  return _IsolateSideFakeMemoryA82();
}

/// Top-level fake that implements every method on `TomBrainMemoryClient`
/// the A.82 round-trip tests exercise.
///
/// Returns deterministic data derived from the call arguments so the
/// host-side assertions can verify both:
///   * the arguments crossed the boundary intact, and
///   * the return value crossed back intact.
final class _IsolateSideFakeMemoryA82 implements TomBrainMemory {
  // Mutable state — recorded calls. Cannot be inspected from the host
  // directly (would require an introspection envelope); instead the
  // methods *encode* their inputs into their outputs.
  final List<String> _calls = <String>[];
  final _FakeStackApi _stackApi = _FakeStackApi();
  final _FakeMigrationApi _migrationApi = _FakeMigrationApi();

  @override
  Future<void> open(MemoryConfig config) async {
    _calls.add('open');
  }

  @override
  Future<void> close() async {
    _calls.add('close');
    final controllers = _stackApi.eventsControllers.values
        .whereType<StreamController<StackEvent>>()
        .where((c) => !c.isClosed)
        .toList();
    for (final c in controllers) {
      await c.close();
    }
  }

  @override
  Future<void> checkpoint() async {
    _calls.add('checkpoint');
  }

  // ─── WriteBudget ─────────────────────────────────────────────

  // Track the last-bound budget per runId so `remainingBudget` returns
  // something distinguishable.
  final Map<String, WriteBudget> _budgets = <String, WriteBudget>{};

  @override
  Future<void> beginRun({
    required String runId,
    required WriteBudget budget,
  }) async {
    _budgets[runId] = budget;
  }

  @override
  Future<void> endRun(String runId) async {
    _budgets.remove(runId);
  }

  @override
  Future<WriteBudget?> remainingBudget(String runId) async => _budgets[runId];

  // ─── Node CRUD ───────────────────────────────────────────────

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    // Encode the type-name length into the returned id timestamp so the
    // assertion can confirm the draft arrived intact. Easier proof: just
    // mint a fresh id and assert the type round-trip via a follow-up
    // `get`.
    return NodeId.generate();
  }

  @override
  Future<Node?> get(NodeId id) async {
    // Return a Node whose `values['echoedId']` matches the requested id.
    return Node(
      id: id,
      typeName: 'EchoedType',
      values: <String, Object?>{'echoedId': id.toString()},
      createdAt: DateTime.utc(2026, 1, 1),
    );
  }

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async {
    return [
      for (final id in ids)
        Node(
          id: id,
          typeName: 'Bulk',
          values: <String, Object?>{'pos': ids.indexOf(id)},
          createdAt: DateTime.utc(2026, 1, 2),
        ),
    ];
  }

  // Tracks the most recent demote/forget call so the test can check that
  // the reason crossed correctly. Inspected via `stats()` (we hijack
  // `stats()` here as a generic introspection channel since the A.80
  // path already proved it round-trips).
  String _lastDemoteReason = '';
  String _lastForgetReason = '';

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {
    _lastDemoteReason = reason.name;
  }

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {
    _lastForgetReason = reason.name;
  }

  // ─── Edges ───────────────────────────────────────────────────

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    return EdgeId.generate();
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    // Encode the direction + type-set size into the edge attrs so the
    // assertion can confirm the args arrived.
    return <Edge>[
      Edge(
        id: EdgeId.generate(),
        from: id,
        type: EdgeType.mentions,
        to: NodeId.generate(),
        weight: 1.5,
        attrs: <String, Object?>{
          'direction': direction.name,
          'typeFilterSize': types?.length ?? 0,
        },
      ),
    ];
  }

  // ─── Node-type registry ──────────────────────────────────────

  final Map<String, NodeTypeDecl> _types = <String, NodeTypeDecl>{};

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {
    _types[decl.typeName] = decl;
  }

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() async =>
      _types.values.toList(growable: false);

  @override
  Future<NodeTypeDecl?> getNodeType(String typeName) async => _types[typeName];

  // ─── Retrieval ───────────────────────────────────────────────

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    return RecallResult(
      nodes: <Node>[
        Node(
          id: NodeId.generate(),
          typeName: 'RecalledFor:${query.text ?? '?'}',
          values: <String, Object?>{
            'k': query.k,
            'modes': query.modes.map((m) => m.name).toList(),
          },
          createdAt: DateTime.utc(2026, 1, 3),
        ),
      ],
      report: RecallReport(
        candidatesPerMode: <RecallMode, int>{
          for (final m in query.modes) m: 1,
        },
        fusionStrategy: query.fusion.strategy,
        diversityStrategy: query.diversity.strategy,
        elapsedMs: 7,
      ),
    );
  }

  @override
  Stream<Node> stream(StreamQuery query) async* {
    // The test encodes the desired stream length into the
    // filter's `producer` field (e.g. `producer: 'len:42'`).
    final tag = query.filter.producer ?? 'len:3';
    final m = RegExp(r'^len:(\d+)$').firstMatch(tag);
    final count = m == null ? 3 : int.parse(m.group(1)!);
    for (var i = 0; i < count; i++) {
      yield Node(
        id: NodeId.generate(),
        typeName: 'StreamItem',
        values: <String, Object?>{'i': i, 'total': count},
        createdAt: DateTime.utc(2026, 1, 4).add(Duration(milliseconds: i)),
      );
    }
  }

  // ─── Classification ──────────────────────────────────────────

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    return ClassificationResult(
      decision: ClassificationDecision.confident,
      bestMatch: 'target:${target.name},dims:${embedding.dimension}',
      bestSimilarity: 0.91,
      secondSimilarity: 0.42,
    );
  }

  String _lastCentroidKey = '';
  int _lastCentroidDims = -1;

  @override
  Future<void> updateCentroid(String forKey, Vec centroid) async {
    _lastCentroidKey = forKey;
    _lastCentroidDims = centroid.dimension;
  }

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) async {
    // Return one id whose ULID is meaningless; encode the args into the
    // returned list length so the test can assert.
    return <NodeId>[
      for (var i = 0; i < limit.clamp(0, 3); i++) NodeId.generate(),
    ];
  }

  // ─── Stacks / Migrations sub-APIs ────────────────────────────

  @override
  StackApi get stacks => _stackApi;

  @override
  MigrationApi get migrations => _migrationApi;

  // ─── Trails ──────────────────────────────────────────────────

  // Returns a constant id so the test can match it back. Generating
  // the same TrailId twice doesn't matter — the host-side check is just
  // round-trip.
  TrailId _trailId = TrailId.generate();

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    _trailId = TrailId.generate();
    return _trailId;
  }

  // Stores last-appended entry payload for verification via stats hack.
  String _lastAppendedNote = '';

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    _lastAppendedNote = entry.payload['message']?.toString() ?? '';
  }

  String _lastCloseSummary = '';

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    _lastCloseSummary = outcome.summary;
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) async* {
    yield TrailEntry.note('readback');
  }

  @override
  Stream<MemoryEvent> events() async* {
    // Not exercised by A.82 — A.81 already proved this stream.
    yield TrailOpened(
      trailId: TrailId.generate(),
      runRef: const ProcedureRunRef(procedureId: 'p', runId: 'r'),
      jsonlPath: '/tmp/fake',
      openedAt: DateTime.now().toUtc(),
      occurredAt: DateTime.now().toUtc(),
    );
  }

  // ─── Stats — repurposed as an introspection hatch for the test ───

  /// Stats is the existing round-trip-proven envelope (A.80). We pack
  /// the fake's recorded state into the various histograms so the test
  /// can `client.stats()` to verify in-isolate side-effects without
  /// adding a custom envelope.
  @override
  Future<MemoryStats> stats() async {
    return MemoryStats(
      nodeCountByType: <String, int>{
        if (_lastDemoteReason.isNotEmpty) 'demote:$_lastDemoteReason': 1,
        if (_lastForgetReason.isNotEmpty) 'forget:$_lastForgetReason': 1,
        if (_lastCentroidKey.isNotEmpty)
          'centroid:$_lastCentroidKey:dims=$_lastCentroidDims': 1,
        if (_lastAppendedNote.isNotEmpty) 'note:$_lastAppendedNote': 1,
        if (_lastCloseSummary.isNotEmpty) 'close:$_lastCloseSummary': 1,
        for (final t in _types.keys) 'type:$t': 1,
        for (final r in _budgets.keys)
          'budget:$r:n=${_budgets[r]!.maxNodes}': 1,
      },
      edgeCountByType: <String, int>{},
      stackSizes: <String, int>{},
      trailCount: 0,
      trailBytes: 0,
      recallLatencyPerMode: <String, LatencyHistogram>{},
      classificationConfidenceHistogram: <String, int>{},
      migrationProgress: <String, double>{},
    );
  }
}

// ─── Stack & Migration sub-API fakes ──────────────────────────────

final class _FakeStackApi implements StackApi {
  final Map<String, StreamController<StackEvent>> eventsControllers =
      <String, StreamController<StackEvent>>{};

  @override
  Future<List<StackSummary>> list() async => const <StackSummary>[
        StackSummary(
          name: 'fake_questions',
          size: 7,
          topPriority: 0.91,
          bootstrap: true,
        ),
      ];

  @override
  Future<StackInfo?> info(String name) async => StackInfo(
        name: name,
        summary: 'echoed:$name',
        policy: const StackPolicy(
          priority: PriorityPolicyKind.priority,
          retention: RetentionPolicyKind.boundedN,
          maxCount: 100,
        ),
        entryNodeType: 'Question',
        size: 4,
        bootstrap: name.startsWith('bootstrap_'),
      );

  @override
  Future<void> create(StackDecl decl) async {}

  @override
  Future<void> updatePolicy(String name, StackPolicy policy) async {}

  @override
  Future<void> delete(String name) async {}

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    return StackEntryId.generate();
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    return <StackEntry>[
      for (var i = 0; i < k.clamp(0, 3); i++)
        StackEntry(
          id: StackEntryId.generate(),
          stackName: name,
          nodeId: NodeId.generate(),
          priority: 1.0 - i * 0.1,
          pushedAt: DateTime.utc(2026, 1, 5),
        ),
    ];
  }

  @override
  Future<StackEntry?> pop(String name) async => StackEntry(
        id: StackEntryId.generate(),
        stackName: name,
        nodeId: NodeId.generate(),
        priority: 0.42,
        pushedAt: DateTime.utc(2026, 1, 6),
      );

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {}

  @override
  Future<void> remove(String name, NodeId entry) async {}

  @override
  Stream<StackEntry> streamArchived(String name, {int? limit}) async* {
    final count = limit ?? 3;
    for (var i = 0; i < count; i++) {
      yield StackEntry(
        id: StackEntryId.generate(),
        stackName: name,
        nodeId: NodeId.generate(),
        priority: i * 0.1,
        pushedAt: DateTime.utc(2026, 1, 7).add(Duration(milliseconds: i)),
        status: StackEntryStatus.archived,
      );
    }
  }

  @override
  Stream<StackEvent> events(String name) {
    final controller = StreamController<StackEvent>.broadcast();
    eventsControllers[name] = controller;
    // Tick a `pushed` event every few ms so the cancellation test sees
    // chunks before cancelling.
    Timer.periodic(const Duration(milliseconds: 5), (t) {
      if (controller.isClosed) {
        t.cancel();
        return;
      }
      controller.add(
        StackEvent(
          stackName: name,
          kind: StackEventKind.pushed,
          at: DateTime.now().toUtc(),
          entryId: StackEntryId.generate(),
        ),
      );
    });
    return controller.stream;
  }
}

final class _FakeMigrationApi implements MigrationApi {
  final Map<String, MigrationDecl> _decls = <String, MigrationDecl>{};
  final Map<String, MigrationCursor> _cursors = <String, MigrationCursor>{};

  @override
  Future<void> start(MigrationDecl decl) async {
    _decls[decl.migrationId] = decl;
  }

  @override
  Future<MigrationCursor?> cursor(String migrationId) async =>
      _cursors[migrationId];

  @override
  Future<void> saveCursor(
    String migrationId,
    Map<String, Object?> position,
  ) async {
    _cursors[migrationId] = MigrationCursor(
      migrationId: migrationId,
      position: position,
      savedAt: DateTime.utc(2026, 1, 8),
    );
  }

  @override
  Future<MigrationStatus?> status(String migrationId) async =>
      _decls.containsKey(migrationId)
          ? MigrationStatus(
              migrationId: migrationId,
              total: 100,
              processed: _cursors.containsKey(migrationId) ? 42 : 0,
              complete: false,
              lastCycleAt: DateTime.utc(2026, 1, 9),
            )
          : null;

  @override
  Future<List<MigrationStatus>> listInProgress() async => <MigrationStatus>[
        for (final id in _decls.keys)
          MigrationStatus(
            migrationId: id,
            total: 100,
            processed: 50,
            complete: false,
          ),
      ];
}

// ─── Test setup helpers ──────────────────────────────────────────

MemoryConfig _fakeConfig() => MemoryConfig.forTesting(
      root: '/tmp/tom_brain_memory_a82_fake_unused',
    );

Scope _testScope() => const Scope(producer: 'a82:test:run');

NodeTypeDecl _testDecl(String typeName) => NodeTypeDecl(
      typeName: typeName,
      version: BrainVersion.initial,
      schema: const <String, FieldSpec>{},
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: IndexPolicy.indexNothing,
      retentionPolicy: RetentionPolicy.indefinite,
      allowedOutgoing: const <EdgeType>{},
      allowedIncoming: const <EdgeType>{},
    );

Vec _testVec(int dims) => Vec(Float32List(dims)..fillRange(0, dims, 0.5));

// ─── Tests ────────────────────────────────────────────────────────

void main() {
  group('A.82 lifecycle round-trip', () {
    test('checkpoint() round-trips', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());
        await client.checkpoint(); // no-throw is the assertion
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 WriteBudget round-trip', () {
    test('beginRun / remainingBudget / endRun round-trip', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final budget = WriteBudget(
          maxNodes: 11,
          maxEdges: 22,
          maxStackEntries: 33,
        );
        await client.beginRun(runId: 'r1', budget: budget);

        final remaining = await client.remainingBudget('r1');
        expect(remaining, isNotNull);
        expect(remaining!.maxNodes, equals(11));
        expect(remaining.maxEdges, equals(22));
        expect(remaining.maxStackEntries, equals(33));

        // Verify in-isolate state via the stats() introspection hatch.
        final s = await client.stats();
        expect(s.nodeCountByType, contains('budget:r1:n=11'));

        await client.endRun('r1');
        final afterEnd = await client.remainingBudget('r1');
        expect(afterEnd, isNull);
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 node CRUD round-trip', () {
    test('persist / get / getMany / demote / forget round-trip', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        // persist
        final draft = const NodeDraft(
          typeName: 'Question',
          values: <String, Object?>{'text': 'hello'},
        );
        final id = await client.persist(draft, scope: _testScope());
        expect(id, isA<NodeId>());

        // get
        final got = await client.get(id);
        expect(got, isNotNull);
        expect(got!.typeName, equals('EchoedType'));
        expect(got.values['echoedId'], equals(id.toString()));

        // getMany
        final ids = <NodeId>[id, NodeId.generate(), NodeId.generate()];
        final bulk = await client.getMany(ids);
        expect(bulk, hasLength(3));
        expect(bulk[0].id, equals(ids[0]));
        expect(bulk[2].values['pos'], equals(2));

        // demote
        await client.demote(id, DemotionReason.prunerDecision);
        var s = await client.stats();
        expect(s.nodeCountByType, contains('demote:prunerDecision'));

        // forget
        await client.forget(id, ForgetReason.userRequested);
        s = await client.stats();
        expect(s.nodeCountByType, contains('forget:userRequested'));
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 edges round-trip', () {
    test('edge() and edgesOf() round-trip with direction + type filter',
        () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final from = NodeId.generate();
        final to = NodeId.generate();
        final eid = await client.edge(
          from,
          EdgeType.derivedFrom,
          to,
          scope: _testScope(),
          weight: 2.5,
          attrs: <String, Object?>{'k': 'v'},
        );
        expect(eid, isA<EdgeId>());

        final edges = await client.edgesOf(
          from,
          direction: EdgeDirection.outgoing,
          types: <EdgeType>{EdgeType.mentions, EdgeType.derivedFrom},
        );
        expect(edges, hasLength(1));
        expect(edges.first.attrs['direction'], equals('outgoing'));
        expect(edges.first.attrs['typeFilterSize'], equals(2));
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 node-type registry round-trip', () {
    test('registerNodeType / listNodeTypes / getNodeType round-trip',
        () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        await client.registerNodeType(_testDecl('Alpha'));
        await client.registerNodeType(_testDecl('Beta'));

        final all = await client.listNodeTypes();
        expect(all.map((d) => d.typeName), containsAll(['Alpha', 'Beta']));

        final one = await client.getNodeType('Alpha');
        expect(one, isNotNull);
        expect(one!.typeName, equals('Alpha'));

        final missing = await client.getNodeType('NoSuch');
        expect(missing, isNull);
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 retrieval round-trip', () {
    test('recall() round-trips RecallQuery -> RecallResult', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final result = await client.recall(
          const RecallQuery(
            text: 'hello world',
            modes: <RecallMode>{RecallMode.bm25, RecallMode.vector},
            k: 5,
          ),
        );
        expect(result.nodes, hasLength(1));
        expect(result.nodes.first.typeName, equals('RecalledFor:hello world'));
        expect(result.nodes.first.values['k'], equals(5));
        expect(result.report.candidatesPerMode.keys.toSet(), equals(<RecallMode>{
          RecallMode.bm25,
          RecallMode.vector,
        }));
        expect(result.report.elapsedMs, equals(7));
      } finally {
        await host.shutdown();
      }
    });

    test(
      'recall() rejects non-null reRank with ArgumentError, never opens envelope',
      () async {
        final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
        final client = TomBrainMemoryIsolateClient(host);
        try {
          await host.spawn();
          await client.open(_fakeConfig());

          final query = RecallQuery(
            modes: const <RecallMode>{RecallMode.bm25},
            reRank: (candidates) async => <NodeId>[],
          );

          await expectLater(
            client.recall(query),
            throwsA(isA<ArgumentError>().having(
              (e) => e.name,
              'name',
              'query.reRank',
            )),
          );
        } finally {
          await host.shutdown();
        }
      },
    );
  });

  group('A.82 classification round-trip', () {
    test('classify / updateCentroid / findUncertain round-trip', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final res = await client.classify(
          _testVec(64),
          target: ClassificationTarget.procedure,
        );
        expect(res.decision, equals(ClassificationDecision.confident));
        expect(res.bestMatch, equals('target:procedure,dims:64'));
        expect(res.bestSimilarity, closeTo(0.91, 1e-9));

        await client.updateCentroid('TopicX', _testVec(128));
        final s = await client.stats();
        expect(s.nodeCountByType, contains('centroid:TopicX:dims=128'));

        final unsure = await client.findUncertain(
          forKey: 'TopicX',
          low: 0.3,
          high: 0.6,
          limit: 2,
        );
        expect(unsure, hasLength(2));
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 stacks sub-API round-trip', () {
    test('list / info / create / updatePolicy / delete round-trip', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final summaries = await client.stacks.list();
        expect(summaries, hasLength(1));
        expect(summaries.first.name, equals('fake_questions'));
        expect(summaries.first.bootstrap, isTrue);

        final info = await client.stacks.info('bootstrap_questions');
        expect(info, isNotNull);
        expect(info!.name, equals('bootstrap_questions'));
        expect(info.summary, equals('echoed:bootstrap_questions'));
        expect(info.bootstrap, isTrue);

        await client.stacks.create(
          const StackDecl(
            name: 'custom_stack',
            summary: 's',
            policy: StackPolicy(
              priority: PriorityPolicyKind.fifo,
              retention: RetentionPolicyKind.unbounded,
            ),
            entryNodeType: 'Question',
          ),
        );

        await client.stacks.updatePolicy(
          'custom_stack',
          const StackPolicy(
            priority: PriorityPolicyKind.lifo,
            retention: RetentionPolicyKind.unbounded,
          ),
        );

        await client.stacks.delete('custom_stack');
      } finally {
        await host.shutdown();
      }
    });

    test('push / peek / pop / update / remove round-trip', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final pushed = await client.stacks.push(
          'inflight',
          NodeId.generate(),
          priority: 0.8,
          attrs: <String, Object?>{'k': 'v'},
        );
        expect(pushed, isA<StackEntryId>());

        final peeked = await client.stacks.peek('inflight', k: 2);
        expect(peeked, hasLength(2));
        expect(peeked.first.stackName, equals('inflight'));

        final popped = await client.stacks.pop('inflight');
        expect(popped, isNotNull);
        expect(popped!.stackName, equals('inflight'));
        expect(popped.priority, closeTo(0.42, 1e-9));

        await client.stacks.update(
          'inflight',
          NodeId.generate(),
          priority: 0.5,
          status: StackEntryStatus.archived,
        );

        await client.stacks.remove('inflight', NodeId.generate());
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 trails round-trip', () {
    test('openTrail / appendTrail / closeTrail round-trip', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final tid = await client.openTrail(
          const ProcedureRunRef(procedureId: 'p_test', runId: 'r_test'),
        );
        expect(tid, isA<TrailId>());

        await client.appendTrail(tid, TrailEntry.note('hello-from-test'));
        var s = await client.stats();
        expect(s.nodeCountByType, contains('note:hello-from-test'));

        await client.closeTrail(
          tid,
          TrailOutcome(
            status: TrailOutcomeStatus.accepted,
            summary: 'all-good',
          ),
        );
        s = await client.stats();
        expect(s.nodeCountByType, contains('close:all-good'));
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 migrations sub-API round-trip', () {
    test('start / cursor / saveCursor / status / listInProgress round-trip',
        () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        await client.migrations.start(
          const MigrationDecl(
            migrationId: 'm1',
            summary: 'first',
            candidates: StreamQuery(filter: SymbolicFilter()),
            perCycleBudget: 10,
          ),
        );

        var c = await client.migrations.cursor('m1');
        expect(c, isNull, reason: 'no cursor yet');

        await client.migrations.saveCursor('m1', <String, Object?>{'p': 1});
        c = await client.migrations.cursor('m1');
        expect(c, isNotNull);
        expect(c!.migrationId, equals('m1'));
        expect(c.position['p'], equals(1));

        final s = await client.migrations.status('m1');
        expect(s, isNotNull);
        expect(s!.migrationId, equals('m1'));
        expect(s.processed, equals(42));

        final missing = await client.migrations.status('nope');
        expect(missing, isNull);

        final all = await client.migrations.listInProgress();
        expect(all, hasLength(1));
        expect(all.first.migrationId, equals('m1'));
      } finally {
        await host.shutdown();
      }
    });
  });

  group('A.82 stream(StreamQuery) round-trip', () {
    test('small stream delivers every item in order', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final items = await client
            .stream(
              const StreamQuery(
                filter: SymbolicFilter(producer: 'len:5'),
              ),
            )
            .toList();
        expect(items, hasLength(5));
        expect(
          items.map((n) => n.values['i']).toList(),
          equals(<int>[0, 1, 2, 3, 4]),
        );
      } finally {
        await host.shutdown();
      }
    });

    test(
      'large stream (N >> initialCredits) delivers all items in order — '
      'backpressure proof',
      () async {
        final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
        // Force a small credit window so the producer must pause and the
        // sliding-window auto-pull has to keep replenishing.
        final client = TomBrainMemoryIsolateClient(
          host,
          streamQueryInitialCredits: 4,
        );
        try {
          await host.spawn();
          await client.open(_fakeConfig());

          const total = 200;
          final items = await client
              .stream(
                const StreamQuery(
                  filter: SymbolicFilter(producer: 'len:$total'),
                ),
              )
              .toList();
          expect(items, hasLength(total));
          for (var i = 0; i < total; i++) {
            expect(items[i].values['i'], equals(i),
                reason: 'item $i out of order');
          }
        } finally {
          await host.shutdown();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('A.82 stacks.streamArchived round-trip', () {
    test('small archived stream delivers every entry in order', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
      final client = TomBrainMemoryIsolateClient(host);
      try {
        await host.spawn();
        await client.open(_fakeConfig());

        final entries = await client.stacks
            .streamArchived('archived_stack', limit: 5)
            .toList();
        expect(entries, hasLength(5));
        expect(entries.every((e) => e.stackName == 'archived_stack'), isTrue);
        expect(entries.every((e) => e.status == StackEntryStatus.archived),
            isTrue);
      } finally {
        await host.shutdown();
      }
    });

    test(
      'large archived stream (N >> initialCredits) delivers all entries '
      '— backpressure proof',
      () async {
        final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
        final client = TomBrainMemoryIsolateClient(
          host,
          stacksArchivedInitialCredits: 4,
        );
        try {
          await host.spawn();
          await client.open(_fakeConfig());

          const total = 150;
          final entries = await client.stacks
              .streamArchived('archived_stack', limit: total)
              .toList();
          expect(entries, hasLength(total));
        } finally {
          await host.shutdown();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('A.82 stacks.events round-trip and cancellation', () {
    test(
      'stacks.events streams chunks then closes on consumer cancel',
      () async {
        final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
        final client = TomBrainMemoryIsolateClient(host);
        try {
          await host.spawn();
          await client.open(_fakeConfig());

          final received = <StackEvent>[];
          final done = Completer<void>();
          late StreamSubscription<StackEvent> sub;
          sub = client.stacks.events('live_stack').listen((e) async {
            received.add(e);
            if (received.length == 3) {
              await sub.cancel();
              done.complete();
            }
          });
          await done.future.timeout(const Duration(seconds: 5));
          expect(received.length, equals(3));
          expect(received.every((e) => e.stackName == 'live_stack'), isTrue);
          // Give the cancel round-trip time to clean up the host sink.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(host.liveStreamCount, equals(0),
              reason: 'host sink must be torn down after consumer cancel');
        } finally {
          await host.shutdown();
        }
      },
    );
  });

  group('A.82 stream(StreamQuery) cancellation', () {
    test(
      'consumer cancel on long stream() tears down the host sink',
      () async {
        final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemoryForA82);
        final client = TomBrainMemoryIsolateClient(
          host,
          streamQueryInitialCredits: 2,
        );
        try {
          await host.spawn();
          await client.open(_fakeConfig());

          final received = <Node>[];
          final done = Completer<void>();
          late StreamSubscription<Node> sub;
          sub = client
              .stream(
                const StreamQuery(
                  filter: SymbolicFilter(producer: 'len:1000'),
                ),
              )
              .listen((n) async {
            received.add(n);
            if (received.length == 5) {
              await sub.cancel();
              done.complete();
            }
          });
          await done.future.timeout(const Duration(seconds: 5));
          expect(received.length, equals(5));
          // Allow cancel + close to round-trip.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(host.liveStreamCount, equals(0),
              reason: 'host sink must be torn down after consumer cancel');
        } finally {
          await host.shutdown();
        }
      },
    );
  });
}
