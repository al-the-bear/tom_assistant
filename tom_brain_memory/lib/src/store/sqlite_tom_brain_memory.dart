// SqliteTomBrainMemory — the concrete v1 in-process memory store.
//
// prototype_implementation_plan_2.md #13:
//   "Memory: implement SqliteTomBrainMemory.open(config). Assemble the
//    existing parts (MemoryDirectory.openOrCreate, applySchemaV1,
//    TwoDbCoordinator, BootIntegrityCheck) into the concrete store, and
//    wire loadVecExtensionOrRefuseToBoot into open() (closes P1.1) so a
//    missing/broken vec0 raises VectorRuntimeUnavailable and the store
//    refuses to open."
//
// prototype_implementation_plan_2.md #14:
//   "Memory: bootstrap catalogue on open. Register the 21 node types,
//    12-edge alphabet, and 6 bootstrap stacks during open() (idempotent)."
//
// Scope at #13 was the *open / close / checkpoint lifecycle only*. #14
// added catalogue seeding (the 21 node types + six stacks + registry
// trio). #15 adds the node-write/read path and trails: open() now
// installs the per-model vector indexes and wires NodePersister,
// NodeReader, and SqliteTrailStore, so persist / get / getMany /
// openTrail / appendTrail / closeTrail / readTrail are live. #16 adds
// retrieval: open() threads a shared Fts5Catalog into the registry (so
// the per-type FTS5 tables exist) and an Fts5Writer into the persister
// (so persisted nodes land FTS rows), then wires a RecallExecutor over
// the four mode executors, so recall() is live. The remaining
// data-plane methods (edges, stacks, classification, lifecycle, budget,
// migrations, observability) are deferred to #17 and throw
// UnimplementedError until those steps land. Keeping them as loud stubs
// — rather than silent no-ops — means any consumer wired up early fails
// fast at the exact unimplemented call rather than corrupting state.
//
// ─────────────────────────────────────────────────────────────────────
// open() ordering (and why)
// ─────────────────────────────────────────────────────────────────────
//
//   1. MemoryDirectory.openOrCreate(config)
//        Materialises <root>/ + trails/ tombstones/ checkpoints/ and
//        resolves memory.db / vectors.db paths. No SQLite handle yet.
//
//   2. loadVecExtensionOrRefuseToBoot(sqlite, config)  ← BEFORE any open
//        Registers vec0 with sqlite3_auto_extension, which only affects
//        Databases opened *after* registration. Doing this before
//        opening either DB is what guarantees the vectors.db handle has
//        vec0. A missing/broken binary throws VectorRuntimeUnavailable
//        here and open() aborts WITHOUT creating memory.db / vectors.db
//        — a refused boot leaves no half-initialised store on disk
//        (Q-A.6.1, spec principle 6: no BM25-only fallback).
//
//   3. memory.db: open + WAL + busy_timeout + BootIntegrityCheck.run().
//        BootIntegrityCheck runs the schema migrator FIRST (which applies
//        schema v1 via applySchemaV1 transitively — open() must NOT call
//        applySchemaV1 directly; schema_v1.dart forbids host calls
//        outside the migration path), then the four read-only probes.
//        throwIfFailed() turns any failed probe into a hard refusal.
//
//   4. vectors.db: open + WAL + busy_timeout + VectorTable.ensureMetaTable.
//        The vector_indexes meta table is created up-front so the
//        persist path can install per-model indexes.
//
//   5. Seed the bootstrap catalogue (21 node types + 6 stacks).
//
//   6. Install one vector index per distinct embedding model among the
//        registered types. `VectorTable.insertVector` refuses
//        (EmbeddingModelMismatch) when no index is installed, so the
//        index must exist before any persist write — and before the
//        pending-write replay in step 7, which may itself write vectors.
//
//   7. TwoDbCoordinator.recoverPending()
//        Replays any pending_vector_writes left by a crash between the
//        memory.db commit and the vectors.db apply. On a fresh store this
//        is an empty no-op; on a re-open after a crash it converges the
//        two databases before the store serves a single read.
//
//   8. Wire the data-plane owners — NodePersister, NodeReader,
//        SqliteTrailStore — around the shared handles and hold them as
//        fields for the life of the store. `close` flushes the trail
//        store before the database handles are disposed.

import 'package:sqlite3/sqlite3.dart';
// All consumer-facing data types (NodeDraft, Node, Edge, Scope,
// RecallResult, StackApi, MigrationApi, MemoryEvent, MemoryStats, …) plus
// Clock / SystemClock / MemoryConfig / ids / Vec / WriteBudget come from
// the shared barrel — the TomBrainMemoryClient contract is defined there.
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../api/tom_brain_memory.dart';
import '../budget/write_budget_tracker.dart';
import '../classification/centroid_store.dart';
import '../cognitive_agents/agent_registry.dart';
import '../classification/classifier.dart';
import '../classification/uncertain_finder.dart';
import '../edges/edge_reader.dart';
import '../edges/edge_writer.dart';
import '../migrations/json_file_migration_api.dart';
import '../nodes/critique_hook.dart';
import '../nodes/node_access_recorder.dart';
import '../nodes/node_lifecycle.dart';
import '../nodes/node_persister.dart';
import '../nodes/node_reader.dart';
import '../nodes/node_type_registry.dart';
import '../nodes/node_type_yaml_loader.dart';
import '../observability/memory_event_bus.dart';
import '../observability/memory_stats_collector.dart';
import '../observability/node_lifecycle_event_counter.dart';
import '../procedures/procedure_metrics_writer.dart';
import '../profiles/sqlite_memory_profile_registry.dart';
import '../retrieval/bm25_recall.dart';
import '../retrieval/fts5_catalog.dart';
import '../retrieval/fts5_writer.dart';
import '../retrieval/graph_walk_recall.dart';
import '../retrieval/recall_executor.dart';
import '../retrieval/stream_cursor_store.dart';
import '../retrieval/symbolic_recall.dart';
import '../retrieval/vector_recall.dart';
import '../stacks/bootstrap_stacks_installer.dart';
import '../stacks/sqlite_stack_api.dart';
import '../trails/sqlite_trail_store.dart';
import 'boot_integrity.dart';
import 'memory_directory.dart';
import 'two_db_coordinator.dart';
import 'vec_extension_loader.dart';
import 'vector_table.dart';
import 'vector_table_applier.dart';

