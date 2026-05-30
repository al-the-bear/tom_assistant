// A.24 API-shape conformance test.
//
// Locks the public surface that Plan step A.24 lands:
//
//   * `TomBrainMemory` abstract class — every method named in
//     `memory_specification.md` § 3.1, with the expected
//     parameter/return shapes, surfaced through the top-level
//     `package:tom_brain_memory/tom_brain_memory.dart` barrel.
//   * `MemoryConfig` and its sub-configs — spec-aligned defaults,
//     the `forTesting` factory, the path-resolver getters under
//     `<root>/`.
//   * The supporting value types every method signature mentions —
//     `Scope`, `DemotionReason`, `ForgetReason`, `NodeDraft`,
//     `Node`, `EdgeType`, `EdgeDirection`, `RecallQuery`,
//     `RecallResult`, `StreamQuery`, `ClassificationTarget`,
//     `ClassificationResult`, `NodeTypeDecl`, `TrailEntry`,
//     `TrailOutcome`, `MemoryEvent`, `MemoryStats`.
//
// The test is black-box / contract-only. It does not instantiate
// `TomBrainMemory` (there is no concrete implementation yet); it
// uses a no-op `_FakeMemory` implementation to assert the *shape*
// of the surface and confirm the abstract class is implementable
// without renames, missing methods, or shifted return types.
//
// If a future plan step renames a method, drops a parameter, or
// shifts a return type, `_FakeMemory` stops compiling and this
// test fails before any behavioural test runs.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:test/test.dart';

