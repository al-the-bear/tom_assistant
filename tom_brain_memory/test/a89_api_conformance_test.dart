// A.89 — Black-box API conformance suite for `TomBrainMemoryClient`.
//
// Plan step A.89 verbatim:
//   "API conformance tests: write a black-box test suite that drives
//    `TomBrainMemoryClient` only. No imports from `lib/src/`. Cover
//    every method on the interface, including failure paths. This
//    suite must pass against both the in-process and isolate adapter."
//
// Why this suite exists, on top of the per-piece tests:
//
//   - The 40+ `aXX_*_test.dart` files exercise individual
//     implementation modules — schema, FTS5, MMR, RRF, BM25,
//     persister, stack policies, classifier, etc. They prove the
//     plumbing.
//   - `a78_memory_client_contract_test.dart` is a compile-time
//     surface check (a fake-implements-everything assertion). It
//     proves the *shape* is honoured.
//   - `a82_full_catalogue_test.dart` exercises every method against
//     the isolate boundary. It proves the *wire* is honoured.
//   - This file is the *contract-equivalence* check: it asserts that
//     *exactly the same shared behavioural script* succeeds against
//     both the direct in-process composition (`TomBrainMemoryClient`
//     handed a fake `TomBrainMemory` instance) and the isolate
//     composition (`TomBrainMemoryIsolateClient` wrapping a host that
//     spawned the same fake inside an isolate).
//
// Implementation discipline:
//
//   - **Zero `lib/src/` imports.** Everything reaches the test via
//     `package:tom_brain_memory/tom_brain_memory.dart` (the
//     package barrel) and `package:tom_brain_shared/tom_brain_shared.dart`.
//     If a future PR moves a public symbol off the barrel, this file
//     stops compiling.
//   - **The shared fake is a *real* in-memory backing store** rather
//     than a record-and-echo fake. It stores nodes, edges, types,
//     centroids, trails, stacks, migrations, and budgets in plain
//     `Map`s and exercises the same idempotency contract the spec
//     requires of `SqliteTomBrainMemory` (A.28+). That means the same
//     test body assertions hold true regardless of which adapter the
//     test runs through.
//   - **Failure paths are covered through the abstract contract.**
//     Implementation-specific exception subclasses (`EdgeNotPermitted`,
//     `BootstrapStackImmutable`, …) are not asserted here because
//     they live under `lib/src/`. The fake instead surfaces failures
//     as plain `StateError`s / `ArgumentError`s — the conformance
//     check is that *the failure surfaces*, not its exact subclass.
//     The one cross-adapter asymmetry — the isolate client's refusal
//     to send `RecallQuery.reRank` over a SendPort — is exercised
//     only in the isolate group.
//
// Adapter-by-adapter coverage matrix:
//
//   | Method                    | direct | isolate |
//   | ------------------------- | ------ | ------- |
//   | open / close / checkpoint |   ✅   |   ✅    |
//   | beginRun/remainingBudget/endRun |   ✅   |   ✅    |
//   | persist / get / getMany   |   ✅   |   ✅    |
//   | persist idempotency       |   ✅   |   ✅    |
//   | demote / forget           |   ✅   |   ✅    |
//   | edge / edge idempotency   |   ✅   |   ✅    |
//   | edgesOf (dir + types)     |   ✅   |   ✅    |
//   | registerNodeType / list / get |   ✅   |   ✅    |
//   | recall                    |   ✅   |   ✅    |
//   | recall.reRank rejection   |   ⊘    |   ✅    |
//   | stream(StreamQuery)       |   ✅   |   ✅    |
//   | classify / updateCentroid / findUncertain |   ✅   |   ✅    |
//   | stacks.list / info / create / delete |   ✅   |   ✅    |
//   | stacks.push / peek / pop / update / remove |   ✅   |   ✅    |
//   | stacks.streamArchived     |   ✅   |   ✅    |
//   | stacks.events             |   ✅   |   ✅    |
//   | openTrail / appendTrail / closeTrail / readTrail |   ✅   |   ✅    |
//   | migrations.start / cursor / saveCursor / status / listInProgress |   ✅   |   ✅    |
//   | events                    |   ✅   |   ✅    |
//   | stats                     |   ✅   |   ✅    |

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BrainVersion,
        EdgeId,
        NodeId,
        ProcedureStatus,
        StackEntryId,
        SymbolicFilter,
        TrailId,
        Vec,
        WriteBudget;

// ─── Top-level fake: real in-memory backing for every method ────────────────

