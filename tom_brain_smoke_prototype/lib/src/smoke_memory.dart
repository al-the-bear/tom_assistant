// SmokeMemory + spawnSmokeMemory — an in-isolate `TomBrainMemory` double for
// the end-to-end smoke (E.46).
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
// For the E.46 stand-up smoke every method is an unobtrusive no-op: the test
// asserts the process *stands up*, not that a run touched memory (a run
// roundtrip is E.47). Later E.10 steps may swap in a recording variant.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;

/// Top-level factory the isolate transport calls inside the spawned worker to
/// build the memory the smoke runs against. Must be top-level so the host can
/// send it across the isolate boundary.
Future<TomBrainMemory> spawnSmokeMemory() async => SmokeMemory();

/// An in-isolate [TomBrainMemory] double for the smoke harness. Opens cleanly,
/// reports empty stats, and treats every store operation as a no-op — enough to
/// boot the process and stand it up. Top-level so it is reachable in the spawned
/// isolate.
final class SmokeMemory implements TomBrainMemory {
  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> checkpoint() async {}

  @override
  Future<MemoryStats> stats() async => MemoryStats.empty;

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
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async =>
      NodeId.generate();

  @override
  Future<Node?> get(NodeId id) async => null;

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async => const <Node>[];

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {}

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {}

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async =>
      EdgeId.generate();

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
  StackApi get stacks => _NoopStackApi();

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async => TrailId.generate();

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {}

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {}

  @override
  Stream<TrailEntry> readTrail(TrailId id) => const Stream<TrailEntry>.empty();

  @override
  MigrationApi get migrations => _NoopMigrationApi();

  @override
  Stream<MemoryEvent> events() => const Stream<MemoryEvent>.empty();
}

class _NoopStackApi implements StackApi {
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
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async =>
      StackEntryId.generate();

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async =>
      const <StackEntry>[];

  @override
  Future<StackEntry?> pop(String name) async => null;

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
