// InspectableSmokeMemory — an in-process, MCP-inspectable `TomBrainMemory`
// for the end-to-end conformance test (E.55).
//
// Plan step E.55 (verbatim): "End-to-end conformance test: scripted scenario —
// start process → OpenAI request → answer → memory inspect (via the MCP
// server) → assert event + conclusion + interest stack contents. Repeat for
// Telegram. Both must pass in CI."
//
// ── Why a second smoke memory ────────────────────────────────────────
//
// E.46–E.54 run memory over the *isolate* transport ([SmokeMemory] +
// [spawnSmokeMemory]) and inspect the post-run graph through the one read-back
// that marshals across the isolate boundary, [TomBrainMemoryClient.stats]. E.55
// has a stricter obligation: it must inspect memory *through the MCP server*,
// which is the brain's real external memory-inspection surface
// (`memory_specification.md` § 3.2). The MCP server is constructed over a
// [TomBrainMemory] and forwards each tool call to it directly; it cannot reach
// a store that lives behind a SendPort in a worker isolate.
//
// So E.55 provisions memory **in-process** ([MemoryProvisioningConfig.inProcess]
// — the test transport D.43 names): the run and the MCP server share one
// [TomBrainMemory] object in the host isolate. The run writes to it through the
// dispatcher/engine; the MCP server reads it back through the seven v1 tools.
// Since `TomBrainMemory implements TomBrainMemoryClient`, the very same object
// is both the dispatcher's in-process client and the MCP server's memory.
//
// ── How the cold path survives a recall that returns persisted nodes ──
//
// `answer_with_memory_v1` (§ 11) recalls **first**, then persists the Event /
// Conclusion / InterestItem. So a recall whose result is "every currently-
// persisted node" still returns *nothing* during the run (the store is empty at
// recall time, before any persist), which keeps the procedure on its cold
// classification path (InterestItem + an `interests` stack push, D.40). After
// the run the same recall returns the persisted Event and Conclusion — exactly
// what the E.55 MCP inspection needs to read back. The two phases are
// distinguished by *when* recall runs relative to the writes, not by any flag.
//
// Unlike [SmokeMemory] (which only tallies counts), this memory records full
// [Node] / [Edge] / [StackEntry] objects so the MCP read tools — `memory.recall`,
// `memory.get`, `memory.edgesOf`, `memory.stack.list`, `memory.stack.peek` —
// return real graph contents to the inspecting client.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;

/// An in-process recording [TomBrainMemory] whose graph is readable back through
/// the memory MCP server (E.55).
///
/// Records every persisted node, every edge, and every stack push as full
/// domain objects, and serves them through the consumer API the MCP tools call.
/// [recall] returns the persisted nodes (capped at the query's `k`), so a
/// post-run MCP `memory.recall` surfaces the run's Event + Conclusion; because
/// `answer_with_memory_v1` recalls before it persists, the in-run recall still
/// returns empty and the cold-classification path (InterestItem + `interests`
/// push) is preserved. Open / close / budget / lifecycle methods the smoke does
/// not exercise are unobtrusive no-ops.
final class InspectableSmokeMemory implements TomBrainMemory {
  /// The node type the engine's `RunRecorder` persists as a run bookkeeping
  /// marker (`procedureRunNodeType`). Excluded from [recall] so it never
  /// masquerades as a knowledge hit (see [recall]).
  static const String _procedureRunTypeName = 'ProcedureRun';

