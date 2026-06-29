// A.79 — TomBrainMemoryIsolateHost.
//
// Exercises the host's lifecycle (spawn → ready → shutdown) and
// the dispatch boundary (Ping/Pong, OpenMemory/CloseMemory,
// MemoryStats dispatch) against a top-level fake `TomBrainMemory`
// hosted inside the spawned isolate.
//
// What this test enforces:
//
//   1. The host spawns a real Dart isolate via `TomWorker.spawn`
//      (the worker's `isReady` becomes true).
//   2. Lifecycle envelopes (`Ping`, `OpenMemory`, `CloseMemory`)
//      round-trip cleanly.
//   3. The dispatch-proof envelope (`MemoryStatsRequest`) reaches
//      the held `TomBrainMemory` instance and the response carries
//      the fake's `stats()` payload back unchanged.
//   4. Errors inside the executor surface as
//      `IsolateBoundaryException` host-side (e.g. calling
//      `stats()` before `OpenMemory`).
//   5. Shutdown closes the isolate cleanly even when memory is
//      still open, by sending a `CloseMemoryRequest` first.
//
// What this test does *not* enforce (those land later):
//
//   - The full envelope catalogue (A.81/A.82).
//   - Cancellation and backpressure semantics (A.81/A.82).
//   - Multi-machine variants (A.85).
//
// Why a top-level fake:
//
//   The factory function reference crosses the isolate boundary as
//   part of the `MemoryWorkerContext`. Dart's isolate runtime
//   forbids closures captured from the spawning isolate. The fake
//   below is a top-level class, the factory function is top-level,
//   and both are reachable in the spawned isolate (which loads the
//   same Dart program).

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        NodeId,
        ProcedureStatus,
        StackEntryId,
        TomBrainMemoryClient,
        TrailId,
        Vec,
        WriteBudget;
import 'package:test/test.dart';

// ─── Top-level fake + factory (must be top-level to be sendable) ──

/// Top-level factory consumed by the isolate. Must not capture any
/// closure state from the spawning isolate.
Future<TomBrainMemory> spawnFakeMemory() async {
  return _IsolateSideFakeMemory();
}

/// Factory variant that yields a fake whose `stats()` returns a
/// distinctive (non-empty) snapshot — used by the dispatch-proof
/// test so the response payload is visibly different from
/// `MemoryStats.empty`.
Future<TomBrainMemory> spawnRichFakeMemory() async {
  return _IsolateSideFakeMemory.rich();
}

/// A fake `TomBrainMemory` whose `open`, `close`, and `stats`
/// implementations are observable from the test side via the
/// response payload — these are the methods A.79's executor wires
/// to envelopes. Every other method is a no-op (they are wired in
/// A.81).
final class _IsolateSideFakeMemory implements TomBrainMemory {
  final MemoryStats _statsPayload;

  _IsolateSideFakeMemory() : _statsPayload = MemoryStats.empty;

  _IsolateSideFakeMemory.rich()
      : _statsPayload = const MemoryStats(
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

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> checkpoint() async {}

  @override
  Future<MemoryStats> stats() async => _statsPayload;

  // ─── Every other method is a no-op — A.81 wires them ──────────

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
          embeddingsCallouts: 0,
          reRankInvoked: false,
          degraded: false,
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
  ) async =>
      throw UnimplementedError();

