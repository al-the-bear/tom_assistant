// D.43 — memory provisioning seam.
//
// Plan step D.43: "Adopt the `TomBrainMemoryIsolateHost` + `…Client`
// pair from Phase A. Wire the dispatcher to instantiate one
// isolate-hosted memory by default; allow in-process via config flag
// for tests."
//
// This suite drives `MemoryProvisioner.provision()` through its
// declared public surface (the dispatcher barrel) and proves:
//
//   1. Isolate transport (the default) spawns a real worker isolate,
//      opens memory inside it, and hands back a
//      `TomBrainMemoryIsolateClient` whose calls round-trip across the
//      boundary; `dispose()` shuts the worker down cleanly.
//   2. In-process transport (the config flag) uses the injected
//      `TomBrainMemoryClient` directly, opens it, and `dispose()`
//      closes it — no isolate spawned.
//   3. Transport parity: an identical call returns an identical result
//      through both transports (the D.53 parity claim).
//   4. `dispose()` is idempotent on both transports.
//
// Why a top-level fake memory + top-level factory:
//
//   The factory function reference crosses the isolate boundary as
//   part of the host's worker context. Dart forbids closures captured
//   from the spawning isolate, so the factory must be top-level and
//   the fake it returns must be a top-level class reachable in the
//   spawned isolate (which loads the same Dart program). This mirrors
//   the Phase A `a79_isolate_host_test.dart` convention.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        MemoryProvisioner,
        MemoryProvisioningConfig,
        MemoryTransport,
        ProvisionedMemory;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, ProcedureStatus, StackEntryId, TrailId, Vec, WriteBudget;
import 'package:test/test.dart';

// ─── Top-level fake + factory (must be top-level to be sendable) ──

/// Top-level factory consumed by the isolate transport. Returns a
/// *rich* fake whose `stats()` carries a distinctive payload so the
/// round-trip is visibly non-empty.
Future<TomBrainMemory> spawnRichFakeMemory() async =>
    RecordingFakeMemory.rich();

/// The same distinctive snapshot the isolate-side fake reports, so
/// the parity test can assert an in-process instance and an isolate
/// instance agree.
const MemoryStats _richStats = MemoryStats(
  nodeCountByType: <String, int>{'Event': 42, 'Concept': 7},
  edgeCountByType: <String, int>{'mentions': 99},
  stackSizes: <String, int>{'questions_open': 3},
  trailCount: 5,
  trailBytes: 1024,
  recallLatencyPerMode: <String, LatencyHistogram>{},
  classificationConfidenceHistogram: <String, int>{},
  migrationProgress: <String, double>{},
  lifecycleEventCounts: <String, int>{},
  accessCountHistogram: <String, int>{},
);

/// A fake `TomBrainMemory` that records its `open`/`close` lifecycle
/// (observable for the in-process transport, where the instance is
/// constructed in the test isolate) and answers `stats()` with a
/// fixed snapshot. Every other method is a no-op.
final class RecordingFakeMemory implements TomBrainMemory {
  final MemoryStats _statsPayload;

  /// Captured `root` of the config the provisioner opened with.
  /// `null` until `open` runs. Only meaningful for the in-process
  /// transport (the isolate-side instance lives in another isolate).
  String? openedWithRoot;

  /// Number of times `close()` has been called.
  int closeCount = 0;

  RecordingFakeMemory() : _statsPayload = MemoryStats.empty;
  RecordingFakeMemory.rich() : _statsPayload = _richStats;

  @override
  Future<void> open(MemoryConfig config) async {
    openedWithRoot = config.root;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Future<void> checkpoint() async {}

  @override
  Future<MemoryStats> stats() async => _statsPayload;

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
  Future<void> recordAccess(List<NodeId> ids, {String? producer}) async {}

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {}

  @override
  Future<void> promote(NodeId id, PromotionReason reason) async {}

  @override
  Future<void> updateProcedureMetrics(
    NodeId id, {
    ProcedureStatus? status,
    double? successRate,
    int? runCount,
    DateTime? lastRunAt,
  }) async {}

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
  MemoryProfileRegistry get profiles => _NoopProfileRegistry();

  @override
  String? get currentProfile => null;
}

class _NoopProfileRegistry implements MemoryProfileRegistry {
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
  ) =>
      throw UnimplementedError(
        'readInProfile is not exercised by this double.',
      );

