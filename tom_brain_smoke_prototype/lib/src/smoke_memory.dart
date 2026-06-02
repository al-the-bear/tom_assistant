// SmokeMemory + spawnSmokeMemory — an in-isolate recording `TomBrainMemory`
// for the end-to-end smoke (E.46 stand-up, E.47 chat roundtrip).
//
// The smoke harness provisions memory over the *isolate* transport (the
// production topology), so the store runs in a spawned worker isolate. The
// factory reference and the class it returns therefore cross the isolate
// boundary: Dart forbids closures captured from the spawning isolate, so both
// [spawnSmokeMemory] and [SmokeMemory] must be top-level, reachable in the
// spawned isolate (which loads the same Dart program). This mirrors the
// procedure prototype's `RecordingFakeMemory` + `spawnRichFakeMemory`
// convention (`d43_memory_provisioning_test.dart`).
//
// ── Why this records (and how the test reads it back) ────────────────
//
// E.47 drives a real `POST /v1/chat/completions` and must then assert the
// `answer_with_memory_v1` procedure persisted the expected graph: an `Event`
// for the inbound prompt, a `Conclusion` for the answer, a `produced_by` edge
// (recorder), and — on a fresh empty memory — a cold-path `InterestItem` plus
// an `interests` stack push. But the store runs in the *worker* isolate, so
// the test cannot reach into it directly. The one marshallable read-back is
// [TomBrainMemory.stats]: this store therefore tallies every persist (by node
// type), every edge (by wire name), every stack push (by stack name), and
// every opened trail, and projects them onto a [MemoryStats] the host can read
// across the boundary.
//
// Recall stays empty (no seeded nodes) so the procedure takes the cold path —
// exactly the E.47 post-condition bundle. Methods the smoke never exercises
// remain unobtrusive no-ops.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;

/// Top-level factory the isolate transport calls inside the spawned worker to
/// build the memory the smoke runs against. Must be top-level so the host can
/// send it across the isolate boundary.
Future<TomBrainMemory> spawnSmokeMemory() async => SmokeMemory();

/// An in-isolate recording [TomBrainMemory] for the smoke harness.
///
/// Opens cleanly, records every persist / edge / stack push / opened trail, and
/// projects the running tallies onto a [MemoryStats] through [stats] — the one
/// read-back path that marshals across the isolate boundary back to the host.
/// Recall returns empty (no seeded nodes), so the `answer_with_memory_v1`
/// procedure takes its cold path. Top-level so it is reachable in the spawned
/// isolate.
final class SmokeMemory implements TomBrainMemory {
  /// Persisted-node count keyed by `NodeDraft.typeName` (`Event`,
  /// `Conclusion`, `InterestItem`, `ProcedureRun`, …).
  final Map<String, int> _nodeCountByType = <String, int>{};

  /// Edge count keyed by `EdgeType.wireName` (`produced_by`, `derived_from`,
  /// …).
  final Map<String, int> _edgeCountByType = <String, int>{};

  /// Persisted nodes, kept so [get] can resolve a just-persisted id (the run
  /// recorder reads its inflight marker back).
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};

  final _RecordingStackApi _stacks = _RecordingStackApi();

  /// Count of trails opened — the smoke's proxy for "a run wrote a trail".
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
      createdAt: DateTime.now().toUtc(),
    );
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
    _edgeCountByType.update(type.wireName, (c) => c + 1, ifAbsent: () => 1);
    return EdgeId.generate();
  }

  @override
  Future<RecallResult> recall(RecallQuery query) async => const RecallResult(
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
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async =>
      const <Edge>[];

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

/// A recording [StackApi] — tallies pushes per stack so [SmokeMemory.stats]
/// can report `stackSizes` (the smoke asserts the cold-path `interests` push).
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
  Future<List<StackSummary>> list() async => const <StackSummary>[];

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