  @override
  Future<T> writeInProfile<T>(
    String name,
    Future<T> Function(TomBrainMemoryClient body) body,
  ) async =>
      throw UnimplementedError();
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

// ─── A minimal MemoryConfig instance used by the tests ───────────

MemoryConfig _fakeConfig() => MemoryConfig.forTesting(
      root: '/tmp/tom_brain_memory_a79_fake_unused',
    );

// ─── Tests ────────────────────────────────────────────────────────

void main() {
  group('A.79 TomBrainMemoryIsolateHost — lifecycle', () {
    test('spawn() makes the host ready', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      try {
        await host.spawn();
        expect(host.isReady, isTrue);
        expect(host.isClosed, isFalse);
      } finally {
        await host.shutdown();
      }
    });

    test('shutdown() closes the isolate cleanly', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      await host.spawn();
      await host.shutdown();
      // `isClosed` is the and-of (shutdown requested, worker closed).
      // We allow a short grace period for the worker close to settle.
      for (var i = 0; i < 50 && !host.isClosed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(host.isClosed, isTrue);
    });

    test('shutdown() is idempotent', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      await host.spawn();
      await host.shutdown();
      await host.shutdown(); // second call is a no-op
      expect(host.isClosed, isTrue);
    });

    test('spawn() after shutdown() throws StateError', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      await host.spawn();
      await host.shutdown();
      expect(() => host.spawn(), throwsStateError);
    });

    test('send() before spawn() throws StateError', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      expect(
        () => host.send<PongResponse>(
          const PingRequest(hostWallClockMs: 0),
        ),
        throwsStateError,
      );
    });
  });

  group('A.79 TomBrainMemoryIsolateHost — envelope dispatch', () {
    test('PingRequest round-trips to PongResponse', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      try {
        await host.spawn();
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final reply = await host.send<PongResponse>(
          PingRequest(hostWallClockMs: t0),
        );
        expect(reply.echoedHostWallClockMs, equals(t0));
        // Isolate clock is the same wall clock; reply timestamp
        // must be >= request timestamp.
        expect(reply.isolateWallClockMs, greaterThanOrEqualTo(t0));
      } finally {
        await host.shutdown();
      }
    });

    test('OpenMemoryRequest drives the in-isolate memory.open()', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      try {
        await host.spawn();
        expect(host.isMemoryOpen, isFalse);
        await host.openMemory(_fakeConfig());
        expect(host.isMemoryOpen, isTrue);
      } finally {
        await host.shutdown();
      }
    });

    test(
      'MemoryStatsRequest reaches the held memory and returns the snapshot',
      () async {
        // Use the *rich* factory so the response payload is visibly
        // non-empty — proves the bytes round-tripped, not just that
        // any MemoryStats came back.
        final host =
            TomBrainMemoryIsolateHost(factory: spawnRichFakeMemory);
        try {
          await host.spawn();
          await host.openMemory(_fakeConfig());
          final reply = await host.send<MemoryStatsResponse>(
            const MemoryStatsRequest(),
          );
          expect(
            reply.stats.nodeCountByType,
            equals({'Event': 42, 'Concept': 7}),
          );
          expect(reply.stats.edgeCountByType, equals({'mentions': 99}));
          expect(reply.stats.stackSizes, equals({'questions_open': 3}));
          expect(reply.stats.trailCount, equals(5));
          expect(reply.stats.trailBytes, equals(1024));
        } finally {
          await host.shutdown();
        }
      },
    );

    test(
      'MemoryStatsRequest before OpenMemoryRequest surfaces as '
      'IsolateBoundaryException',
      () async {
        final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
        try {
          await host.spawn();
          await expectLater(
            host.send<MemoryStatsResponse>(const MemoryStatsRequest()),
            throwsA(
              isA<IsolateBoundaryException>().having(
                (e) => e.exceptionType,
                'exceptionType',
                'StateError',
              ),
            ),
          );
        } finally {
          await host.shutdown();
        }
      },
    );

    test('shutdown with open memory sends CloseMemory first', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      await host.spawn();
      await host.openMemory(_fakeConfig());
      await host.shutdown();
      expect(host.isMemoryOpen, isFalse);
    });

    test('explicit closeMemory() then shutdown() works', () async {
      final host = TomBrainMemoryIsolateHost(factory: spawnFakeMemory);
      try {
        await host.spawn();
        await host.openMemory(_fakeConfig());
        await host.closeMemory();
        expect(host.isMemoryOpen, isFalse);
      } finally {
        await host.shutdown();
      }
    });
  });
}