  /// Persisted nodes in insertion order, keyed by id.
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};

  /// Insertion order of node ids (recall returns nodes in this order).
  final List<NodeId> _nodeOrder = <NodeId>[];

  /// Recorded edges in insertion order.
  final List<Edge> _edges = <Edge>[];

  /// Persisted-node count keyed by `NodeDraft.typeName`.
  final Map<String, int> _nodeCountByType = <String, int>{};

  /// Edge count keyed by `EdgeType.wireName`.
  final Map<String, int> _edgeCountByType = <String, int>{};

  final _RecordingStackApi _stacks = _RecordingStackApi();

  int _trailCount = 0;

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> checkpoint() async {}

  @override
  Future<MemoryStats> stats() async => MemoryStats(
        nodeCountByType: Map<String, int>.of(_nodeCountByType),
        edgeCountByType: Map<String, int>.of(_edgeCountByType),
        stackSizes: _stacks.sizes(),
        trailCount: _trailCount,
        trailBytes: 0,
        recallLatencyPerMode: const <String, LatencyHistogram>{},
        classificationConfidenceHistogram: const <String, int>{},
        migrationProgress: const <String, double>{},
      );

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final NodeId id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      embedding: draft.embedding,
      createdAt: DateTime.now().toUtc(),
    );
    _nodeOrder.add(id);
    _nodeCountByType.update(draft.typeName, (c) => c + 1, ifAbsent: () => 1);
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async =>
      <Node>[for (final id in ids) if (_nodes[id] != null) _nodes[id]!];

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    final EdgeId id = EdgeId.generate();
    _edges.add(
      Edge(
        id: id,
        from: from,
        type: type,
        to: to,
        weight: weight,
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    _edgeCountByType.update(type.wireName, (c) => c + 1, ifAbsent: () => 1);
    return id;
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    // Return the persisted *knowledge* nodes in insertion order, capped at the
    // query's k. `ProcedureRun` records are excluded: a real recall surfaces
    // retrievable knowledge (Event, Conclusion, InterestItem, …), never run
    // bookkeeping — and the engine's `RunRecorder` persists an inflight
    // `ProcedureRun` marker *before* the procedure body runs. Counting that
    // marker as a recall hit would make the in-run recall non-empty and rob
    // `answer_with_memory_v1` of its cold-classification path (the InterestItem
    // + `interests` push, D.40). Filtering it keeps recall empty during the run
    // (only the marker exists at that point) while still surfacing the Event +
    // Conclusion after the run for the MCP inspection (see the file header).
    final nodes = <Node>[
      for (final id in _nodeOrder)
        if (_nodes[id] != null && _nodes[id]!.typeName != _procedureRunTypeName)
          _nodes[id]!,
    ];
    final capped = nodes.length <= query.k ? nodes : nodes.sublist(0, query.k);
    return RecallResult(
      nodes: capped,
      report: RecallReport(
        candidatesPerMode: <RecallMode, int>{
          for (final mode in query.modes) mode: capped.length,
        },
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        elapsedMs: 0,
        embeddingsCallouts: 0,
        reRankInvoked: false,
        degraded: false,
      ),
    );
  }

  @override
  StackApi get stacks => _stacks;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    _trailCount++;
    return TrailId.generate();
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {}

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {}

  @override
  Stream<TrailEntry> readTrail(TrailId id) => const Stream<TrailEntry>.empty();

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async =>
      <Edge>[
        for (final e in _edges)
          if (_touches(e, id, direction) &&
              (types == null || types.contains(e.type)))
            e,
      ];

  /// Whether [e] touches [id] in the requested [direction].
  bool _touches(Edge e, NodeId id, EdgeDirection direction) {
    switch (direction) {
      case EdgeDirection.outgoing:
        return e.from == id;
      case EdgeDirection.incoming:
        return e.to == id;
      case EdgeDirection.both:
        return e.from == id || e.to == id;
    }
  }

  // ─── Every other method is an unused no-op ────────────────────

  @override
  Future<void> beginRun({
    required String runId,
    required WriteBudget budget,
  }) async {}

  @override
  Future<void> endRun(String runId) async {}

  @override
  Future<WriteBudget?> remainingBudget(String runId) async => null;

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {}

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {}

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {}

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() async => const <NodeTypeDecl>[];

  @override
  Future<NodeTypeDecl?> getNodeType(String typeName) async => null;

  @override
  Stream<Node> stream(StreamQuery query) => const Stream<Node>.empty();

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async =>
      const ClassificationResult.unknown();

  @override
  Future<void> updateCentroid(String forKey, Vec centroid) async {}

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) async =>
      const <NodeId>[];

  @override
  MigrationApi get migrations => _NoopMigrationApi();

  @override
  Stream<MemoryEvent> events() => const Stream<MemoryEvent>.empty();
}

/// A recording [StackApi] that serves the inventory + top-K views the MCP
/// `memory.stack.list` / `memory.stack.peek` tools call.
class _RecordingStackApi implements StackApi {
  final Map<String, List<StackEntry>> _byName = <String, List<StackEntry>>{};

  /// The current active size of each known stack.
  Map<String, int> sizes() => <String, int>{
        for (final entry in _byName.entries) entry.key: entry.value.length,
      };

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final StackEntryId id = StackEntryId.generate();
    (_byName[name] ??= <StackEntry>[]).add(
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
  Future<List<StackSummary>> list() async => <StackSummary>[
        for (final entry in _byName.entries)
          StackSummary(
            name: entry.key,
            size: entry.value.length,
            topPriority: entry.value.isEmpty
                ? 0.0
                : entry.value
                    .map((e) => e.priority)
                    .reduce((a, b) => a > b ? a : b),
            bootstrap: false,
          ),
      ];

  @override
  Future<StackInfo?> info(String name) async => null;

  @override
  Future<void> create(StackDecl decl) async {}

  @override
  Future<void> updatePolicy(String name, StackPolicy policy) async {}

  @override
  Future<void> delete(String name) async {}

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final entries = _byName[name] ?? const <StackEntry>[];
    return entries.length <= k ? entries : entries.sublist(0, k);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final entries = _byName[name];
    if (entries == null || entries.isEmpty) return null;
    return entries.removeLast();
  }

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {}

  @override
  Future<void> remove(String name, NodeId entry) async {
    _byName[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Stream<StackEntry> streamArchived(String name, {int? limit}) =>
      const Stream<StackEntry>.empty();

  @override
  Stream<StackEvent> events(String name) => const Stream<StackEvent>.empty();
}

class _NoopMigrationApi implements MigrationApi {
  @override
  Future<void> start(MigrationDecl decl) async {}

  @override
  Future<MigrationCursor?> cursor(String migrationId) async => null;

  @override
  Future<void> saveCursor(
    String migrationId,
    Map<String, Object?> position,
  ) async {}

  @override
  Future<MigrationStatus?> status(String migrationId) async => null;

  @override
  Future<List<MigrationStatus>> listInProgress() async =>
      const <MigrationStatus>[];
}