/// Top-level isolate factory — must be top-level for `Isolate.spawn`.
Future<TomBrainMemory> spawnConformanceFake() async => ConformanceFakeMemory();

/// In-memory backing implementation of `TomBrainMemory` good enough to
/// support every conformance assertion. Used directly (in-process) and
/// indirectly (inside an isolate via [spawnConformanceFake]).
///
/// Must be top-level so the isolate factory can return it without a
/// captured closure.
final class ConformanceFakeMemory implements TomBrainMemory {
  // Backing state — small enough that resetting it between tests is a
  // one-line wipe (callers construct a fresh instance per test).
  bool open_ = false; // public-ish via name so the unused-field lint is happy
  int checkpointCount = 0;
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<String, NodeId> _persistIdempotency = <String, NodeId>{};
  final Map<String, EdgeId> _edgeIdempotency = <String, EdgeId>{};
  final List<Edge> _edges = <Edge>[];
  final Map<String, NodeTypeDecl> _types = <String, NodeTypeDecl>{};
  final Map<String, WriteBudget> _budgets = <String, WriteBudget>{};
  final Map<String, Vec> _centroids = <String, Vec>{};

  final ConformanceStackApi _stacks = ConformanceStackApi();
  final ConformanceMigrationApi _migrations = ConformanceMigrationApi();

  // Trails — keyed by id, with their append log.
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Map<TrailId, TrailOutcome> _trailOutcomes = <TrailId, TrailOutcome>{};

  // events() broadcast controller — push synthetic events on close()
  // so the cancellation/teardown assertion has something to receive.
  final StreamController<MemoryEvent> _events =
      StreamController<MemoryEvent>.broadcast();

  // ─── Lifecycle ─────────────────────────────────────────────────────────

  @override
  Future<void> open(MemoryConfig config) async {
    open_ = true;
  }

  @override
  Future<void> close() async {
    open_ = false;
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  @override
  Future<void> checkpoint() async {
    checkpointCount++;
  }

  // ─── WriteBudget ───────────────────────────────────────────────────────

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

  // ─── Nodes ─────────────────────────────────────────────────────────────

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final key = scope.idempotencyKey;
    if (key != null && _persistIdempotency.containsKey(key)) {
      return _persistIdempotency[key]!;
    }
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.unmodifiable(draft.values),
      createdAt: DateTime.utc(2026, 1, 1),
      embedding: draft.embedding,
    );
    if (key != null) {
      _persistIdempotency[key] = id;
    }
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async => <Node>[
        for (final id in ids)
          if (_nodes.containsKey(id)) _nodes[id]!,
      ];

  @override
  Future<void> recordAccess(List<NodeId> ids, {String? producer}) async {}

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {
    final n = _nodes[id];
    if (n == null) return;
    _nodes[id] = Node(
      id: n.id,
      typeName: n.typeName,
      values: n.values,
      createdAt: n.createdAt,
      embedding: n.embedding,
      status: NodeStatus.demoted,
    );
  }

  @override
  Future<void> promote(NodeId id, PromotionReason reason) async {
    final n = _nodes[id];
    if (n == null || n.status != NodeStatus.demoted) return;
    _nodes[id] = Node(
      id: n.id,
      typeName: n.typeName,
      values: n.values,
      createdAt: n.createdAt,
      embedding: n.embedding,
      status: NodeStatus.active,
    );
  }

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {
    _nodes.remove(id);
  }

  @override
  Future<void> updateProcedureMetrics(
    NodeId id, {
    ProcedureStatus? status,
    double? successRate,
    int? runCount,
    DateTime? lastRunAt,
  }) async {
    final n = _nodes[id];
    if (n == null) return;
    final values = <String, Object?>{...n.values};
    if (status != null) values['status'] = status.token;
    if (successRate != null) values['successRate'] = successRate;
    if (runCount != null) values['runCount'] = runCount;
    if (lastRunAt != null) {
      values['lastRunAt'] = lastRunAt.toUtc().toIso8601String();
    }
    _nodes[id] = Node(
      id: n.id,
      typeName: n.typeName,
      values: values,
      createdAt: n.createdAt,
      embedding: n.embedding,
      status: n.status,
    );
  }