/// The concrete v1 SQLite-backed [TomBrainMemory].
///
/// Construct one per memory root per OS process (the single-process
/// contract MemoryDirectory documents). Call [open] before any other
/// method; [close] releases the native handles.
///
/// The node-write/read path, trails, the node-type registry trio, and
/// the four-mode [recall] pipeline are live (#14–#16). The remaining
/// data-plane methods are deferred to prototype_implementation_plan_2
/// item #17 and throw [UnimplementedError] until then.
final class SqliteTomBrainMemory extends TomBrainMemory {
  /// The single FTS5 catalog shared by the registry (which provisions
  /// the per-type FTS5 virtual tables on registration) and the
  /// persister's [Fts5Writer] (which writes the FTS rows). Both halves
  /// must agree on table names and column order, so they read from the
  /// same catalog instance. `Fts5Catalog` is a stateless `const`, so a
  /// single shared value is sufficient.
  static const Fts5Catalog _ftsCatalog = Fts5Catalog();

  /// The SQLite runtime. Injected so the vec0 auto-extension
  /// registration in [open] targets the same runtime the store opens
  /// its databases through. Defaults to the process-global `sqlite3`.
  final Sqlite3 _sqlite;

  /// Wall clock for time-stamped storage rows. Defaults to the system
  /// clock; tests inject a fixed clock.
  final Clock _clock;

  bool _isOpen = false;
  late Database _memoryDb;
  late Database _vectorsDb;

  /// The node-type registry, seeded with the bootstrap catalogue during
  /// [open] and backing [listNodeTypes] / [getNodeType] /
  /// [registerNodeType]. Built fresh per open; it warms its in-memory
  /// cache from the `node_types` rows already on disk.
  late NodeTypeRegistry _registry;

  /// Owner of the node-write path ([persist]). Built in [open] around
  /// the shared `memory.db` handle, the two-DB coordinator, and the
  /// seeded registry.
  late NodePersister _persister;

  /// Optional storage-stack embedder (Q-H.1, non-generative). Threaded
  /// into the [RecallExecutor] so a vector seed carrying only `text` can
  /// be embedded; `null` leaves text-only vector seeds degrading. Shared
  /// with the profile child stores spawned by [_profiles].
  final RecallEmbedder? _embedder;

  /// Owner of the node-read path ([get] / [getMany]). Reads `memory.db`
  /// only — embeddings live in `vectors.db` and are not rehydrated here
  /// (Q-A.35.1).
  late NodeReader _reader;

  /// Owner of the trail subsystem ([openTrail] / [appendTrail] /
  /// [closeTrail] / [readTrail]). Holds open JSONL writers, so [close]
  /// must flush it before disposing the database handles.
  late SqliteTrailStore _trailStore;

  /// The four-mode retrieval pipeline backing [recall] (BM25, vector,
  /// graph-walk, symbolic → RRF + MMR → optional caller re-rank hook).
  /// Built in [open] over the shared handles, registry, and vector
  /// table; stateless across calls.
  late RecallExecutor _recallExecutor;

  /// Central fan-in for `MemoryEvent`s. Every per-subsystem owner that
  /// emits events (persister, edge writer, stack API, lifecycle
  /// manager, centroid store, classifier, migration API) is handed
  /// `_eventBus.emit` as its sink; [events] returns `_eventBus.events()`
  /// and [close] closes the bus.
  late MemoryEventBus _eventBus;

  /// Per-run write-budget enforcement ([beginRun] / [endRun] /
  /// [remainingBudget]). Threaded into the persister, edge writer, and
  /// stack API so every accepted write of a registered run is charged.
  late WriteBudgetTracker _budgetTracker;

  /// Per-agent scope and write-guard registry. Threaded into the persister,
  /// edge writer, and stack API so that a write carrying an `agentName`
  /// (via its [Scope]) is rejected with [AgentScopeViolation] when the
  /// agent is unregistered or the target type/wire/stack is outside the
  /// agent's declared write scopes. Writes without an `agentName` bypass it.
  late AgentRegistry _agentRegistry;

  /// Owner of the edge-write path ([edge]).
  late EdgeWriter _edgeWriter;

  /// Owner of the edge-read path ([edgesOf]).
  late EdgeReader _edgeReader;

  /// Owner of the node-lifecycle transitions ([demote] / [forget]).
  late NodeLifecycleManager _lifecycle;

  /// Owner of the usage-tracking write ([recordAccess]) — sole writer of
  /// the `last_access_ms` / `access_count` columns.
  late NodeAccessRecorder _accessRecorder;

  /// Owner of the Procedure metric/status cache write ([updateProcedureMetrics]).
  late ProcedureMetricsWriter _procedureMetrics;

  /// `memory.db` side of the centroid table backing [updateCentroid].
  late CentroidStore _centroidStore;

