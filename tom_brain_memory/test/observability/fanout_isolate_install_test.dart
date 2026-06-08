// Isolate-side install of `FanoutLogOutput` (`tom_brain_logging.md`
// §5.1 / §10 step #3 — "host + isolate").
//
// The memory isolate runs a *separate* `tomLog` from the host, so the
// host's file sink never reaches it. `MemoryWorkerContext.logRootPath`
// (threaded from `MemoryProvisioningConfig.isolate(isolateLogRootPath:)`)
// is what lets the isolate install its own `FanoutLogOutput` in
// `initializeIsolate()` so its `tom_brain.memory.*` lines land in the
// same `brain.log` + `components/memory.log` as the host's.
//
// This test proves that end-to-end across a real isolate boundary:
//
//   1. Spawn a host with a `logRootPath` pointing at a temp dir.
//   2. Open memory — the top-level factory runs *inside* the isolate
//      and emits a tagged headline line (`MemoryLog.store.status`).
//   3. Assert the isolate's own `FanoutLogOutput` wrote that line to
//      both `brain.log` (headline routing) and
//      `components/memory.log` (component routing).
//
// The factory must be top-level (it crosses the isolate boundary) and
// must not capture closure state — it logs a fixed marker string the
// host side then greps for.

import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;
import 'package:test/test.dart';

/// The marker the in-isolate factory logs and the host side asserts on.
const String _kMarker = 'fanout-isolate-install-marker';

/// Top-level factory — runs inside the spawned isolate. Emits a tagged
/// `tom_brain.memory.store` headline line so the isolate's installed
/// `FanoutLogOutput` routes it to both `brain.log` and
/// `components/memory.log`, then returns a no-op fake memory.
Future<TomBrainMemory> spawnLoggingFakeMemory() async {
  MemoryLog.store.status(_kMarker);
  return _NoopMemory();
}

void main() {
  group('FanoutLogOutput — isolate-side install (§10 step #3)', () {
    late Directory logRoot;

    setUp(() {
      logRoot = Directory.systemTemp.createTempSync('tbm_fanout_iso_');
    });

    tearDown(() {
      if (logRoot.existsSync()) {
        logRoot.deleteSync(recursive: true);
      }
    });

    test(
      'isolate with logRootPath writes its tagged lines to brain.log + '
      'components/memory.log',
      () async {
        final host = TomBrainMemoryIsolateHost(
          factory: spawnLoggingFakeMemory,
          logRootPath: logRoot.path,
        );
        try {
          await host.spawn();
          // Triggers the factory inside the isolate, which logs the marker
          // *after* `initializeIsolate` installed the FanoutLogOutput.
          await host.openMemory(
            MemoryConfig.forTesting(root: '${logRoot.path}/unused'),
          );

          final brainLog = File('${logRoot.path}/brain.log');
          final memoryLog =
              File('${logRoot.path}/components/memory.log');

          // The isolate writes flushed/append, but the cross-isolate
          // round-trip of openMemory has already completed; give the
          // file system a brief settle window for robustness.
          for (var i = 0;
              i < 50 &&
                  !(brainLog.existsSync() && memoryLog.existsSync());
              i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }

          expect(brainLog.existsSync(), isTrue,
              reason: 'isolate headline routing → brain.log');
          expect(memoryLog.existsSync(), isTrue,
              reason: 'isolate component routing → components/memory.log');
          expect(brainLog.readAsStringSync(), contains(_kMarker));
          expect(memoryLog.readAsStringSync(),
              contains('[tom_brain.memory.store]'));
          expect(memoryLog.readAsStringSync(), contains(_kMarker));
        } finally {
          await host.shutdown();
        }
      },
    );

    test(
      'isolate without logRootPath writes no trail files (console default)',
      () async {
        final host =
            TomBrainMemoryIsolateHost(factory: spawnLoggingFakeMemory);
        try {
          await host.spawn();
          await host.openMemory(
            MemoryConfig.forTesting(root: '${logRoot.path}/unused'),
          );
          // No FanoutLogOutput installed in the isolate → no files under
          // the temp root (the isolate logs to its console default).
          expect(File('${logRoot.path}/brain.log').existsSync(), isFalse);
          expect(
            Directory('${logRoot.path}/components').existsSync(),
            isFalse,
          );
        } finally {
          await host.shutdown();
        }
      },
    );
  });
}

// ─── Top-level no-op memory (sendable factory target) ────────────────

final class _NoopMemory implements TomBrainMemory {
  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> checkpoint() async {}

  @override
  Future<MemoryStats> stats() async => MemoryStats.empty;

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
