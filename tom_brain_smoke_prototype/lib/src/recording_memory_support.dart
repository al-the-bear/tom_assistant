// Shared recording machinery for the two smoke `TomBrainMemory` doubles.
//
// [SmokeMemory] (isolate transport, tallies-only) and [InspectableSmokeMemory]
// (in-process transport, full graph for MCP read-back) are the same recording
// store read back two ways. They diverge in exactly four members — `persist`,
// `edge`, `recall`, `edgesOf` — and shared ~70 % of their body verbatim before
// this base was extracted: the recording fields, `stats()`, `get`/`getMany`,
// the trail surface, and the long "every other method is an unused no-op" tail.
//
// [RecordingMemoryBase] owns all of that shared surface and leaves the four
// projecting members abstract; each double overrides only those. The shared
// [RecordingStackApi] and [NoopMigrationApi] replace the two byte-identical
// copies that used to live in each double's file.
//
// ── Why these symbols are top-level (and not private) ────────────────
//
// [SmokeMemory] crosses the isolate boundary (the smoke provisions memory over
// the production isolate transport via the top-level `spawnSmokeMemory`
// factory). Dart forbids closures captured from the spawning isolate, so the
// class and everything it extends must be top-level, reachable in the spawned
// isolate (which loads the same program). Library-private (`_`-prefixed)
// symbols cannot be shared across files, so these are public package symbols —
// `lib/src/` and unexported from the barrel, so they are not part of the
// package's public API.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;

/// The shared recording surface of the two smoke memory doubles.
///
/// Owns the recording state and every member both doubles implement
/// identically: lifecycle no-ops, [stats] projection, [get] / [getMany], the
/// stack getter, the trail surface (which only tallies), and the long tail of
/// methods the smoke never exercises. Subclasses override only the four
/// members that genuinely diverge: [persist], [edge], [recall], and [edgesOf].
abstract class RecordingMemoryBase implements TomBrainMemory {
  /// Persisted nodes keyed by id — kept so [get] can resolve a just-persisted
  /// id (the run recorder reads its inflight marker back). Subclass [persist]
  /// records into this map.
  final Map<NodeId, Node> nodes = <NodeId, Node>{};

  /// Persisted-node count keyed by `NodeDraft.typeName` (`Event`,
  /// `Conclusion`, `InterestItem`, `ProcedureRun`, …).
  final Map<String, int> nodeCountByType = <String, int>{};

  /// Edge count keyed by `EdgeType.wireName` (`produced_by`, `derived_from`,
  /// …).
  final Map<String, int> edgeCountByType = <String, int>{};

  /// Recording stack store — tallies pushes per stack and (for the inspectable
  /// double) serves the MCP `memory.stack.list` / `peek` views.
  final RecordingStackApi recordingStacks = RecordingStackApi();

  /// Count of trails opened — the smoke's proxy for "a run wrote a trail".
  int trailCount = 0;

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> checkpoint() async {}

  @override
  Future<MemoryStats> stats() async => MemoryStats(
        nodeCountByType: Map<String, int>.of(nodeCountByType),
        edgeCountByType: Map<String, int>.of(edgeCountByType),
        stackSizes: recordingStacks.sizes(),
        trailCount: trailCount,
        trailBytes: 0,
        recallLatencyPerMode: const <String, LatencyHistogram>{},
        classificationConfidenceHistogram: const <String, int>{},
        migrationProgress: const <String, double>{},
      );

  @override
  Future<Node?> get(NodeId id) async => nodes[id];

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async =>
      <Node>[for (final id in ids) if (nodes[id] != null) nodes[id]!];

  @override
  StackApi get stacks => recordingStacks;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    trailCount++;
    return TrailId.generate();
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {}

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {}

  @override
  Stream<TrailEntry> readTrail(TrailId id) => const Stream<TrailEntry>.empty();

  // ─── The four projecting members the doubles diverge on ───────

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope});

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  });

  @override
  Future<RecallResult> recall(RecallQuery query);

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  });

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
  MigrationApi get migrations => NoopMigrationApi();

  @override
  Stream<MemoryEvent> events() => const Stream<MemoryEvent>.empty();

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      const RecallResult(
        nodes: <Node>[],
        report: RecallReport(
          candidatesPerMode: <RecallMode, int>{},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          elapsedMs: 0,
        ),
      );

  @override
  MemoryProfileRegistry get profiles => NoopProfileRegistry();

  @override
  String? get currentProfile => null;
}

/// A no-op [MemoryProfileRegistry] shared by both smoke memory doubles.
/// The smoke harness never materialises a profile; the registry exists
/// only so the doubles concretely realise the in-process marker.
class NoopProfileRegistry implements MemoryProfileRegistry {
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
}

/// A recording [StackApi] shared by both smoke memory doubles.
///
/// Tallies pushes per stack (so [SmokeMemory.stats] can report `stackSizes`)
/// and projects real [StackSummary] rows through [list] (so the inspectable
/// double serves the MCP `memory.stack.list` view). The tallies-only double
/// simply never calls [list], so one implementation serves both.
class RecordingStackApi implements StackApi {
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

/// A no-op [MigrationApi] shared by both smoke memory doubles — neither smoke
/// exercises migrations.
class NoopMigrationApi implements MigrationApi {
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