  /// Centroid-based classifier backing [classify].
  late Classifier _classifier;

  /// Borderline-node finder backing [findUncertain].
  late UncertainFinder _uncertainFinder;

  /// Owner of the named-stack surface ([stacks]). Holds stream
  /// controllers, so [close] must release it before the handles go.
  late SqliteStackApi _stackApi;

  /// File-backed migration-cursor surface ([migrations]).
  late JsonFileMigrationApi _migrations;

  /// Durable stream-cursor checkpoints backing [stream] resumption.
  late JsonFileStreamCursorStore _streamCursorStore;

  /// Assembles the [stats] snapshot from per-subsystem source tear-offs.
  late MemoryStatsCollector _statsCollector;

  /// Running tally of node-lifecycle transitions (persist / promote /
  /// demote / forget), feeding [MemoryStats.lifecycleEventCounts]
  /// (§ 17). Fed synchronously by [_emitLifecycleCounted] — the sink
  /// the node-lifecycle producers emit through — so the count is exact
  /// at the moment [stats] reads it, with no race against the async
  /// [events] broadcast feed. Lives for the store's whole life.
  final NodeLifecycleEventCounter _lifecycleCounter =
      NodeLifecycleEventCounter();

  /// The profile-administration surface ([profiles]) over the
  /// `<memory-root>/profiles/` tier (memory § 2.5). Built in [open]
  /// from the profile-unbound base config, a child-store factory, and
  /// the event bus's `emit` sink. Holds no long-lived handle — every
  /// create / seed / drop opens, works, and closes a short-lived child
  /// store — so [close] has nothing to release here.
  late SqliteMemoryProfileRegistry _profiles;

  /// The profile name this handle is bound to, captured from
  /// `MemoryConfig.profile` at [open] and reset to `null` on [close]
  /// (memory § 3.1, reconciled at H.28). `null` = the profile-unbound
  /// single-tenant layout.
  String? _currentProfile;

  /// Creates an unopened store.
  ///
  /// [sqlite] defaults to the process-global `sqlite3` instance;
  /// [clock] defaults to `const SystemClock()`.
  ///
  /// [embedder] is the optional storage-stack embedding model (Q-H.1,
  /// non-generative). When supplied it lets `recall` / `recallMulti`
  /// embed a vector seed that carries only `text` (no precomputed
  /// `embedding`); when `null`, such seeds degrade — vector mode skipped.
  SqliteTomBrainMemory({
    Sqlite3? sqlite,
    Clock clock = const SystemClock(),
    RecallEmbedder? embedder,
  })  : _sqlite = sqlite ?? sqlite3,
        _clock = clock,
        _embedder = embedder;

  /// The opened `memory.db` handle. **Test-only** introspection seam;
  /// production consumers go through the [TomBrainMemoryClient] surface.
  /// Throws a [StateError] if read before [open].
  Database get debugMemoryDatabase {
    _ensureOpen('debugMemoryDatabase');
    return _memoryDb;
  }

  /// The opened `vectors.db` handle. **Test-only** introspection seam.
  /// Throws a [StateError] if read before [open].
  Database get debugVectorsDatabase {
    _ensureOpen('debugVectorsDatabase');
    return _vectorsDb;
  }

