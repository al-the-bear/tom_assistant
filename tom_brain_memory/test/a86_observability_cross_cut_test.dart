// A.86 cross-cut tests — config + logger + stats over a real corpus.
//
// The plan line (Phase A § A.16):
//
//   "Tests: config roundtrip; logger categorisation; stats reflect
//    a known-seeded corpus."
//
// A.83 already covers `MemoryConfigLoader` exhaustively at the parser
// surface (every required field, every type mismatch, every topology
// rule). A.84 covers `MemoryLog` at the wrapper surface (every
// category, every level, lazy contract). A.85 covers `MemoryEventBus`,
// `RecallLatencyTracker`, `ClassificationConfidenceTracker`, and
// `MemoryStatsCollector` at the in-memory primitive surface.
//
// A.86 is the **cross-cut**: do the four pieces still hold when wired
// to the *real* downstream subsystems that the composition root will
// hand them to?
//
//   - Config roundtrip — load the canonical § 14 YAML, hand the typed
//     `MemoryConfig` to the load-bearing consumers (`MemoryConfig`
//     path getters → opening a file-backed `memory.db`, applying the
//     real schema migrator). The asserted invariant: the loader's
//     output is structurally complete enough that downstream code
//     compiles, runs, and produces the same artifacts as the
//     hand-rolled `MemoryConfig.forTesting` path.
//
//   - Logger categorisation — drive three real seeded operations
//     (`SchemaMigrator.migrate`, `installBootstrapStacks`, a full
//     trail open → append → close cycle) and capture every line
//     emitted through `tomLog`. Assert that lines under
//     `[tom_brain.memory.store]`, `[tom_brain.memory.stacks]`, and
//     `[tom_brain.memory.trail]` all appear, and that no foreign
//     category prefix leaks through. The other three categories
//     (`retrieval`, `mcp`, `isolate`) are exercised by their owning
//     subsystem's per-test files; A.86 covers the three that share
//     a single seeded thread.
//
//   - Stats reflect a known-seeded corpus — seed a small corpus
//     deterministically: persist a handful of `Claim` / `Question` /
//     `Event` nodes through `NodePersister` with the bootstrap
//     manifest, mint a few edges through `EdgeWriter`, install the
//     six bootstrap stacks, push a small batch into them, open and
//     close one trail with a couple of appends, and feed
//     `RecallLatencyTracker` + `ClassificationConfidenceTracker`
//     with deterministic samples. Wire `MemoryStatsCollector` with
//     SQL-backed source callbacks (the same shape the composition
//     root will use once `SqliteTomBrainMemory` lands) and assert
//     every slice of the returned `MemoryStats` matches the seeded
//     state.
//
// A.85 asserts the *primitives* compose correctly with hand-fed
// closures. A.86 asserts the same primitives compose correctly when
// the closures pull from the real storage stack — the failure mode
// A.85 cannot catch is "the snapshot is right against a stub but
// wrong against the database".

import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, EdgeId, FixedClock, NodeId, SystemClock, Vec;

/// Records every `tomLog` line for the duration of one test.
///
/// Same pattern as A.84 (`_CapturingLogOutput`); A.86 needs the
/// captured records to assert cross-category coverage in a single
/// seeded thread.
class _CapturingLogOutput extends TomLogOutput {
  final List<_LogRecord> records = <_LogRecord>[];

  @override
  void output(
    TomLogLevel loggerLevel,
    TomLogLevel logLevel,
    String level,
    Object message,
    String isolateName,
    DateTime timeStamp, [
    String? origin,
  ]) {
    records.add(
      _LogRecord(level: level.trim(), message: convertToString(message)),
    );
  }
}

class _LogRecord {
  _LogRecord({required this.level, required this.message});
  final String level;
  final String message;

  @override
  String toString() => '($level) $message';
}

/// VectorApplier stand-in for the persist path. The store wires real
/// vector writes through `TwoDbCoordinator` → applier; A.86 does not
/// exercise vector recall, so a recording stub is enough — it lets
/// `NodePersister.persist` complete its happy path without needing
/// sqlite_vec to be loaded.
final class _RecordingVectorApplier implements VectorApplier {
  final List<PendingVectorWrite> calls = <PendingVectorWrite>[];