void main() {
  group('A.24 TomBrainMemory abstract surface', () {
    test('a fake implementation of every method compiles', () {
      // The *act of constructing* `_FakeMemory` is the contract
      // check — if any abstract member is missing or its signature
      // shifted, this test would not load. We additionally type-
      // check the reference as `TomBrainMemory` to lock the
      // inheritance relationship.
      final TomBrainMemory memory = _FakeMemory();
      expect(memory, isA<TomBrainMemory>());
    });

    test('stacks getter returns a StackApi', () {
      final TomBrainMemory memory = _FakeMemory();
      expect(memory.stacks, isA<StackApi>());
    });

    test('migrations getter returns a MigrationApi', () {
      final TomBrainMemory memory = _FakeMemory();
      expect(memory.migrations, isA<MigrationApi>());
    });

    test('events() returns a Stream<MemoryEvent>', () {
      final TomBrainMemory memory = _FakeMemory();
      expect(memory.events(), isA<Stream<MemoryEvent>>());
    });
  });

  group('A.24 MemoryConfig defaults', () {
    test('forTesting builds a usable config with sensible defaults', () {
      final cfg = MemoryConfig.forTesting(root: '/tmp/brain');
      expect(cfg.root, equals('/tmp/brain'));
      expect(cfg.sqliteVec, isA<SqliteVecConfig>());
      expect(cfg.retrieval, isA<RetrievalConfig>());
      expect(cfg.trails, isA<TrailsConfig>());
      expect(cfg.classification, isA<ClassificationConfig>());
      expect(cfg.budgets, isA<BudgetsConfig>());
      expect(cfg.mcpServer, isA<McpServerConfig>());
      expect(cfg.replication, isA<ReplicationConfig>());
    });

    test('forTesting rejects an empty root', () {
      expect(
        () => MemoryConfig.forTesting(root: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('retrieval defaults match spec § 6.2 (rrfK=60, mmrLambda=0.7)', () {
      const cfg = RetrievalConfig();
      expect(cfg.rrfK, equals(60));
      expect(cfg.mmrLambda, closeTo(0.7, 1e-9));
    });

    test('classification defaults match spec § 7.2', () {
      const cfg = ClassificationConfig();
      expect(cfg.minConfidence, closeTo(0.55, 1e-9));
      expect(cfg.minMargin, closeTo(0.05, 1e-9));
      expect(cfg.coldStartMinExamples, equals(8));
    });

    test('trails defaults: fsync on, 7-day compress, 90-day cold', () {
      const cfg = TrailsConfig();
      expect(cfg.fsyncEveryAppend, isTrue);
      expect(cfg.compressAfter, equals(const Duration(days: 7)));
      expect(cfg.coldStorageAfter, equals(const Duration(days: 90)));
    });

    test('default write-budget caps match spec § 9.3', () {
      const cfg = DefaultWriteBudgetConfig();
      expect(cfg.maxNodes, equals(5000));
      expect(cfg.maxEdges, equals(20000));
      expect(cfg.maxStackEntries, equals(1000));
    });

    test('MCP server defaults to disabled', () {
      const cfg = McpServerConfig();
      expect(cfg.enabled, isFalse);
      expect(cfg.bindAddress, isNull);
      expect(cfg.bindPort, isNull);
      expect(cfg.bearerAuthRealm, isNull);
    });

    test('replication defaults to authority role', () {
      const cfg = ReplicationConfig();
      expect(cfg.role, equals(ReplicationRole.authority));
      expect(cfg.writeLogDir, isNull);
      expect(cfg.authorityEndpoint, isNull);
    });

    test('replication role enum has authority/worker/mirror', () {
      // Spec § 10 topology — three roles, in this order.
      expect(
        ReplicationRole.values,
        equals(<ReplicationRole>[
          ReplicationRole.authority,
          ReplicationRole.worker,
          ReplicationRole.mirror,
        ]),
      );
    });
  });

  group('A.24 MemoryConfig path resolution', () {
    test('resolves DB and folder paths under root', () {
      final cfg = MemoryConfig.forTesting(root: '/var/brain');
      // The exact separator depends on the host platform; the
      // contract is that the last segment is correct and that the
      // path starts with the configured root.
      expect(cfg.memoryDbPath, startsWith('/var/brain'));
      expect(cfg.memoryDbPath, endsWith('memory.db'));
      expect(cfg.vectorsDbPath, endsWith('vectors.db'));
      expect(cfg.trailsDir, endsWith('trails'));
      expect(cfg.tombstonesDir, endsWith('tombstones'));
      expect(cfg.checkpointsDir, endsWith('checkpoints'));
    });
  });

  group('A.24 supporting value types', () {
    test('EdgeType closed alphabet matches spec § 4.2 (12 kinds)', () {
      // The spec enumerates exactly twelve edge kinds. Renaming or
      // adding one is a spec change, not a code change.
      expect(EdgeType.values, hasLength(12));
      expect(
        EdgeType.values.map((e) => e.wireName).toSet(),
        equals(<String>{
          'mentions',
          'derived_from',
          'superseded_by',
          'satisfied_by',
          'motivates',
          'evidence_for',
          'contradicts',
          'part_of',
          'produced_by',
          'authored_by',
          'targets',
          'caused_by',
        }),
      );
    });

    test('EdgeType.fromWireName round-trips every value', () {
      for (final t in EdgeType.values) {
        expect(EdgeType.fromWireName(t.wireName), equals(t));
      }
    });

    test('EdgeDirection enum has outgoing/incoming/both', () {
      expect(
        EdgeDirection.values,
        equals(<EdgeDirection>[
          EdgeDirection.outgoing,
          EdgeDirection.incoming,
          EdgeDirection.both,
        ]),
      );
    });

    test('DemotionReason enum lists every spec-named reason', () {
      // Spec § 5.3 / § 9.4 / § 11.2 reasons.
      expect(
        DemotionReason.values.toSet(),
        equals(<DemotionReason>{
          DemotionReason.retentionHorizon,
          DemotionReason.prunerDecision,
          DemotionReason.supersession,
          DemotionReason.migrationArchive,
          DemotionReason.operatorOverride,
        }),
      );
    });

    test('ForgetReason enum lists every spec-named reason', () {
      // Spec § 4.1 (Tombstone) reasons.
      expect(
        ForgetReason.values.toSet(),
        equals(<ForgetReason>{
          ForgetReason.userRequested,
          ForgetReason.legalErasure,
          ForgetReason.scopeViolation,
        }),
      );
    });

    test('Scope constructor records producer + idempotency key', () {
      const s = Scope(producer: 'extractor:dream_v1:r_1', idempotencyKey: 'k');
      expect(s.producer, equals('extractor:dream_v1:r_1'));
      expect(s.idempotencyKey, equals('k'));
      expect(s.causedBy, isNull);
      expect(s.runId, isNull);
    });

    test('Scope.nonIdempotent sets idempotencyKey null', () {
      const s = Scope.nonIdempotent(producer: 'p', runId: 'r');
      expect(s.idempotencyKey, isNull);
      expect(s.runId, equals('r'));
    });

    test('ClassificationResult.unknown is the cold-start sentinel', () {
      const r = ClassificationResult.unknown();
      expect(r.decision, equals(ClassificationDecision.unknown));
      expect(r.bestMatch, isNull);
      expect(r.bestSimilarity, equals(0.0));
      expect(r.secondSimilarity, equals(0.0));
    });

    test('MemoryStats.empty has zeroed observables', () {
      const s = MemoryStats.empty;
      expect(s.nodeCountByType, isEmpty);
      expect(s.edgeCountByType, isEmpty);
      expect(s.stackSizes, isEmpty);
      expect(s.trailCount, equals(0));
      expect(s.trailBytes, equals(0));
      expect(s.recallLatencyPerMode, isEmpty);
      expect(s.classificationConfidenceHistogram, isEmpty);
      expect(s.migrationProgress, isEmpty);
    });

    test('LatencyHistogram.zero is a both-zero pair', () {
      const h = LatencyHistogram.zero;
      expect(h.p50Ms, equals(0.0));
      expect(h.p95Ms, equals(0.0));
    });
  });
}

/// Minimal no-op implementation used as a *compile-time* assertion
/// that `TomBrainMemory`'s shape can be honoured.
///
/// Every override is intentionally trivial — the value of this fake
/// is that adding, renaming, or shifting an abstract method on
/// `TomBrainMemory` makes this fake refuse to compile.
class _FakeMemory implements TomBrainMemory {
  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> checkpoint() async {}

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
  Future<TrailId> openTrail(ProcedureRunRef run) async =>
      TrailId.generate();

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
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
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