  @override
  Future<void> open(MemoryConfig config) async {
    if (_isOpen) return; // idempotent (spec § 3.1 open contract)

    // 1. Directory layout (no SQLite handle yet).
    final directory = MemoryDirectory.openOrCreate(config);

    // 2. Refuse to boot without a loadable vec0 — BEFORE opening any DB
    //    so the auto-extension registration applies to both handles and
    //    so a refused boot leaves no half-built store on disk.
    loadVecExtensionOrRefuseToBoot(sqlite: _sqlite, config: config);

    // 3. memory.db: open, WAL, integrity check (which migrates schema).
    final memoryDb = _sqlite.open(directory.memoryDbPath);
    _applyConnectionPragmas(memoryDb);
    BootIntegrityCheck()
        .run(memoryDb: memoryDb, directory: directory, config: config)
        .throwIfFailed();

    // 4. vectors.db: open, WAL, ensure the per-model index meta table.
    final vectorsDb = _sqlite.open(directory.vectorsDbPath);
    _applyConnectionPragmas(vectorsDb);
    final vectorTable = VectorTable(
      vectorsDb: vectorsDb,
      backend: const Vec0VirtualTableBackend(),
      clock: _clock,
    )..ensureMetaTable();

    // 5. Seed the bootstrap catalogue — the 21 spec node types and the
    //    six reserved stacks (the 12-edge alphabet rides along in the
    //    node types' allowed-edge sets, validated at registration).
    //    Idempotent: re-open against a seeded DB is a no-op.
    final registry = await _seedBootstrapCatalogue(memoryDb);

    // 6. Install one vector index per distinct embedding model among the
    //    registered types. A persist that carries an embedding writes
    //    its vector through `VectorTable.insertVector`, which refuses
    //    (EmbeddingModelMismatch) when no index is installed — so the
    //    index must exist before any write or pending-write replay.
    //    Idempotent: re-install at the same dims returns the existing
    //    index, so a re-open is a no-op here too.
    _installVectorIndexes(vectorTable, registry);

    // 7. Build the two-DB coordinator, then recover any pending writes
    //    left by a prior crash (empty no-op on a fresh store). Recovery
    //    replays vector writes, so it must run *after* the indexes are
    //    installed (step 6). The coordinator is shared with the
    //    persister built next.
    final coordinator = TwoDbCoordinator(
      memoryDb: memoryDb,
      applier: VectorTableApplier(vectorTable: vectorTable),
      clock: _clock,
    )..recoverPending();

    // 8. Wire the data-plane owners around the shared handles. They are
    //    held as fields for the life of the store; `close` flushes the
    //    trail store and releases the stack API + event bus before the
    //    database handles are disposed.
    _memoryDb = memoryDb;
    _vectorsDb = vectorsDb;
    _registry = registry;

    // The event bus is built first so every owner below can take
    // `_eventBus.emit` as its sink; the budget tracker is shared by
    // every write owner (persister, edge writer, stack API).
    _eventBus = MemoryEventBus();
    _budgetTracker = WriteBudgetTracker();
    _agentRegistry = AgentRegistry();

    _persister = NodePersister(
      memoryDb: memoryDb,
      coordinator: coordinator,
      registry: registry,
      now: _clock.now,
      // Persisted nodes land their FTS5 rows through the shared catalog
      // so BM25 recall (step below) can find them. The writer is a no-op
      // for types without FTS fields.
      ftsWriter: const Fts5Writer(catalog: _ftsCatalog),
      // Node-lifecycle producer: route through the counting tap so the
      // `node-persisted` tally is exact for `stats()` (§ 17).
      eventSink: _emitLifecycleCounted,
      budgetTracker: _budgetTracker,
      agentRegistry: _agentRegistry,
    );
    _reader = NodeReader(memoryDb: memoryDb);
    _trailStore = SqliteTrailStore(
      memoryDb: memoryDb,
      trailsRoot: directory.trailsDir,
      clock: _clock,
    );

    // 9. Wire the four-mode retrieval pipeline. Each mode executor reads
    //    the shared handles + registry; the BM25 executor uses the same
    //    catalog the registry provisioned its FTS5 tables with and the
    //    persister wrote rows against, so all three agree on the table
    //    layout. The executor itself is stateless across calls.
    _recallExecutor = RecallExecutor(
      bm25: Bm25Recall(
        memoryDb: memoryDb,
        registry: registry,
        catalog: _ftsCatalog,
      ),
      vector: VectorRecall(
        memoryDb: memoryDb,
        registry: registry,
        vectorTable: vectorTable,
      ),
      symbolic: SymbolicRecall(memoryDb: memoryDb),
      graphWalk: GraphWalkRecall(memoryDb: memoryDb),
      nodeReader: _reader,
      embedder: _embedder,
      clock: _clock,
      // § 6.2.1 / § 14: the `recencyBoosted` re-score reads its weight
      // and the per-type half-life from config. `halfLifeDaysFor` owns
      // the `default` fallback (§ 6.6), so a type without an override
      // gets the configured default rather than the executor's built-in.
      recencyWeight: config.retrieval.ranking.recencyWeight,
      halfLifeForType: (typeName) =>
          Duration(days: config.decay.halfLifeDaysFor(typeName)),
    );

    // 10. Wire the remaining data-plane owners — edges, classification,
    //     lifecycle, stacks, migrations, the stream-cursor store, and
    //     the stats collector. Each takes the shared handles and (where
    //     it writes) the event bus + budget tracker built in step 8.
    _edgeWriter = EdgeWriter(
      memoryDb: memoryDb,
      registry: registry,
      now: _clock.now,
      eventSink: _eventBus.emit,
      budgetTracker: _budgetTracker,
      agentRegistry: _agentRegistry,
    );
    _edgeReader = EdgeReader(memoryDb: memoryDb);
    _lifecycle = NodeLifecycleManager(
      memoryDb: memoryDb,
      now: _clock.now,
      // Node-lifecycle producer: promote / demote / forget transitions
      // are counted through the tap so `stats()` is exact (§ 17).
      eventSink: _emitLifecycleCounted,
    );
    _accessRecorder = NodeAccessRecorder(
      memoryDb: memoryDb,
      now: _clock.now,
    );
    _procedureMetrics = ProcedureMetricsWriter(
      memoryDb: memoryDb,
      now: _clock.now,
    );
    _centroidStore = CentroidStore(
      memoryDb: memoryDb,
      clock: _clock,
      eventSink: _eventBus.emit,
    );
    _classifier = Classifier(
      store: _centroidStore,
      eventSink: _eventBus.emit,
      clock: _clock,
    );
    _uncertainFinder = UncertainFinder(
      memoryDb: memoryDb,
      vectorTable: vectorTable,
      centroidStore: _centroidStore,
    );
    _stackApi = SqliteStackApi(
      memoryDb: memoryDb,
      now: _clock.now,
      eventSink: _eventBus.emit,
      budgetTracker: _budgetTracker,
      agentRegistry: _agentRegistry,
    );
    _migrations = JsonFileMigrationApi(
      directory: directory,
      clock: _clock.now,
      eventSink: _eventBus.emit,
    );
    _streamCursorStore = JsonFileStreamCursorStore(
      directory: directory,
      clock: _clock.now,
    );
    _statsCollector = MemoryStatsCollector(
      nodeCounts: _countNodesByType,
      edgeCounts: _countEdgesByType,
      stackSizes: _stackSizes,
      migrationProgress: _migrationProgress,
      lifecycleEventCounts: _lifecycleEventCounts,
      accessCountHistogram: _accessCountHistogram,
    );

    // 11. Profile administration (memory § 2.5). The registry operates
    //     on the `<root>/profiles/` sibling tier, so it takes the
    //     profile-*unbound* base config; child handles it spawns share
    //     this store's injected `sqlite` + `clock`. Profile lifecycle
    //     events ride this store's bus via `_eventBus.emit`.
    _profiles = SqliteMemoryProfileRegistry(
      baseConfig: config.withProfile(null),
      childStoreFactory: () => SqliteTomBrainMemory(
        sqlite: _sqlite,
        clock: _clock,
        embedder: _embedder,
      ),
      emit: _eventBus.emit,
      clock: _clock,
    );

    // H.28 — capture the profile binding for `currentProfile`
    // introspection (memory § 3.1). `null` is the unbound layout.
    _currentProfile = config.profile;

    _isOpen = true;
  }