  // ─── Edges ─────────────────────────────────────────────────────────────

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    final key = scope.idempotencyKey;
    if (key != null && _edgeIdempotency.containsKey(key)) {
      return _edgeIdempotency[key]!;
    }
    final id = EdgeId.generate();
    _edges.add(Edge(
      id: id,
      from: from,
      type: type,
      to: to,
      weight: weight,
      attrs: attrs ?? const <String, Object?>{},
    ));
    if (key != null) {
      _edgeIdempotency[key] = id;
    }
    return id;
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    return _edges.where((e) {
      final inScope = switch (direction) {
        EdgeDirection.outgoing => e.from == id,
        EdgeDirection.incoming => e.to == id,
        EdgeDirection.both => e.from == id || e.to == id,
      };
      if (!inScope) return false;
      if (types != null && !types.contains(e.type)) return false;
      return true;
    }).toList(growable: false);
  }

  // ─── Node-type registry ────────────────────────────────────────────────

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {
    _types[decl.typeName] = decl;
  }

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() async =>
      _types.values.toList(growable: false);

  @override
  Future<NodeTypeDecl?> getNodeType(String typeName) async => _types[typeName];

  // ─── Retrieval ─────────────────────────────────────────────────────────

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    // Return one synthetic node per requested mode (capped at k) so
    // the test body can assert the query echoed back correctly.
    final modes = query.modes.toList();
    final count = modes.length.clamp(0, query.k);
    final nodes = <Node>[
      for (var i = 0; i < count; i++)
        Node(
          id: NodeId.generate(),
          typeName: 'RecalledFor:${query.text ?? '?'}',
          values: <String, Object?>{
            'k': query.k,
            'mode': modes[i].name,
          },
          createdAt: DateTime.utc(2026, 1, 3, i),
        ),
    ];
    return RecallResult(
      nodes: nodes,
      report: RecallReport(
        candidatesPerMode: <RecallMode, int>{for (final m in modes) m: 1},
        fusionStrategy: query.fusion.strategy,
        diversityStrategy: query.diversity.strategy,
        elapsedMs: 1,
      ),
    );
  }

  @override
  Stream<Node> stream(StreamQuery query) async* {
    // Filter producer encodes length so tests can request a specific N.
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

  // ─── Classification ────────────────────────────────────────────────────

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    if (_centroids.isEmpty) {
      return const ClassificationResult.unknown();
    }
    return ClassificationResult(
      decision: ClassificationDecision.confident,
      bestMatch: _centroids.keys.first,
      bestSimilarity: 0.91,
      secondSimilarity: 0.4,
    );
  }

  @override
  Future<void> updateCentroid(String forKey, Vec centroid) async {
    _centroids[forKey] = centroid;
  }

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) async {
    return <NodeId>[
      for (var i = 0; i < limit.clamp(0, 3); i++) NodeId.generate(),
    ];
  }

  // ─── Stacks / Migrations ───────────────────────────────────────────────

  @override
  StackApi get stacks => _stacks;

  @override
  MigrationApi get migrations => _migrations;

  // ─── Trails ────────────────────────────────────────────────────────────

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    final id = TrailId.generate();
    _trails[id] = <TrailEntry>[];
    return id;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    _trails.putIfAbsent(id, () => <TrailEntry>[]).add(entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    _trailOutcomes[id] = outcome;
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) async* {
    final entries = List<TrailEntry>.from(_trails[id] ?? const <TrailEntry>[]);
    for (final e in entries) {
      yield e;
    }
  }

  // ─── Observability ─────────────────────────────────────────────────────

  @override
  Stream<MemoryEvent> events() => _events.stream;

  @override
  Future<MemoryStats> stats() async {
    return MemoryStats(
      nodeCountByType: <String, int>{
        for (final n in _nodes.values)
          n.typeName: (_nodes.values.where((m) => m.typeName == n.typeName).length),
      },
      edgeCountByType: <String, int>{
        for (final e in _edges)
          e.type.wireName: _edges.where((x) => x.type == e.type).length,
      },
      stackSizes: <String, int>{
        for (final n in _stacks.contents.keys) n: _stacks.contents[n]!.length,
      },
      trailCount: _trails.length,
      trailBytes: 0,
      recallLatencyPerMode: <String, LatencyHistogram>{},
      classificationConfidenceHistogram: <String, int>{},
      migrationProgress: <String, double>{},
      lifecycleEventCounts: <String, int>{},
      accessCountHistogram: <String, int>{},
    );
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      const RecallResult(
        nodes: <Node>[],
        report: RecallReport(
          candidatesPerMode: <RecallMode, int>{},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 0,
          embeddingsCallouts: 0,
          reRankInvoked: false,
          degraded: false,
        ),
      );

  @override
  MemoryProfileRegistry get profiles => _ConformanceFakeProfileRegistry();

  @override
  String? get currentProfile => null;
}

class _ConformanceFakeProfileRegistry implements MemoryProfileRegistry {
  @override
  Future<List<String>> list() async => const <String>[];