  @override
  Future<T> writeInProfile<T>(
    String name,
    Future<T> Function(TomBrainMemoryClient body) body,
  ) =>
      throw UnimplementedError(
        'writeInProfile is not exercised by this double.',
      );
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

// ─── Config helpers ──────────────────────────────────────────────

MemoryConfig _config(String root) => MemoryConfig.forTesting(root: root);

void main() {
  group('D.43-1 isolate transport (the default)', () {
    test('provisions a ready, opened isolate-hosted client', () async {
      final provisioner = MemoryProvisioner(
        MemoryProvisioningConfig.isolate(
          factory: spawnRichFakeMemory,
          memoryConfig: _config('/tmp/tom_brain_d43_isolate_unused'),
        ),
      );
      late final ProvisionedMemory provisioned;
      try {
        provisioned = await provisioner.provision();
        expect(provisioned.transport, MemoryTransport.isolate);
        expect(provisioned.host, isNotNull);
        expect(provisioned.host!.isReady, isTrue);
        expect(provisioned.host!.isMemoryOpen, isTrue);
        expect(provisioned.client, isA<TomBrainMemoryIsolateClient>());
      } finally {
        await provisioned.dispose();
      }
    });

    test('the client round-trips a call across the boundary', () async {
      final provisioner = MemoryProvisioner(
        MemoryProvisioningConfig.isolate(
          factory: spawnRichFakeMemory,
          memoryConfig: _config('/tmp/tom_brain_d43_isolate_unused'),
        ),
      );
      final provisioned = await provisioner.provision();
      try {
        final stats = await provisioned.client.stats();
        // The rich fake lives in the spawned isolate; receiving its
        // distinctive payload proves the client opened + wired the
        // worker, not just that any MemoryStats came back.
        expect(stats.nodeCountByType, equals({'Event': 42, 'Concept': 7}));
        expect(stats.edgeCountByType, equals({'mentions': 99}));
        expect(stats.trailCount, equals(5));
      } finally {
        await provisioned.dispose();
      }
    });

    test('dispose() shuts the worker down cleanly', () async {
      final provisioner = MemoryProvisioner(
        MemoryProvisioningConfig.isolate(
          factory: spawnRichFakeMemory,
          memoryConfig: _config('/tmp/tom_brain_d43_isolate_unused'),
        ),
      );
      final provisioned = await provisioner.provision();
      final host = provisioned.host!;
      await provisioned.dispose();
      expect(host.isMemoryOpen, isFalse);
      for (var i = 0; i < 50 && !host.isClosed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(host.isClosed, isTrue);
    });

    test('dispose() is idempotent', () async {
      final provisioner = MemoryProvisioner(
        MemoryProvisioningConfig.isolate(
          factory: spawnRichFakeMemory,
          memoryConfig: _config('/tmp/tom_brain_d43_isolate_unused'),
        ),
      );
      final provisioned = await provisioner.provision();
      await provisioned.dispose();
      await provisioned.dispose(); // second call is a no-op
      expect(provisioned.host!.isMemoryOpen, isFalse);
    });
  });

  group('D.43-2 in-process transport (the config flag)', () {
    test('uses the injected client directly, opens it, no isolate', () async {
      final fake = RecordingFakeMemory.rich();
      final provisioner = MemoryProvisioner(
        MemoryProvisioningConfig.inProcess(
          client: fake,
          memoryConfig: _config('/tmp/tom_brain_d43_in_process'),
        ),
      );
      final provisioned = await provisioner.provision();
      try {
        expect(provisioned.transport, MemoryTransport.inProcess);
        expect(provisioned.host, isNull);
        // The exact instance is handed back — no wrapping.
        expect(identical(provisioned.client, fake), isTrue);
        // The provisioner opened it with the config it was given.
        expect(fake.openedWithRoot, '/tmp/tom_brain_d43_in_process');
      } finally {
        await provisioned.dispose();
      }
    });

    test('dispose() closes the in-process client', () async {
      final fake = RecordingFakeMemory.rich();
      final provisioner = MemoryProvisioner(
        MemoryProvisioningConfig.inProcess(
          client: fake,
          memoryConfig: _config('/tmp/tom_brain_d43_in_process'),
        ),
      );
      final provisioned = await provisioner.provision();
      expect(fake.closeCount, 0);
      await provisioned.dispose();
      expect(fake.closeCount, 1);
    });

    test('dispose() is idempotent (closes exactly once)', () async {
      final fake = RecordingFakeMemory.rich();
      final provisioner = MemoryProvisioner(
        MemoryProvisioningConfig.inProcess(
          client: fake,
          memoryConfig: _config('/tmp/tom_brain_d43_in_process'),
        ),
      );
      final provisioned = await provisioner.provision();
      await provisioned.dispose();
      await provisioned.dispose();
      expect(fake.closeCount, 1);
    });
  });

  group('D.43-3 transport parity', () {
    test('an identical call returns an identical result on both '
        'transports', () async {
      // In-process: the rich fake, constructed in this isolate.
      final inProc = MemoryProvisioner(
        MemoryProvisioningConfig.inProcess(
          client: RecordingFakeMemory.rich(),
          memoryConfig: _config('/tmp/tom_brain_d43_parity_in'),
        ),
      );
      // Isolate: the same rich fake, constructed in the spawned isolate.
      final iso = MemoryProvisioner(
        MemoryProvisioningConfig.isolate(
          factory: spawnRichFakeMemory,
          memoryConfig: _config('/tmp/tom_brain_d43_parity_iso'),
        ),
      );
      final inProcMem = await inProc.provision();
      final isoMem = await iso.provision();
      try {
        final inProcStats = await inProcMem.client.stats();
        final isoStats = await isoMem.client.stats();
        expect(isoStats.nodeCountByType, equals(inProcStats.nodeCountByType));
        expect(isoStats.edgeCountByType, equals(inProcStats.edgeCountByType));
        expect(isoStats.stackSizes, equals(inProcStats.stackSizes));
        expect(isoStats.trailCount, equals(inProcStats.trailCount));
        expect(isoStats.trailBytes, equals(inProcStats.trailBytes));
      } finally {
        await inProcMem.dispose();
        await isoMem.dispose();
      }
    });
  });
}