  /// The profile-administration surface over the
  /// `<memory-root>/profiles/` tier (memory § 2.5).
  ///
  /// `list` / `exists` / `createProfile` / `seedProfile` /
  /// `dropProfile`. A profile scopes a whole handle — open a
  /// profile-bound store via `open(config.withProfile(name))` to read
  /// or write inside one. `dropProfile` is a whole-store delete
  /// (reset-to-zero) and is deliberately absent from the read-only MCP
  /// server (memory § 3.2).
  ///
  /// Throws a [StateError] if read before [open] completes.
  @override
  MemoryProfileRegistry get profiles {
    _ensureOpen('profiles');
    return _profiles;
  }

  /// Installs a vector index for each distinct embedding model declared
  /// by a registered node type.
  ///
  /// Types with `EmbeddingPolicy.none` contribute nothing. The rest are
  /// grouped by `(modelIdentity, dimensions)` so each physical vec0
  /// virtual table is created exactly once even though many types share
  /// the bootstrap default. `installIndex` is idempotent at matching
  /// dims, so this is safe to re-run on every open.
  static void _installVectorIndexes(
    VectorTable vectorTable,
    NodeTypeRegistry registry,
  ) {
    final installed = <String>{};
    for (final decl in registry.listAll()) {
      final policy = decl.embeddingPolicy;
      if (policy.isNone) continue;
      if (!installed.add(policy.modelIdentity)) continue;
      vectorTable.installIndex(
        modelId: policy.modelIdentity,
        dims: policy.dimensions,
      );
    }
  }

  /// Registers the 21 bootstrap node types and installs the six reserved
  /// stacks against [memoryDb], returning the warmed [NodeTypeRegistry].
  ///
  /// Idempotent on both halves:
  ///
  ///   * The registry warms its cache from the `node_types` rows already
  ///     on disk; each manifest type is only registered when absent, so
  ///     a re-open neither re-inserts nor trips
  ///     `NodeTypeAlreadyExists`.
  ///   * `installBootstrapStacks` checks each reserved name individually
  ///     and skips the ones already present.
  ///
  /// The critique hook is accept-all: the bootstrap manifest is the
  /// curated catalogue, not a runtime proposal, so there is nothing to
  /// veto. Runtime `registerNodeType` calls (#17) route through the same
  /// registry but with the substrate-backed critique hook the consumer
  /// wires in.
  Future<NodeTypeRegistry> _seedBootstrapCatalogue(Database memoryDb) async {
    final registry = NodeTypeRegistry(
      memoryDb: memoryDb,
      critiqueHook: (_, _) async => const CritiqueApproved(),
      now: _clock.now,
      // Provision the per-type FTS5 virtual tables as each bootstrap type
      // registers, so BM25 recall has tables to MATCH against. Shared
      // with the persister's Fts5Writer so writer and reader agree on the
      // table layout.
      ftsCatalog: _ftsCatalog,
    );

    final decls = await NodeTypeYamlLoader.loadBootstrapManifest();
    for (final decl in decls) {
      // Skip types already registered (re-open path). The registry warms
      // lazily, so the first `get` materialises the on-disk catalogue.
      if (registry.get(decl.typeName) != null) continue;
      await registry.registerNodeType(decl);
    }

    installBootstrapStacks(memoryDb, now: _clock.now);

    return registry;
  }

  @override
  Future<void> close() async {
    if (!_isOpen) return; // no-op on an already-closed store (spec § 3.1)
    // Flush any still-open trail writers (and their JSONL fsync) before
    // the database handles go away — the trail store writes its index
    // rows into memory.db, so it must finish while that handle is live.
    await _trailStore.close();
    // Release the stack API's stream controllers and close the event
    // bus while the database handles are still live (the stack API does
    // not own the handle, but closing it after dispose would race a
    // late event emission against the disposed DB).
    await _stackApi.close();
    _eventBus.close();
    _checkpointDatabase(_memoryDb);
    _checkpointDatabase(_vectorsDb);
    _memoryDb.dispose();
    _vectorsDb.dispose();
    _currentProfile = null;
    _isOpen = false;
  }

  @override
  String? get currentProfile {
    _ensureOpen('currentProfile');
    return _currentProfile;
  }

  @override
  Future<void> checkpoint() async {
    _ensureOpen('checkpoint');
    _checkpointDatabase(_memoryDb);
    _checkpointDatabase(_vectorsDb);
  }

  /// Sets the per-connection PRAGMAs every store handle shares: WAL
  /// journalling (so readers never block the single writer) and a
  /// bounded busy-timeout (so a momentarily-locked DB retries rather
  /// than failing instantly).
  static void _applyConnectionPragmas(Database db) {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA busy_timeout = 5000');
  }