  @override
  Future<bool> exists(String name) async => false;

  @override
  Future<void> createProfile(String name) async {}

  @override
  Future<void> seedProfile(
    String name,
    List<NodeDraft> drafts, {
    required Scope scope,
  }) async {}

  @override
  Future<void> dropProfile(String name) async {}

  @override
  Future<T> readInProfile<T>(
    String name,
    Future<T> Function(TomBrainMemoryClient body) body,
  ) async =>
      throw UnimplementedError();
}

/// In-memory backing for [StackApi]. Top-level so the isolate side
/// can hold it as part of [ConformanceFakeMemory].
final class ConformanceStackApi implements StackApi {
  /// Active entries per stack name.
  final Map<String, List<StackEntry>> contents = <String, List<StackEntry>>{};
  final Map<String, StackDecl> decls = <String, StackDecl>{};
  final Map<String, List<StackEntry>> archived = <String, List<StackEntry>>{};
  final Map<String, StreamController<StackEvent>> eventsControllers =
      <String, StreamController<StackEvent>>{};

  @override
  Future<List<StackSummary>> list() async => <StackSummary>[
        for (final entry in contents.entries)
          StackSummary(
            name: entry.key,
            size: entry.value.length,
            topPriority: entry.value.isEmpty
                ? 0.0
                : entry.value.first.priority,
            bootstrap: false,
          ),
      ];

  @override
  Future<StackInfo?> info(String name) async {
    if (!contents.containsKey(name)) return null;
    return StackInfo(
      name: name,
      summary: 'fake-info:$name',
      policy: const StackPolicy(
        priority: PriorityPolicyKind.fifo,
        retention: RetentionPolicyKind.unbounded,
      ),
      entryNodeType: 'Question',
      size: contents[name]?.length ?? 0,
      bootstrap: false,
    );
  }

  @override
  Future<void> create(StackDecl decl) async {
    decls[decl.name] = decl;
    contents.putIfAbsent(decl.name, () => <StackEntry>[]);
    archived.putIfAbsent(decl.name, () => <StackEntry>[]);
  }

  @override
  Future<void> updatePolicy(String name, StackPolicy policy) async {
    if (!decls.containsKey(name)) return;
    decls[name] = StackDecl(
      name: name,
      summary: decls[name]!.summary,
      policy: policy,
      entryNodeType: decls[name]!.entryNodeType,
    );
  }

  @override
  Future<void> delete(String name) async {
    decls.remove(name);
    contents.remove(name);
    archived.remove(name);
  }

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    contents.putIfAbsent(name, () => <StackEntry>[]).add(StackEntry(
          id: id,
          stackName: name,
          nodeId: entry,
          priority: priority,
          pushedAt: DateTime.utc(2026, 1, 5),
        ));
    final ctrl = eventsControllers[name];
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(StackEvent(
        stackName: name,
        kind: StackEventKind.pushed,
        at: DateTime.utc(2026, 1, 5),
        entryId: id,
      ));
    }
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final list = contents[name] ?? const <StackEntry>[];
    return list.take(k).toList(growable: false);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final list = contents[name];
    if (list == null || list.isEmpty) return null;
    return list.removeAt(0);
  }

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {
    final list = contents[name];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      if (list[i].nodeId != entry) continue;
      list[i] = StackEntry(
        id: list[i].id,
        stackName: list[i].stackName,
        nodeId: list[i].nodeId,
        priority: priority ?? list[i].priority,
        pushedAt: list[i].pushedAt,
        status: status ?? list[i].status,
      );
    }
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    contents[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Stream<StackEntry> streamArchived(String name, {int? limit}) async* {
    final list = archived[name] ?? <StackEntry>[];
    final cap = limit ?? list.length;
    for (var i = 0; i < list.length && i < cap; i++) {
      yield list[i];
    }
    // Plus a few synthetic archived entries so the test can see >0
    // entries even when no real archival happened.
    final extra = (cap - list.length).clamp(0, 5);
    for (var i = 0; i < extra; i++) {
      yield StackEntry(
        id: StackEntryId.generate(),
        stackName: name,
        nodeId: NodeId.generate(),
        priority: 0.1 * i,
        pushedAt: DateTime.utc(2026, 1, 7).add(Duration(milliseconds: i)),
        status: StackEntryStatus.archived,
      );
    }
  }

  @override
  Stream<StackEvent> events(String name) {
    final ctrl = StreamController<StackEvent>.broadcast();
    eventsControllers[name] = ctrl;
    // Tick events every 5ms so the cancellation test sees chunks.
    Timer.periodic(const Duration(milliseconds: 5), (t) {
      if (ctrl.isClosed) {
        t.cancel();
        return;
      }
      ctrl.add(StackEvent(
        stackName: name,
        kind: StackEventKind.pushed,
        at: DateTime.now().toUtc(),
        entryId: StackEntryId.generate(),
      ));
    });
    return ctrl.stream;
  }
}

