// A.78 — TomBrainMemoryClient contract test.
//
// Locks the consumer-facing interface that Plan step A.78 lands:
//
//   * `TomBrainMemoryClient` abstract class — the substitutable
//     contract every brain component talks to. Mirrors
//     `memory_specification.md` § 3.1 with no surface drift from
//     `TomBrainMemory`.
//   * `TomBrainMemory extends TomBrainMemoryClient` — the in-
//     process marker base class is a `TomBrainMemoryClient`.
//
// The test is black-box / contract-only. It does not instantiate
// a `SqliteTomBrainMemory` (the concrete v1 implementation lands
// at A.28+); it uses a no-op `_FakeMemoryClient` to assert the
// *shape* of the client surface and confirm the interface is
// implementable without renames, missing methods, or shifted
// return types.
//
// If a future plan step renames a method, drops a parameter, or
// shifts a return type, `_FakeMemoryClient` stops compiling and
// this test fails before any behavioural test runs. The same
// shape is enforced for `TomBrainMemory` by the existing
// `api_shape_test.dart` (A.24); this file enforces it at the
// `TomBrainMemoryClient` layer, which the isolate adapter (A.80)
// and the A.89 black-box conformance suite will both rely on.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        NodeId,
        ProcedureStatus,
        StackEntryId,
        TrailId,
        Vec,
        WriteBudget;
import 'package:test/test.dart';

void main() {
  group('A.78 TomBrainMemoryClient surface', () {
    test('a fake implementation of every method compiles', () {
      // The *act of constructing* `_FakeMemoryClient` is the
      // contract check — if any abstract member is missing or
      // its signature shifted, this test would not load.
      final TomBrainMemoryClient client = _FakeMemoryClient();
      expect(client, isA<TomBrainMemoryClient>());
    });

    test('stacks getter returns a StackApi', () {
      final TomBrainMemoryClient client = _FakeMemoryClient();
      expect(client.stacks, isA<StackApi>());
    });

    test('migrations getter returns a MigrationApi', () {
      final TomBrainMemoryClient client = _FakeMemoryClient();
      expect(client.migrations, isA<MigrationApi>());
    });

    test('events() returns a Stream<MemoryEvent>', () {
      final TomBrainMemoryClient client = _FakeMemoryClient();
      expect(client.events(), isA<Stream<MemoryEvent>>());
    });
  });

  group('A.78 TomBrainMemory IS-A TomBrainMemoryClient', () {
    test(
      'a concrete-shape in-process implementation is assignable '
      'to TomBrainMemoryClient',
      () {
        final TomBrainMemory inProcess = _FakeInProcessMemory();
        // The compile-time success of this assignment is the
        // load-bearing assertion: if `TomBrainMemory` ever stops
        // implementing `TomBrainMemoryClient`, the next line
        // would fail to compile.
        final TomBrainMemoryClient client = inProcess;
        expect(client, isA<TomBrainMemoryClient>());
        expect(client, isA<TomBrainMemory>());
      },
    );

    test('TomBrainMemory adds no extra abstract surface for v1', () {
      // A.78 reserves the seam for in-process-only fast paths,
      // but ships none. A future addition that requires fakes
      // implementing `TomBrainMemory` (and not just the client)
      // would fail to instantiate `_FakeInProcessMemory` unless
      // overridden — this test would surface that change as a
      // compile failure here, prompting an intentional
      // documentation update.
      final TomBrainMemory inProcess = _FakeInProcessMemory();
      expect(inProcess, isA<TomBrainMemory>());
    });
  });
}

/// Minimal no-op implementation used as a *compile-time*
/// assertion that `TomBrainMemoryClient`'s shape can be honoured.
///
/// Mirrors the `_FakeMemory` shape in `api_shape_test.dart` so
/// that the two surfaces stay in lockstep — surface drift between
/// `TomBrainMemoryClient` and `TomBrainMemory` will break exactly
/// one of these tests.
class _FakeMemoryClient implements TomBrainMemoryClient {
  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> checkpoint() async {}

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
  Future<void> recordAccess(List<NodeId> ids, {String? producer}) async {}

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {}

  @override
  Future<void> promote(NodeId id, PromotionReason reason) async {}

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {}

  @override
  Future<void> updateProcedureMetrics(
    NodeId id, {
    ProcedureStatus? status,
    double? successRate,
    int? runCount,
    DateTime? lastRunAt,
  }) async {}

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
  Future<RecallResult> recall(RecallQuery query) async =>
      const RecallResult(nodes: <Node>[], report: _emptyReport);

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async =>
      const RecallResult(nodes: <Node>[], report: _emptyReport);

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
  StackApi get stacks => _FakeStackApi();

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async => TrailId.generate();

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {}

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {}

  @override
  Stream<TrailEntry> readTrail(TrailId id) => const Stream<TrailEntry>.empty();

  @override
  MigrationApi get migrations => _FakeMigrationApi();

  @override
  Stream<MemoryEvent> events() => const Stream<MemoryEvent>.empty();

  @override
  Future<MemoryStats> stats() async => MemoryStats.empty;
}

/// Mirror-implementation of [TomBrainMemory] (not just the
/// client). Proves that the in-process marker class can still be
/// concretely realised on top of `TomBrainMemoryClient` without
/// re-declaring abstract members.
class _FakeInProcessMemory extends _FakeMemoryClient implements TomBrainMemory {
  // The in-process marker adds only the profile-administration seam
  // (`profiles` / `currentProfile`) over the client. The wire-capable
  // `recallMulti` lives on `TomBrainMemoryClient` and is inherited.
  @override
  MemoryProfileRegistry get profiles => _FakeProfileRegistry();

  @override
  String? get currentProfile => null;
}

class _FakeProfileRegistry implements MemoryProfileRegistry {
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

const RecallReport _emptyReport = RecallReport(
  candidatesPerMode: <RecallMode, int>{},
  fusionStrategy: FusionStrategy.rrf,
  diversityStrategy: DiversityStrategy.mmr,
  elapsedMs: 0,
  embeddingsCallouts: 0,
  reRankInvoked: false,
  degraded: false,
);

class _FakeStackApi implements StackApi {
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

class _FakeMigrationApi implements MigrationApi {
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