  /// Truncating WAL checkpoint — flushes the WAL back into the main
  /// database file and resets it. Used by [close] and [checkpoint].
  static void _checkpointDatabase(Database db) {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  void _ensureOpen(String member) {
    if (!_isOpen) {
      throw StateError(
        'SqliteTomBrainMemory.$member called before open() completed',
      );
    }
  }

  // ─── WriteBudget enforcement ─────────────────────────────────────

  @override
  Future<void> beginRun({
    required String runId,
    required WriteBudget budget,
  }) async {
    _ensureOpen('beginRun');
    _budgetTracker.beginRun(runId: runId, budget: budget);
  }

  @override
  Future<void> endRun(String runId) async {
    _ensureOpen('endRun');
    _budgetTracker.endRun(runId);
  }

  @override
  Future<WriteBudget?> remainingBudget(String runId) async {
    _ensureOpen('remainingBudget');
    return _budgetTracker.remaining(runId);
  }

  // ─── Cognitive-agent scope registration ──────────────────────────

  /// Registers a cognitive agent so that subsequent writes carrying its
  /// [AgentRegistration.agentName] (via the write's [Scope.agentName]) are
  /// confined to the agent's declared read/write scopes. A write to a type,
  /// edge wire, or stack outside those scopes — or under an `agentName` that
  /// was never registered — is rejected with [AgentScopeViolation]. Writes
  /// that carry no `agentName` are unaffected.
  void registerAgent(AgentRegistration registration) {
    _ensureOpen('registerAgent');
    _agentRegistry.register(registration);
  }

  /// Removes a previously [registerAgent]ed agent. After this call, writes
  /// under its `agentName` are rejected as unregistered.
  void unregisterAgent(String agentName) {
    _ensureOpen('unregisterAgent');
    _agentRegistry.unregister(agentName);
  }

  /// Returns the registration for [agentName], or `null` if no agent under
  /// that name is currently registered.
  AgentRegistration? agentRegistration(String agentName) {
    _ensureOpen('agentRegistration');
    return _agentRegistry.resolve(agentName);
  }

  // ─── Node CRUD (persist/get live; lifecycle deferred) ────────────

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    _ensureOpen('persist');
    return _persister.persist(draft, scope: scope);
  }

  @override
  Future<Node?> get(NodeId id) async {
    _ensureOpen('get');
    return _reader.get(id);
  }

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async {
    _ensureOpen('getMany');
    return _reader.getMany(ids);
  }

  @override
  Future<void> recordAccess(List<NodeId> ids, {String? producer}) async {
    _ensureOpen('recordAccess');
    return _accessRecorder.recordAccess(ids, producer: producer);
  }

  @override
  Future<void> demote(NodeId id, DemotionReason reason) async {
    _ensureOpen('demote');
    return _lifecycle.demote(id, reason);
  }

  @override
  Future<void> promote(NodeId id, PromotionReason reason) async {
    _ensureOpen('promote');
    return _lifecycle.promote(id, reason);
  }

  @override
  Future<void> forget(NodeId id, ForgetReason reason) async {
    _ensureOpen('forget');
    return _lifecycle.forget(id, reason);
  }

  @override
  Future<void> updateProcedureMetrics(
    NodeId id, {
    ProcedureStatus? status,
    double? successRate,
    int? runCount,
    DateTime? lastRunAt,
  }) async {
    _ensureOpen('updateProcedureMetrics');
    return _procedureMetrics.updateProcedureMetrics(
      id,
      status: status,
      successRate: successRate,
      runCount: runCount,
      lastRunAt: lastRunAt,
    );
  }

  // ─── Edges ───────────────────────────────────────────────────────

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async {
    _ensureOpen('edge');
    return _edgeWriter.edge(from, type, to,
        scope: scope, weight: weight, attrs: attrs);
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    _ensureOpen('edgesOf');
    return _edgeReader.edgesOf(id, direction: direction, types: types);
  }

  // ─── Node-type registry ──────────────────────────────────────────

  @override
  Future<void> registerNodeType(NodeTypeDecl decl) async {
    _ensureOpen('registerNodeType');
    await _registry.registerNodeType(decl);
  }

  @override
  Future<List<NodeTypeDecl>> listNodeTypes() async {
    _ensureOpen('listNodeTypes');
    return _registry.listAll();
  }

  @override
  Future<NodeTypeDecl?> getNodeType(String typeName) async {
    _ensureOpen('getNodeType');
    return _registry.get(typeName);
  }