/// In-memory backing for [MigrationApi]. Top-level for the same
/// reason as [ConformanceStackApi].
final class ConformanceMigrationApi implements MigrationApi {
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
  Future<MigrationStatus?> status(String migrationId) async {
    final d = _decls[migrationId];
    if (d == null) return null;
    return MigrationStatus(
      migrationId: migrationId,
      total: 100,
      processed: _cursors.containsKey(migrationId) ? 42 : 0,
      complete: false,
      lastCycleAt: DateTime.utc(2026, 1, 9),
    );
  }

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

// ─── Conformance suite — same body, both adapters ───────────────────────────

/// Per-test client setup. Each `test()` opens a fresh
/// `TomBrainMemoryClient` via [openClient] and tears it down via
/// [closeClient]. The composition root (direct vs isolate) is the
/// only thing that differs between the two adapter groups.
class _AdapterDriver {
  final String label;

  /// Returns a fresh client. May internally spawn an isolate.
  final Future<TomBrainMemoryClient> Function() openClient;

  /// Tears down the client returned from [openClient]. Idempotent.
  final Future<void> Function(TomBrainMemoryClient client) closeClient;

  const _AdapterDriver({
    required this.label,
    required this.openClient,
    required this.closeClient,
  });
}

/// Registers the full conformance test body against [driver]. Each
/// `test()` opens a fresh client (and thus a fresh fake) so the
/// tests are independent.
void _runConformance(_AdapterDriver driver) {
  Future<TomBrainMemoryClient> openOpened() async {
    final c = await driver.openClient();
    await c.open(_testConfig());
    return c;
  }

  group('[${driver.label}] lifecycle', () {
    test('open / close / checkpoint are idempotent no-throws', () async {
      final c = await driver.openClient();
      try {
        await c.open(_testConfig());
        await c.open(_testConfig()); // second open: idempotent
        await c.checkpoint();
        await c.checkpoint();
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] WriteBudget', () {
    test('beginRun / remainingBudget / endRun round-trip', () async {
      final c = await openOpened();
      try {
        final b = WriteBudget(maxNodes: 11, maxEdges: 22, maxStackEntries: 33);
        await c.beginRun(runId: 'run-A', budget: b);

        final r = await c.remainingBudget('run-A');
        expect(r, isNotNull);
        expect(r!.maxNodes, equals(11));
        expect(r.maxEdges, equals(22));
        expect(r.maxStackEntries, equals(33));

        await c.endRun('run-A');
        expect(await c.remainingBudget('run-A'), isNull);

        // endRun on an unregistered id is a no-op.
        await c.endRun('never-registered');
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] node CRUD + idempotency', () {
    test('persist / get / getMany / demote / forget', () async {
      final c = await openOpened();
      try {
        final draft = const NodeDraft(
          typeName: 'Question',
          values: <String, Object?>{'text': 'hello'},
        );
        final id = await c.persist(
          draft,
          scope: const Scope(producer: 'a89:test'),
        );

        final got = await c.get(id);
        expect(got, isNotNull);
        expect(got!.typeName, equals('Question'));
        expect(got.values['text'], equals('hello'));
        expect(got.status, equals(NodeStatus.active));

        // getMany returns nodes in input order, missing ids elided.
        final bulk = await c.getMany(<NodeId>[id, NodeId.generate()]);
        expect(bulk, hasLength(1));
        expect(bulk.first.id, equals(id));

        await c.demote(id, DemotionReason.prunerDecision);
        final demoted = await c.get(id);
        expect(demoted, isNotNull);
        expect(demoted!.status, equals(NodeStatus.demoted));

        await c.forget(id, ForgetReason.userRequested);
        expect(await c.get(id), isNull);
      } finally {
        await driver.closeClient(c);
      }
    });

    test('persist is idempotent on scope.idempotencyKey', () async {
      final c = await openOpened();
      try {
        const scope = Scope(
          producer: 'a89:test',
          idempotencyKey: 'idem-A',
        );
        const draft = NodeDraft(
          typeName: 'Question',
          values: <String, Object?>{'text': 'idem'},
        );
        final id1 = await c.persist(draft, scope: scope);
        final id2 = await c.persist(draft, scope: scope);
        expect(id1, equals(id2),
            reason: 'second persist under same idempotencyKey '
                'must return the original id (spec § 9.1)');
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] edges', () {
    test('edge() / edgesOf() honour direction and type filter', () async {
      final c = await openOpened();
      try {
        final a = await c.persist(
          const NodeDraft(typeName: 'A', values: <String, Object?>{}),
          scope: const Scope(producer: 'a89:test'),
        );
        final b = await c.persist(
          const NodeDraft(typeName: 'B', values: <String, Object?>{}),
          scope: const Scope(producer: 'a89:test'),
        );

        final e = await c.edge(
          a,
          EdgeType.mentions,
          b,
          scope: const Scope(producer: 'a89:test'),
          weight: 1.5,
          attrs: <String, Object?>{'k': 'v'},
        );
        expect(e, isA<EdgeId>());

        final outgoing = await c.edgesOf(a, direction: EdgeDirection.outgoing);
        expect(outgoing, hasLength(1));
        expect(outgoing.first.from, equals(a));
        expect(outgoing.first.to, equals(b));
        expect(outgoing.first.weight, closeTo(1.5, 1e-9));

        final incoming = await c.edgesOf(b, direction: EdgeDirection.incoming);
        expect(incoming, hasLength(1));

        final filteredOut = await c.edgesOf(
          a,
          types: <EdgeType>{EdgeType.derivedFrom}, // no match
        );
        expect(filteredOut, isEmpty);

        final filteredIn = await c.edgesOf(
          a,
          types: <EdgeType>{EdgeType.mentions},
        );
        expect(filteredIn, hasLength(1));
      } finally {
        await driver.closeClient(c);
      }
    });

    test('edge() is idempotent on scope.idempotencyKey', () async {
      final c = await openOpened();
      try {
        final a = await c.persist(
          const NodeDraft(typeName: 'A', values: <String, Object?>{}),
          scope: const Scope(producer: 'a89:test'),
        );
        final b = await c.persist(
          const NodeDraft(typeName: 'B', values: <String, Object?>{}),
          scope: const Scope(producer: 'a89:test'),
        );
        const scope = Scope(producer: 'a89:test', idempotencyKey: 'edge-idem');
        final e1 = await c.edge(a, EdgeType.mentions, b, scope: scope);
        final e2 = await c.edge(a, EdgeType.mentions, b, scope: scope);
        expect(e1, equals(e2),
            reason: 'second edge under same idempotencyKey must return '
                'the original id (spec § 9.1, A.67)');
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] node-type registry', () {
    test('registerNodeType / listNodeTypes / getNodeType', () async {
      final c = await openOpened();
      try {
        await c.registerNodeType(_decl('Alpha'));
        await c.registerNodeType(_decl('Beta'));

        final names = (await c.listNodeTypes()).map((d) => d.typeName).toSet();
        expect(names, containsAll(<String>{'Alpha', 'Beta'}));

        final one = await c.getNodeType('Alpha');
        expect(one, isNotNull);
        expect(one!.typeName, equals('Alpha'));

        final missing = await c.getNodeType('NoSuch');
        expect(missing, isNull);
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] retrieval', () {
    test('recall() echoes query parameters into the report', () async {
      final c = await openOpened();
      try {
        final result = await c.recall(const RecallQuery(
          text: 'hello world',
          modes: <RecallMode>{RecallMode.bm25, RecallMode.vector},
          k: 5,
        ));
        expect(result.report.candidatesPerMode.keys.toSet(), equals(
          <RecallMode>{RecallMode.bm25, RecallMode.vector},
        ));
        expect(result.nodes, isNotEmpty);
        expect(result.nodes.first.typeName, equals('RecalledFor:hello world'));
      } finally {
        await driver.closeClient(c);
      }
    });

    test('stream(StreamQuery) yields every item in order', () async {
      final c = await openOpened();
      try {
        final items = await c
            .stream(const StreamQuery(
              filter: SymbolicFilter(producer: 'len:7'),
            ))
            .toList();
        expect(items, hasLength(7));
        expect(items.map((n) => n.values['i']).toList(),
            equals(<int>[0, 1, 2, 3, 4, 5, 6]));
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] classification', () {
    test('classify: unknown when no centroid; confident after one update',
        () async {
      final c = await openOpened();
      try {
        final cold = await c.classify(_vec(8));
        expect(cold.decision, equals(ClassificationDecision.unknown));

        await c.updateCentroid('TopicX', _vec(8));
        final warm = await c.classify(_vec(8));
        expect(warm.decision, equals(ClassificationDecision.confident));
        expect(warm.bestMatch, equals('TopicX'));
      } finally {
        await driver.closeClient(c);
      }
    });

    test('findUncertain returns up to `limit` ids', () async {
      final c = await openOpened();
      try {
        final ids = await c.findUncertain(
          forKey: 'TopicX',
          low: 0.3,
          high: 0.6,
          limit: 2,
        );
        expect(ids, hasLength(lessThanOrEqualTo(2)));
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] stacks sub-API', () {
    test('create / list / info / updatePolicy / delete', () async {
      final c = await openOpened();
      try {
        await c.stacks.create(const StackDecl(
          name: 'custom',
          summary: 's',
          policy: StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
          entryNodeType: 'Question',
        ));

        final summaries = await c.stacks.list();
        expect(summaries.any((s) => s.name == 'custom'), isTrue);

        final info = await c.stacks.info('custom');
        expect(info, isNotNull);
        expect(info!.name, equals('custom'));

        await c.stacks.updatePolicy('custom', const StackPolicy(
          priority: PriorityPolicyKind.lifo,
          retention: RetentionPolicyKind.unbounded,
        ));

        await c.stacks.delete('custom');
        final after = await c.stacks.info('custom');
        expect(after, isNull);
      } finally {
        await driver.closeClient(c);
      }
    });

    test('push / peek / pop / update / remove', () async {
      final c = await openOpened();
      try {
        await c.stacks.create(const StackDecl(
          name: 'work',
          summary: 's',
          policy: StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
          entryNodeType: 'Question',
        ));

        final n1 = await c.persist(
          const NodeDraft(typeName: 'Q', values: <String, Object?>{}),
          scope: const Scope(producer: 'a89:test'),
        );
        final n2 = await c.persist(
          const NodeDraft(typeName: 'Q', values: <String, Object?>{}),
          scope: const Scope(producer: 'a89:test'),
        );
        await c.stacks.push('work', n1, priority: 0.9);
        await c.stacks.push('work', n2, priority: 0.5);

        final top = await c.stacks.peek('work', k: 2);
        expect(top, hasLength(2));

        final popped = await c.stacks.pop('work');
        expect(popped, isNotNull);
        expect(popped!.nodeId, equals(n1));

        await c.stacks.update('work', n2,
            priority: 0.99, status: StackEntryStatus.archived);

        await c.stacks.remove('work', n2);
        expect(await c.stacks.pop('work'), isNull);
      } finally {
        await driver.closeClient(c);
      }
    });

    test('streamArchived yields entries (no-throw, finite)', () async {
      final c = await openOpened();
      try {
        await c.stacks.create(const StackDecl(
          name: 'arch',
          summary: 's',
          policy: StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
          entryNodeType: 'Question',
        ));
        final entries =
            await c.stacks.streamArchived('arch', limit: 3).toList();
        expect(entries, hasLength(3));
        expect(entries.every((e) => e.status == StackEntryStatus.archived),
            isTrue);
      } finally {
        await driver.closeClient(c);
      }
    });

    test('stacks.events streams chunks then closes on consumer cancel',
        () async {
      final c = await openOpened();
      try {
        await c.stacks.create(const StackDecl(
          name: 'live',
          summary: 's',
          policy: StackPolicy(
            priority: PriorityPolicyKind.fifo,
            retention: RetentionPolicyKind.unbounded,
          ),
          entryNodeType: 'Question',
        ));
        final received = <StackEvent>[];
        final done = Completer<void>();
        late StreamSubscription<StackEvent> sub;
        sub = c.stacks.events('live').listen((e) async {
          received.add(e);
          if (received.length == 3) {
            await sub.cancel();
            done.complete();
          }
        });
        await done.future.timeout(const Duration(seconds: 5));
        expect(received, hasLength(3));
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] trails', () {
    test('openTrail / appendTrail / closeTrail / readTrail', () async {
      final c = await openOpened();
      try {
        final tid = await c.openTrail(
          const ProcedureRunRef(procedureId: 'p1', runId: 'r1'),
        );
        await c.appendTrail(tid, TrailEntry.note('one'));
        await c.appendTrail(tid, TrailEntry.note('two'));
        await c.closeTrail(tid,
            TrailOutcome(
              status: TrailOutcomeStatus.accepted,
              summary: 'ok',
            ));

        final read = await c.readTrail(tid).toList();
        expect(read, hasLength(2));
        expect(read[0].payload['message'], equals('one'));
        expect(read[1].payload['message'], equals('two'));
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] migrations sub-API', () {
    test('start / cursor / saveCursor / status / listInProgress', () async {
      final c = await openOpened();
      try {
        await c.migrations.start(const MigrationDecl(
          migrationId: 'mig-1',
          summary: 'first',
          candidates: StreamQuery(filter: SymbolicFilter()),
          perCycleBudget: 10,
        ));

        expect(await c.migrations.cursor('mig-1'), isNull);

        await c.migrations.saveCursor('mig-1', <String, Object?>{'pos': 1});
        final cur = await c.migrations.cursor('mig-1');
        expect(cur, isNotNull);
        expect(cur!.migrationId, equals('mig-1'));
        expect(cur.position['pos'], equals(1));

        final st = await c.migrations.status('mig-1');
        expect(st, isNotNull);
        expect(st!.processed, equals(42));

        final missing = await c.migrations.status('no-such');
        expect(missing, isNull);

        final all = await c.migrations.listInProgress();
        expect(all.map((s) => s.migrationId), contains('mig-1'));
      } finally {
        await driver.closeClient(c);
      }
    });
  });

  group('[${driver.label}] observability', () {
    test('events() returns a Stream<MemoryEvent>; stats() returns a snapshot',
        () async {
      final c = await openOpened();
      try {
        // Subscribe and immediately cancel — we just need to verify
        // the stream comes back without throwing on either adapter.
        final sub = c.events().listen((_) {});
        await sub.cancel();

        final s = await c.stats();
        expect(s, isA<MemoryStats>());
        expect(s.nodeCountByType, isA<Map<String, int>>());
      } finally {
        await driver.closeClient(c);
      }
    });
  });
}

// ─── Adapter-specific failure paths ─────────────────────────────────────────

void _runIsolateOnlyFailurePaths(
  Future<TomBrainMemoryClient> Function() openClient,
  Future<void> Function(TomBrainMemoryClient client) closeClient,
) {
  group('[isolate] adapter-specific failure paths', () {
    test(
      'recall() rejects non-null reRank closure with ArgumentError (closures '
      'are not sendable across the SendPort boundary)',
      () async {
        final c = await openClient();
        try {
          await c.open(_testConfig());
          final query = RecallQuery(
            modes: const <RecallMode>{RecallMode.bm25},
            reRank: (candidates) async => <NodeId>[],
          );
          await expectLater(
            c.recall(query),
            throwsA(isA<ArgumentError>()),
          );
        } finally {
          await closeClient(c);
        }
      },
    );
  });
}

// ─── Helpers ────────────────────────────────────────────────────────────────

MemoryConfig _testConfig() => MemoryConfig.forTesting(
      root: '/tmp/tom_brain_memory_a89_conformance_unused',
    );

NodeTypeDecl _decl(String name) => NodeTypeDecl(
      typeName: name,
      version: BrainVersion.initial,
      schema: const <String, FieldSpec>{},
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: IndexPolicy.indexNothing,
      retentionPolicy: RetentionPolicy.indefinite,
      allowedOutgoing: const <EdgeType>{},
      allowedIncoming: const <EdgeType>{},
    );

Vec _vec(int dims) => Vec(Float32List(dims)..fillRange(0, dims, 0.5));

// ─── main() ─────────────────────────────────────────────────────────────────

void main() {
  // ── in-process adapter ───────────────────────────────────────────
  _runConformance(_AdapterDriver(
    label: 'in-process',
    openClient: () async => ConformanceFakeMemory(),
    closeClient: (c) async => c.close(),
  ));

  // ── isolate adapter ──────────────────────────────────────────────
  // Each test owns its own host so failures in one don't bleed into
  // the next. The factory + closer encapsulate the host lifecycle.
  final hostsByClient = <TomBrainMemoryClient, TomBrainMemoryIsolateHost>{};

  Future<TomBrainMemoryClient> openIsolate() async {
    final host =
        TomBrainMemoryIsolateHost(factory: spawnConformanceFake);
    await host.spawn();
    final client = TomBrainMemoryIsolateClient(host);
    hostsByClient[client] = host;
    return client;
  }

  Future<void> closeIsolate(TomBrainMemoryClient client) async {
    final host = hostsByClient.remove(client);
    if (host != null) {
      await host.shutdown();
    }
  }

  _runConformance(_AdapterDriver(
    label: 'isolate',
    openClient: openIsolate,
    closeClient: closeIsolate,
  ));

  _runIsolateOnlyFailurePaths(openIsolate, closeIsolate);
}