  @override
  void apply(PendingVectorWrite write) {
    calls.add(write);
  }
}

/// Builds a deterministic 768-dim embedding from [seed]. Matches the
/// helper used in `a39_end_to_end_test.dart` so the persist path
/// behaves identically.
Vec _v768({required int seed}) {
  final values = Float32List(768);
  for (var i = 0; i < 768; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

void main() {
  // ─── Group 1: Config roundtrip cross-cut ─────────────────────────

  group('A.86 config roundtrip — loader output wires into downstream '
      'consumers', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('a86_config_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('canonical § 14 YAML parses and every typed field is reachable',
        () {
      // The canonical example from `memory_specification.md` § 14,
      // with env tokens. The A.83 happy-path test asserts each field
      // individually; A.86 re-asserts the roundtrip *here* so a
      // future loader change that breaks the canonical example fails
      // the cross-cut, not just the parser test.
      final yaml = '''
memory:
  root: ${tempDir.path}
  sqliteVec:
    extensionPath: \${TOM_BINARIES}/sqlite_vec/\${PLATFORM}/vec0.so
  retrieval:
    rrf:
      k: 60
    mmr:
      lambda: 0.7
  trails:
    fsyncEveryAppend: true
    compressAfterDays: 7
    coldStorageAfterDays: 90
  classification:
    minConfidence: 0.55
    minMargin: 0.05
  budgets:
    defaultWriteBudget:
      maxNodes: 5000
      maxEdges: 20000
      maxStackEntries: 1000
  mcpServer:
    enabled: true
    bind: 127.0.0.1:8841
    bearerAuthRealm: tom-brain-memory
  replication:
    role: authority
    writeLogDir: ${tempDir.path}/write-log
''';

      final cfg = MemoryConfigLoader.parse(
        yaml,
        envVars: <String, String>{
          'TOM_BINARIES': '/opt/tom/binaries',
          'PLATFORM': 'linux-x64',
        },
      );

      // Every typed field reachable.
      expect(cfg.root, tempDir.path);
      expect(
        cfg.sqliteVec.extensionPath,
        '/opt/tom/binaries/sqlite_vec/linux-x64/vec0.so',
      );
      expect(cfg.retrieval.rrfK, 60);
      expect(cfg.retrieval.mmrLambda, 0.7);
      expect(cfg.trails.fsyncEveryAppend, true);
      expect(cfg.trails.compressAfter, const Duration(days: 7));
      expect(cfg.trails.coldStorageAfter, const Duration(days: 90));
      expect(cfg.classification.minConfidence, 0.55);
      expect(cfg.classification.minMargin, 0.05);
      expect(cfg.classification.coldStartMinExamples, 8);
      expect(cfg.budgets.defaultWriteBudget.maxNodes, 5000);
      expect(cfg.budgets.defaultWriteBudget.maxEdges, 20000);
      expect(cfg.budgets.defaultWriteBudget.maxStackEntries, 1000);
      expect(cfg.mcpServer.enabled, true);
      expect(cfg.mcpServer.bindAddress, '127.0.0.1');
      expect(cfg.mcpServer.bindPort, 8841);
      expect(cfg.mcpServer.bearerAuthRealm, 'tom-brain-memory');
      expect(cfg.replication.role, ReplicationRole.authority);
      expect(cfg.replication.writeLogDir, '${tempDir.path}/write-log');
      expect(cfg.replication.authorityEndpoint, isNull);
    });

    test('loaded config\'s path getters compute the canonical paths '
        'under the configured root', () {
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: ${tempDir.path}
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: ${tempDir.path}/write-log
''');

      final sep = Platform.pathSeparator;
      expect(cfg.memoryDbPath, '${tempDir.path}${sep}memory.db');
      expect(cfg.vectorsDbPath, '${tempDir.path}${sep}vectors.db');
      expect(cfg.trailsDir, '${tempDir.path}${sep}trails');
      expect(cfg.tombstonesDir, '${tempDir.path}${sep}tombstones');
      expect(cfg.checkpointsDir, '${tempDir.path}${sep}checkpoints');
    });

    test('a loaded config drives a real file-backed memory.db through '
        'the schema migrator', () {
      // The loader's output is structurally complete: feeding the
      // resolved `memoryDbPath` to `sqlite3.open` and running the
      // canonical migrator produces a v1 schema with no special-case
      // wiring. This is the cross-cut against `MemoryConfig.forTesting`
      // — the YAML loader output must reach the same end state.
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: ${tempDir.path}
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: ${tempDir.path}/write-log
''');

      final db = sqlite3.open(cfg.memoryDbPath);
      try {
        final report = SchemaMigrator().migrate(db);
        expect(report.didApplyAny, isTrue,
            reason: 'fresh DB at loader-resolved path → applies v1');
        // The migrator-installed `nodes` table is queryable.
        final count = db
            .select('SELECT COUNT(*) AS n FROM nodes')
            .first['n'] as int;
        expect(count, 0,
            reason: 'fresh DB has the table but no rows');
      } finally {
        db.dispose();
      }
      // The file actually landed on disk under the configured root.
      expect(File(cfg.memoryDbPath).existsSync(), isTrue);
    });

    test('forTesting and loader paths produce identical path getters '
        'against the same root', () {
      // The two construction modes (test factory + YAML loader) are
      // the only ways the rest of the system mints a `MemoryConfig`.
      // Their path-derivation logic must agree, otherwise tests and
      // production diverge at the file-system boundary.
      final fromFactory = MemoryConfig.forTesting(
        root: tempDir.path,
        extensionPath: '/opt/vec0.so',
      );
      final fromLoader = MemoryConfigLoader.parse('''
memory:
  root: ${tempDir.path}
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: ${tempDir.path}/write-log
''');

      expect(fromFactory.memoryDbPath, fromLoader.memoryDbPath);
      expect(fromFactory.vectorsDbPath, fromLoader.vectorsDbPath);
      expect(fromFactory.trailsDir, fromLoader.trailsDir);
      expect(fromFactory.tombstonesDir, fromLoader.tombstonesDir);
      expect(fromFactory.checkpointsDir, fromLoader.checkpointsDir);
    });
  });

  // ─── Group 2: Logger categorisation cross-cut ────────────────────

  group('A.86 logger categorisation — one seeded thread emits under '
      'every owning category', () {
    late _CapturingLogOutput capturing;
    late TomLogOutput previousOutput;
    late TomLogLevel previousLevel;
    late Directory tempDir;

    setUp(() {
      capturing = _CapturingLogOutput();
      previousOutput = tomLog.logOutput;
      previousLevel = tomLog.logLevel;
      tomLog.logOutput = capturing;
      // `development` so every category's full level set forwards
      // through; A.84 uses the same gate for the same reason.
      tomLog.setLogLevel(TomLogLevel.development);
      tempDir =
          Directory.systemTemp.createTempSync('a86_log_categorisation_');
    });

    tearDown(() {
      tomLog.logOutput = previousOutput;
      tomLog.setLogLevel(previousLevel);
      tempDir.deleteSync(recursive: true);
    });

    test('a real store + stacks + trail thread emits under each of '
        'its three owning categories with no foreign category leaks',
        () async {
      // One seeded run that touches three subsystems:
      //   * `tom_brain.memory.store`   ← SchemaMigrator
      //   * `tom_brain.memory.stacks`  ← installBootstrapStacks
      //   * `tom_brain.memory.trail`   ← open + append + close
      final dbPath = '${tempDir.path}${Platform.pathSeparator}memory.db';
      final trailsDir = '${tempDir.path}${Platform.pathSeparator}trails';
      Directory(trailsDir).createSync(recursive: true);

      final db = sqlite3.open(dbPath);
      try {
        // (1) store category: migrate v0 → v1.
        final migrateReport = SchemaMigrator().migrate(db);
        expect(migrateReport.didApplyAny, isTrue);

        // (2) stacks category: install the six bootstrap stacks.
        final installReport = installBootstrapStacks(db);
        expect(installReport.wasFreshInstall, isTrue);

        // (3) trail category: open, append, close one trail.
        final trailStore = SqliteTrailStore(
          memoryDb: db,
          trailsRoot: trailsDir,
          clock: const SystemClock(),
        );
        try {
          final tid = await trailStore.openTrail(
            const ProcedureRunRef(
              procedureId: 'p_a86_test',
              runId: 'r_a86_test_1',
            ),
          );
          await trailStore.appendTrail(
            tid,
            TrailEntry.note('seeded for A.86 categorisation'),
          );
          await trailStore.closeTrail(
            tid,
            const TrailOutcome(
              status: TrailOutcomeStatus.accepted,
              summary: 'seeded run completed',
              elapsedMs: 1,
            ),
          );
        } finally {
          await trailStore.close();
        }
      } finally {
        db.dispose();
      }

      // Every category that this seeded thread *should* have touched
      // emitted at least one line.
      final byCategory = <String, List<_LogRecord>>{};
      for (final r in capturing.records) {
        for (final cat in MemoryLogCategory.values) {
          final prefix = '[${cat.name}] ';
          if (r.message.startsWith(prefix)) {
            byCategory.putIfAbsent(cat.name, () => <_LogRecord>[]).add(r);
            break;
          }
        }
      }
      expect(
        byCategory['tom_brain.memory.store'],
        isNotEmpty,
        reason: 'SchemaMigrator.migrate must emit under store',
      );
      expect(
        byCategory['tom_brain.memory.stacks'],
        isNotEmpty,
        reason: 'installBootstrapStacks must emit under stacks',
      );
      expect(
        byCategory['tom_brain.memory.trail'],
        isNotEmpty,
        reason: 'openTrail / closeTrail must emit under trail',
      );

      // No foreign category prefix slipped in. (The other three
      // categories — retrieval, mcp, isolate — are *expected* to be
      // silent in this seeded thread; if they fire here, a future
      // refactor accidentally cross-wired their MemoryLog call.)
      expect(
        byCategory['tom_brain.memory.retrieval'] ?? <_LogRecord>[],
        isEmpty,
        reason: 'no recall executed in this seeded thread',
      );
      expect(
        byCategory['tom_brain.memory.mcp'] ?? <_LogRecord>[],
        isEmpty,
        reason: 'no MCP server started in this seeded thread',
      );
      expect(
        byCategory['tom_brain.memory.isolate'] ?? <_LogRecord>[],
        isEmpty,
        reason: 'no isolate host spawned in this seeded thread',
      );

      // Every line that *does* carry a memory-prefix carries one of
      // the six canonical category prefixes — no ad-hoc strings.
      final memoryLines = capturing.records
          .where((r) => r.message.startsWith('[tom_brain.memory.'))
          .toList();
      for (final r in memoryLines) {
        final matched = MemoryLogCategory.values.any(
          (cat) => r.message.startsWith('[${cat.name}] '),
        );
        expect(matched, isTrue,
            reason: 'line "${r.message}" does not match any '
                'canonical category prefix');
      }
    });
  });

  // ─── Group 3: Stats reflect a known-seeded corpus ────────────────

  group('A.86 stats — collector snapshot reflects the seeded corpus', () {
    late Directory tempDir;
    late Database db;
    late _RecordingVectorApplier applier;
    late TwoDbCoordinator coordinator;
    late NodeTypeRegistry registry;
    late NodePersister persister;
    late EdgeWriter edgeWriter;
    late SqliteStackApi stackApi;
    late SqliteTrailStore trailStore;
    late RecallLatencyTracker latencyTracker;
    late ClassificationConfidenceTracker confidenceTracker;
    late MemoryStatsCollector collector;
    late DateTime fakeNow;
    late int idCounter;
    late int edgeIdCounter;

    NodeId mintNodeId() {
      idCounter += 1;
      return NodeId.generate(
        at: fakeNow,
        randomness: List<int>.generate(16, (i) => (idCounter + i) & 31),
      );
    }

    EdgeId mintEdgeId() {
      edgeIdCounter += 1;
      return EdgeId.generate(
        at: fakeNow,
        randomness:
            List<int>.generate(16, (i) => (edgeIdCounter * 7 + i) & 31),
      );
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('a86_stats_corpus_');
      final trailsDir = '${tempDir.path}${Platform.pathSeparator}trails';
      Directory(trailsDir).createSync(recursive: true);

      fakeNow = DateTime.utc(2026, 5, 30, 14, 0, 0);
      idCounter = 0;
      edgeIdCounter = 0;

      db = sqlite3.openInMemory();
      applySchemaV1(db);

      applier = _RecordingVectorApplier();
      coordinator = TwoDbCoordinator(
        memoryDb: db,
        applier: applier,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );

      var regIdCounter = 1000;
      NodeId mintRegistryId() {
        regIdCounter += 1;
        return NodeId.generate(
          at: fakeNow,
          randomness:
              List<int>.generate(16, (i) => (regIdCounter + i) & 31),
        );
      }

      registry = NodeTypeRegistry(
        memoryDb: db,
        critiqueHook: (proposal, existing) async => const CritiqueApproved(),
        idMint: mintRegistryId,
        now: () => fakeNow,
      );
      final decls = await NodeTypeYamlLoader.loadBootstrapManifest();
      for (final decl in decls) {
        await registry.registerNodeType(decl);
      }

      persister = NodePersister(
        memoryDb: db,
        coordinator: coordinator,
        registry: registry,
        idMint: mintNodeId,
        now: () => fakeNow,
      );
      edgeWriter = EdgeWriter(
        memoryDb: db,
        registry: registry,
        idMint: mintEdgeId,
        now: () => fakeNow,
      );

      installBootstrapStacks(
        db,
        stackNodeIdMint: mintNodeId,
        now: () => fakeNow,
      );
      stackApi = SqliteStackApi(
        memoryDb: db,
        now: () => fakeNow,
      );
      trailStore = SqliteTrailStore(
        memoryDb: db,
        trailsRoot: trailsDir,
        clock: FixedClock(BrainTime.utc(2026, 5, 30, 14, 0, 0)),
      );
      latencyTracker = RecallLatencyTracker();
      confidenceTracker = ClassificationConfidenceTracker();

      // Wire the collector with SQL-backed source callbacks — the
      // same shape `SqliteTomBrainMemory` will use once it lands.
      collector = MemoryStatsCollector(
        nodeCounts: () async => _readNodeCountsLive(db),
        edgeCounts: () async => _readEdgeCounts(db),
        stackSizes: () async {
          final summaries = await stackApi.list();
          return <String, int>{
            for (final s in summaries) s.name: s.size,
          };
        },
        trailCount: () async {
          return db
              .select('SELECT COUNT(*) AS n FROM trails')
              .first['n'] as int;
        },
        trailBytes: () async => _trailsDirBytes(trailsDir),
        recallLatency: () async => latencyTracker.snapshot(),
        classificationConfidence: () async => confidenceTracker.snapshot(),
        migrationProgress: () async => const <String, double>{},
      );
    });

    tearDown(() async {
      await stackApi.close();
      await trailStore.close();
      db.dispose();
      tempDir.deleteSync(recursive: true);
    });

    test('every slice of MemoryStats reflects the seeded state', () async {
      // Seed nodes: 3 Claims, 2 Questions, 1 Event.
      final claimA = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'statement': 'a'},
          embedding: _v768(seed: 1),
        ),
        scope: const Scope(
          producer: 'a86-test',
          idempotencyKey: 'a86:claim:a',
        ),
      );
      final claimB = await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'statement': 'b'},
          embedding: _v768(seed: 2),
        ),
        scope: const Scope(
          producer: 'a86-test',
          idempotencyKey: 'a86:claim:b',
        ),
      );
      await persister.persist(
        NodeDraft(
          typeName: 'Claim',
          values: const <String, Object?>{'statement': 'c'},
          embedding: _v768(seed: 3),
        ),
        scope: const Scope(
          producer: 'a86-test',
          idempotencyKey: 'a86:claim:c',
        ),
      );
      final qOne = await persister.persist(
        NodeDraft(
          typeName: 'Question',
          values: const <String, Object?>{'text': 'q1?'},
          embedding: _v768(seed: 4),
        ),
        scope: const Scope(
          producer: 'a86-test',
          idempotencyKey: 'a86:q:1',
        ),
      );
      final qTwo = await persister.persist(
        NodeDraft(
          typeName: 'Question',
          values: const <String, Object?>{'text': 'q2?'},
          embedding: _v768(seed: 5),
        ),
        scope: const Scope(
          producer: 'a86-test',
          idempotencyKey: 'a86:q:2',
        ),
      );
      await persister.persist(
        NodeDraft(
          typeName: 'Event',
          values: <String, Object?>{
            'summary': 'a86 seeded event',
            'occurred_at': fakeNow.toIso8601String(),
            'payload': const <String, Object?>{'note': 'a86-test'},
          },
          embedding: _v768(seed: 6),
        ),
        scope: const Scope(
          producer: 'a86-test',
          idempotencyKey: 'a86:event:1',
        ),
      );

      // Seed edges: 2 `evidence_for` Claim→Claim, 1 `mentions`
      // Claim→Question. Both edges are in the bootstrap manifest's
      // allowed-set for the involved types.
      await edgeWriter.edge(
        claimA,
        EdgeType.evidenceFor,
        claimB,
        scope: const Scope.nonIdempotent(producer: 'a86-test'),
      );
      await edgeWriter.edge(
        claimB,
        EdgeType.evidenceFor,
        claimA,
        scope: const Scope.nonIdempotent(producer: 'a86-test'),
      );
      await edgeWriter.edge(
        claimA,
        EdgeType.mentions,
        qOne,
        scope: const Scope.nonIdempotent(producer: 'a86-test'),
      );

      // Seed stacks: 2 pushes into `questions_open`, 1 into
      // `interests` (the canonical bootstrap names from spec § 5.4;
      // both accept their respective node types).
      await stackApi.push('questions_open', qOne, priority: 5.0);
      await stackApi.push('questions_open', qTwo, priority: 3.0);
      // `interests` expects InterestItem entries; the api does not
      // enforce that at push-time (the entryNodeType is advisory in
      // A.40), so a Question stand-in is fine for this size check.
      await stackApi.push('interests', qOne, priority: 1.0);

      // Seed a trail: open + 2 appends + close.
      final tid = await trailStore.openTrail(
        const ProcedureRunRef(
          procedureId: 'p_a86_test',
          runId: 'r_a86_test_1',
        ),
      );
      await trailStore.appendTrail(
        tid,
        TrailEntry.note('first note'),
      );
      await trailStore.appendTrail(
        tid,
        TrailEntry.persist(claimA.toString()),
      );
      await trailStore.closeTrail(
        tid,
        const TrailOutcome(
          status: TrailOutcomeStatus.accepted,
          summary: 'seeded run',
          elapsedMs: 1,
        ),
      );

      // Seed the in-memory trackers.
      latencyTracker.record(RecallMode.bm25, 12);
      latencyTracker.record(RecallMode.bm25, 18);
      latencyTracker.record(RecallMode.vector, 40);
      latencyTracker.record(RecallMode.vector, 60);
      latencyTracker.record(RecallMode.vector, 80);
      confidenceTracker.record(0.05); // → 0.0-0.1
      confidenceTracker.record(0.55); // → 0.5-0.6
      confidenceTracker.record(0.95); // → 0.9-1.0
      confidenceTracker.record(0.95); // → 0.9-1.0

      // ─── Snapshot + assertions ─────────────────────────────────
      final stats = await collector.snapshot();

      // Nodes: 3 Claim, 2 Question, 1 Event seeded directly through
      // NodePersister, plus 6 `Stack` nodes minted by
      // installBootstrapStacks (which inserts real `nodes` rows of
      // type_name='Stack'). NodeType registrations live in a separate
      // `node_types` table and do *not* appear in `nodeCountByType`.
      expect(stats.nodeCountByType['Claim'], 3);
      expect(stats.nodeCountByType['Question'], 2);
      expect(stats.nodeCountByType['Event'], 1);
      expect(stats.nodeCountByType['Stack'], 6,
          reason: 'installBootstrapStacks minted 6 Stack nodes');
      expect(stats.nodeCountByType.containsKey('NodeType'), isFalse,
          reason: 'NodeType registrations live in node_types, not nodes');

      // Edges: 2 evidence_for + 1 mentions.
      expect(stats.edgeCountByType['evidence_for'], 2);
      expect(stats.edgeCountByType['mentions'], 1);

      // Stacks: every bootstrap stack appears with its current size.
      expect(stats.stackSizes['questions_open'], 2);
      expect(stats.stackSizes['interests'], 1);
      // The other four bootstrap stacks installed by
      // installBootstrapStacks remain empty.
      expect(stats.stackSizes['automation_ideas'], 0);
      expect(stats.stackSizes['inflight'], 0);
      expect(stats.stackSizes['recent_runs'], 0);
      expect(stats.stackSizes['restructure_backlog'], 0);

      // Trails: one open+closed trail, non-zero on-disk bytes.
      expect(stats.trailCount, 1);
      expect(stats.trailBytes, greaterThan(0),
          reason: 'the JSONL file holds at least the note + persist + '
              'outcome lines');

      // Recall latency: bm25 has 2 samples (12, 18); vector has 3
      // samples (40, 60, 80). Nearest-rank p50/p95 over those:
      //   bm25 sorted=[12, 18]:    p50=ceil(0.5*2)-1=0 → 12;
      //                            p95=ceil(0.95*2)-1=1 → 18.
      //   vector sorted=[40,60,80]: p50=ceil(0.5*3)-1=1 → 60;
      //                             p95=ceil(0.95*3)-1=2 → 80.
      expect(stats.recallLatencyPerMode.keys,
          unorderedEquals(<String>['bm25', 'vector']));
      expect(stats.recallLatencyPerMode['bm25']!.p50Ms, 12.0);
      expect(stats.recallLatencyPerMode['bm25']!.p95Ms, 18.0);
      expect(stats.recallLatencyPerMode['vector']!.p50Ms, 60.0);
      expect(stats.recallLatencyPerMode['vector']!.p95Ms, 80.0);

      // Classification histogram: every bucket present, three buckets
      // non-zero per the seeded samples.
      expect(stats.classificationConfidenceHistogram.keys,
          unorderedEquals(ClassificationConfidenceTracker.bucketLabels));
      expect(stats.classificationConfidenceHistogram['0.0-0.1'], 1);
      expect(stats.classificationConfidenceHistogram['0.5-0.6'], 1);
      expect(stats.classificationConfidenceHistogram['0.9-1.0'], 2);
      // Untouched bucket reads zero rather than missing.
      expect(stats.classificationConfidenceHistogram['0.3-0.4'], 0);

      // Migration progress is empty — A.86 does not run a migration.
      expect(stats.migrationProgress, isEmpty);

      // Every slice map is unmodifiable (A.85 invariant — confirm it
      // survives the SQL-backed wiring path too).
      expect(
        () => stats.nodeCountByType['x'] = 99,
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => stats.stackSizes['x'] = 99,
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

// ─── SQL-backed source helpers ──────────────────────────────────────
//
// The composition root will inline the same SQL once
// `SqliteTomBrainMemory` lands. Until then these helpers live in the
// test file so the seeded-corpus test asserts the *exact* shape A.85's
// `MemoryStatsCollector` contract requires.

/// `nodes` grouped by `type_name`, live rows only (`status='active'`).
///
/// Live-only filter matters: a future demote → forget chain leaves a
/// `Tombstone` row behind, which a naive `COUNT(*)` would conflate
/// with live nodes. The collector contract on
/// `MemoryStats.nodeCountByType` is "current live count by type".
Map<String, int> _readNodeCountsLive(Database db) {
  final rows = db.select(
    "SELECT type_name, COUNT(*) AS c FROM nodes "
    "WHERE status = 'active' GROUP BY type_name",
  );
  return <String, int>{
    for (final row in rows) row['type_name'] as String: row['c'] as int,
  };
}

/// `edges` grouped by `type` (wire name).
Map<String, int> _readEdgeCounts(Database db) {
  final rows = db.select(
    'SELECT type, COUNT(*) AS c FROM edges GROUP BY type',
  );
  return <String, int>{
    for (final row in rows) row['type'] as String: row['c'] as int,
  };
}

/// Total on-disk size of every regular file under [trailsRoot]
/// (recursive). The trail writer date-shards under
/// `trails/YYYY/MM/DD/<runId>.jsonl`; the byte total spans every
/// shard to mirror what an operator running `du -sb trails/` would
/// see.
int _trailsDirBytes(String trailsRoot) {
  final root = Directory(trailsRoot);
  if (!root.existsSync()) return 0;
  var total = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) {
      total += entity.lengthSync();
    }
  }
  return total;
}