  // ─── Retrieval (deferred) ────────────────────────────────────────

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    _ensureOpen('recall');
    final result = await _recallExecutor.recall(query);
    await _maybeRecordAccess(query.countsAsAccess, result);
    return result;
  }

  @override
  Future<RecallResult> recallMulti(MultiRecallQuery query) async {
    _ensureOpen('recallMulti');
    final result = await _recallExecutor.recallMulti(query);
    await _maybeRecordAccess(query.countsAsAccess, result);
    return result;
  }

  /// Records usage for the nodes a recall returned when the query opted
  /// in via `countsAsAccess` (memory_optimization_plan § 8; spec § 6.6).
  ///
  /// The default ([countsAsAccess] `false`) is a no-op: most recalls are
  /// read-only inspections that must not perturb the recency / frequency
  /// signal the [RecallRanking] strategies read. When `true`, the
  /// returned node ids are stamped through the same [recordAccess] write
  /// any other consumer uses — bumping `last_access_ms` / `access_count`
  /// by one. The returned [result] is the pre-bump materialised snapshot;
  /// the usage write is a side effect, so a *subsequent* read reflects
  /// the raised values. An empty result list is itself a no-op inside
  /// [NodeAccessRecorder].
  Future<void> _maybeRecordAccess(
    bool countsAsAccess,
    RecallResult result,
  ) async {
    if (!countsAsAccess || result.nodes.isEmpty) return;
    await _accessRecorder.recordAccess(
      [for (final node in result.nodes) node.id],
    );
  }

  @override
  Stream<Node> stream(StreamQuery query) {
    _ensureOpen('stream');
    return _streamNodes(query);
  }

  /// Cursor-backed scan over the nodes matching [StreamQuery.filter]
  /// (spec § 9.2). Rows are walked in a stable `(created_at_ms ASC,
  /// id ASC)` keyset order so a restart resumes exactly where it left
  /// off; each batch is materialised through [NodeReader.getMany] and,
  /// when the query carries a resumable cursor, checkpointed to the
  /// durable [StreamCursorStore] so a process restart mid-walk resumes
  /// from the last batch rather than from zero.
  Stream<Node> _streamNodes(StreamQuery query) async* {
    final compiled = compileSymbolicFilter(query.filter);
    final batchSize = query.batchSize;
    final streamId = query.resumeFrom?.streamId;

    // Resume position: prefer the durable checkpoint (survives a
    // restart), then the in-query cursor, else start from the top.
    var lastCreatedMs = -1;
    var lastId = '';
    final resumePayload = streamId == null
        ? query.resumeFrom?.payload
        : (await _streamCursorStore.restore(streamId))?.payload ??
            query.resumeFrom?.payload;
    if (resumePayload != null) {
      lastCreatedMs = (resumePayload['createdAtMs'] as int?) ?? -1;
      lastId = (resumePayload['id'] as String?) ?? '';
    }

    while (true) {
      final hasCursor = lastCreatedMs >= 0;
      final sql = StringBuffer()
        ..write('SELECT id, created_at_ms FROM nodes WHERE ')
        ..write('(${compiled.whereSql})');
      final bindings = <Object?>[...compiled.bindings];
      if (hasCursor) {
        sql.write(' AND (created_at_ms > ? '
            'OR (created_at_ms = ? AND id > ?))');
        bindings
          ..add(lastCreatedMs)
          ..add(lastCreatedMs)
          ..add(lastId);
      }
      sql.write(' ORDER BY created_at_ms ASC, id ASC LIMIT ?');
      bindings.add(batchSize);

      final rows = _memoryDb.select(sql.toString(), bindings);
      if (rows.isEmpty) break;

      final ids = <NodeId>[];
      for (final row in rows) {
        final idStr = row['id'] as String;
        ids.add(NodeId.fromString(idStr));
        lastCreatedMs = row['created_at_ms'] as int;
        lastId = idStr;
      }

      final nodes = await _reader.getMany(ids);
      for (final node in nodes) {
        yield node;
      }

      // Checkpoint after the batch so a restart resumes here.
      if (streamId != null) {
        await _streamCursorStore.save(StreamCursor(
          streamId: streamId,
          payload: <String, Object?>{
            'createdAtMs': lastCreatedMs,
            'id': lastId,
          },
        ));
      }

      if (rows.length < batchSize) break;
    }
  }

  // ─── Classification ──────────────────────────────────────────────

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    _ensureOpen('classify');
    return _classifier.classify(embedding, target: target);
  }

  @override
  Future<void> updateCentroid(
    String forKey,
    Vec centroid, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    _ensureOpen('updateCentroid');
    // Q-A.63.2 (option 3): the abstract surface carries only
    // `(forKey, centroid)`; the concrete store derives the two fields
    // `CentroidStore.update` additionally needs — the embedding model
    // id and the accepted-example count — by hidden lookup. H.28 adds
    // the optional `target` so a `dream_recentroid_v1` concept pass can
    // write per-`Concept` centroids through the same surface.
    switch (target) {
      case ClassificationTarget.nodeType:
        // At #17 the resolvable keys are the registered node types; the
        // example count is the live (active) row count of that type.
        final decl = _registry.get(forKey);
        if (decl == null) {
          throw ArgumentError.value(
            forKey,
            'forKey',
            'SqliteTomBrainMemory.updateCentroid: no registered node '
                'type "$forKey" to derive the embedding model from',
          );
        }
        _centroidStore.update(
          forKey: CentroidStore.keyForNodeType(forKey),
          embeddingModelId: decl.embeddingPolicy.modelIdentity,
          centroid: centroid,
          exampleCount: _countActiveNodesOfType(forKey),
        );
      case ClassificationTarget.concept:
        // A Concept centroid is keyed by the concept *name* (`forKey`),
        // not by a node type. The embedding model is the one the
        // `Concept` node type itself declares (concept centroids are
        // means of Concept-node embeddings); the example count is the
        // live count of `Concept` rows feeding the cold-start gate
        // (memory § 7.1, reconciled at H.28).
        final conceptDecl = _registry.get('Concept');
        if (conceptDecl == null) {
          throw StateError(
            'SqliteTomBrainMemory.updateCentroid: the bootstrap '
            '"Concept" node type is not registered; cannot derive the '
            'embedding model for a per-Concept centroid.',
          );
        }
        _centroidStore.update(
          forKey: CentroidStore.keyForConcept(forKey),
          embeddingModelId: conceptDecl.embeddingPolicy.modelIdentity,
          centroid: centroid,
          exampleCount: _countActiveNodesOfType('Concept'),
        );
      case ClassificationTarget.procedure:
        // Procedure centroids are owned by tom_brain_procedure's
        // authoring pass, which derives the model + example count from
        // the procedure registry — not resolvable from this store.
        throw UnimplementedError(
          'SqliteTomBrainMemory.updateCentroid: Procedure-target '
          'centroids are written by the procedure layer, not the '
          'memory store. See memory § 7.1.',
        );
    }
  }

  @override
  Future<List<NodeId>> findUncertain({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) async {
    _ensureOpen('findUncertain');
    // The finder takes the namespaced key; the client surface takes the
    // bare node-type name. Namespace it on the way in (mirrors
    // updateCentroid).
    return _uncertainFinder.find(
      forKey: CentroidStore.keyForNodeType(forKey),
      low: low,
      high: high,
      limit: limit,
    );
  }

  // ─── Stacks ──────────────────────────────────────────────────────

  @override
  StackApi get stacks {
    _ensureOpen('stacks');
    return _stackApi;
  }

  // ─── Trails ──────────────────────────────────────────────────────

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    _ensureOpen('openTrail');
    return _trailStore.openTrail(run);
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    _ensureOpen('appendTrail');
    return _trailStore.appendTrail(id, entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    _ensureOpen('closeTrail');
    return _trailStore.closeTrail(id, outcome);
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    _ensureOpen('readTrail');
    return _trailStore.readTrail(id);
  }

  // ─── Migration checkpoints ───────────────────────────────────────

  @override
  MigrationApi get migrations {
    _ensureOpen('migrations');
    return _migrations;
  }

  // ─── Observability ───────────────────────────────────────────────

  @override
  Stream<MemoryEvent> events() {
    _ensureOpen('events');
    return _eventBus.events();
  }

  @override
  Future<MemoryStats> stats() async {
    _ensureOpen('stats');
    return _statsCollector.snapshot();
  }

  // ─── Stats source tear-offs ──────────────────────────────────────

  /// Live (active) node count keyed by type name. Backs
  /// [MemoryStats.nodeCountByType].
  Future<Map<String, int>> _countNodesByType() async {
    final rows = _memoryDb.select(
      'SELECT type_name, COUNT(*) AS n FROM nodes '
      'WHERE status = ? GROUP BY type_name',
      <Object?>[NodeStatus.active.name],
    );
    return <String, int>{
      for (final row in rows) row['type_name'] as String: row['n'] as int,
    };
  }

  /// Edge count keyed by edge wire name. Backs
  /// [MemoryStats.edgeCountByType].
  Future<Map<String, int>> _countEdgesByType() async {
    final rows = _memoryDb.select(
      'SELECT type, COUNT(*) AS n FROM edges GROUP BY type',
    );
    return <String, int>{
      for (final row in rows) row['type'] as String: row['n'] as int,
    };
  }

  /// Current size of each known stack. Backs [MemoryStats.stackSizes].
  Future<Map<String, int>> _stackSizes() async {
    final summaries = await _stackApi.list();
    return <String, int>{
      for (final summary in summaries) summary.name: summary.size,
    };
  }

  /// Migration progress keyed by id. Backs
  /// [MemoryStats.migrationProgress].
  Future<Map<String, double>> _migrationProgress() async {
    final statuses = await _migrations.listInProgress();
    return <String, double>{
      for (final status in statuses) status.migrationId: status.progress,
    };
  }

  /// Node-lifecycle transition tally since the store opened. Backs
  /// [MemoryStats.lifecycleEventCounts] (§ 17). Read off the synchronous
  /// counter the two lifecycle producers feed through
  /// [_emitLifecycleCounted], so the value is exact at the moment
  /// [stats] is called — no race against the async [events] feed.
  Future<Map<String, int>> _lifecycleEventCounts() async =>
      _lifecycleCounter.snapshot();

  /// Histogram of live (active) nodes bucketed by `access_count`. Backs
  /// [MemoryStats.accessCountHistogram] (§ 17) — the usage signal
  /// `recordAccess` writes when an answer cites a node. Buckets are the
  /// fixed labels `"0"`, `"1-2"`, `"3-5"`, `"6-10"`, `"11+"`; a bucket
  /// with no nodes is absent (not present-with-zero), matching the
  /// other count slices. `COALESCE` defends against a NULL column on a
  /// row written before the v2 backfill default applied.
  Future<Map<String, int>> _accessCountHistogram() async {
    final rows = _memoryDb.select(
      'SELECT CASE '
      "WHEN COALESCE(access_count, 0) = 0 THEN '0' "
      "WHEN COALESCE(access_count, 0) BETWEEN 1 AND 2 THEN '1-2' "
      "WHEN COALESCE(access_count, 0) BETWEEN 3 AND 5 THEN '3-5' "
      "WHEN COALESCE(access_count, 0) BETWEEN 6 AND 10 THEN '6-10' "
      "ELSE '11+' END AS bucket, COUNT(*) AS n "
      'FROM nodes WHERE status = ? GROUP BY bucket',
      <Object?>[NodeStatus.active.name],
    );
    return <String, int>{
      for (final row in rows) row['bucket'] as String: row['n'] as int,
    };
  }

  /// Event sink for the two node-lifecycle producers (the [NodePersister]
  /// and the [NodeLifecycleManager]). Tallies the transition on the
  /// synchronous [_lifecycleCounter] *before* forwarding to the bus, so a
  /// `promote()` immediately followed by `stats()` reads the fresh count
  /// even though [events] delivers on a later microtask (§ 17).
  void _emitLifecycleCounted(MemoryEvent event) {
    _lifecycleCounter.observe(event);
    _eventBus.emit(event);
  }

  /// Count of live (active) `nodes` rows of [typeName]. Used by
  /// [updateCentroid] to derive the centroid's example count.
  int _countActiveNodesOfType(String typeName) {
    final rows = _memoryDb.select(
      'SELECT COUNT(*) AS n FROM nodes '
      'WHERE type_name = ? AND status = ?',
      <Object?>[typeName, NodeStatus.active.name],
    );
    return rows.isEmpty ? 0 : rows.first['n'] as int;
  }
}
