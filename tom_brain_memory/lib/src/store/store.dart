// Barrel for the `store/` module (Plan step A.23).
//
// Owns the physical storage stack described in `memory_specification.md`
// § 2:
//
//   - `memory.db` — SQLite (nodes, edges, stacks, types, metadata).
//   - `vectors.db` — SQLite + sqlite-vec (vector indexes).
//   - FTS5 virtual tables per indexable text column.
//   - `pending_vector_writes` two-database WAL coordinator (§ 2.4).
//   - `tombstones/` and `checkpoints/` directories.
//
// Wiring across later Phase A steps:
//
//   - A.26 — open/close lifecycle, on-disk directory layout, WAL config.
//   - A.27+ — schema bootstrap, vec0 extension load, FTS5 setup.
//   - A.30+ — transactional node/edge writes, the two-DB commit log.
//
// A.26 — first concrete symbol lands: `MemoryDirectory`, the opener
// for the `<memory-root>` directory layout. Later steps (A.27+) add
// the SQLite schema, vec0 extension load, FTS5 setup, and the
// two-database transactional commit log alongside it.
//
// A.27 — `schema_v1.dart`: the v1 DDL constants and the
// idempotent `applySchemaV1(Database)` entry point, plus the
// `readSchemaVersion` probe the migrator (A.28) will chain off.
// The opener (A.26) does not call this yet; the migrator (A.28)
// is the wiring step.
//
// A.28 — `schema_migrator.dart`: the forward-only chained migrator.
// Owns `SchemaMigration` (the per-version registration value),
// `kSchemaMigrations` (the append-only registry — today: v1 only),
// `SchemaMigrator` (the class that walks the registry and applies
// pending versions), `SchemaMigrationReport` (the outcome record),
// and `SchemaVersionAhead` (the refusal-to-downgrade exception).
//
// A.30 — `two_db_coordinator.dart`: the two-database (memory.db +
// vectors.db) write coordinator. Owns `TwoDbCoordinator` (the runner
// that wraps every node-with-vector write in the
// `pending_vector_writes` WAL protocol), `VectorApplier` (the
// abstract `vectors.db`-side hook that A.50+ will implement against
// sqlite-vec), `PendingVectorWritePayload` (the input value type for
// a new write), `PendingVectorWrite` (the row read back during
// recovery), `TwoDbReplayReport` (the recovery outcome), and
// `TwoDbReplayFailure` (per-row failure record). The coordinator
// does not open or own `vectors.db`; it interacts with it solely
// through `VectorApplier`, keeping A.30 free of any sqlite-vec
// dependency.
//
// A.29 — `boot_integrity.dart`: the boot-time integrity check.
// Owns `BootIntegrityCheck` (the four-probe runner — schema version,
// FTS5 availability, loadExtension capability, embedding-model
// marker), `BootIntegrityReport` (the outcome record),
// `BootIntegrityFailure` (raised by `report.throwIfFailed()`),
// `IntegrityProbeResult` / `IntegrityProbeStatus` (per-probe value
// types), the `Fts5Probe` / `LoadExtensionProbe` /
// `EmbeddingMarkerProbe` typedefs (for test injection), the three
// `default*` probe functions, and the
// `kEmbeddingModelMarkerFileName` / `embeddingModelMarkerPath`
// convention for the marker file A.50+ will own.
//
// A.50 — `vec_extension_loader.dart`: the sqlite-vec (vec0)
// shared-library loader. Owns `VecExtensionLoader` (the load pipeline
// with injection points for open / lookup / register),
// `VecExtensionLoadResult` (the outcome record), `VecLoadOutcome` /
// `VecUnavailableReason` (per-outcome value types), the
// `DynamicLibraryOpener` / `DynamicLibrarySymbolLookup` /
// `ExtensionRegistrar` typedefs (for test injection), the
// `loadVecExtensionOrRefuseToBoot` wiring helper for the open() path,
// and the `VectorRuntimeUnavailable` exception it throws on every
// non-`loaded` outcome. Vector search is mandatory inside this quest
// (Q-A.6.1): the loader refuses to boot rather than fall back to
// BM25-only mode.
//
// A.51 — `vector_table.dart` + `vector_table_exception.dart`: the
// `vectors.db` side of the storage stack. Owns `VectorTable` (the
// per-model vector-index layer over `vectors.db`), `VectorIndexInfo`
// (the meta-row value type), `VectorMatch` (the k-NN result row),
// `VectorIndexBackend` (the backend interface), `Vec0VirtualTableBackend`
// (production — composes sqlite-vec DDL/SQL), `PlainBlobTableBackend`
// (test — plain SQL with a Dart-side brute-force k-NN), and the
// sealed exception family `VectorTableException` /
// `EmbeddingModelMismatch` / `EmbeddingDimsMismatch` /
// `IndexInstallationConflict`. Records the embedding-model identity
// per row by virtue of the per-model index layout (each model gets
// its own physical table, recorded in `vector_indexes`).
//
// A.52 — `vector_table_applier.dart`: the production [VectorApplier]
// that bridges the two-DB coordinator's `PendingVectorWrite` payload
// (raw little-endian float32 blob + embedding-model-id + node-id)
// into a `VectorTable.insertVector(nodeId, vector, modelId)` call.
// Owns the single class `VectorTableApplier`. The persister (A.34)
// already routes through the coordinator (A.30) when a draft carries
// an embedding under a non-`none` policy; A.52 supplies the
// production adapter that closes the wiring at the `vectors.db`
// boundary. Idempotency is delegated to `VectorTable.insertVector`
// (both ship backends use INSERT … ON CONFLICT DO UPDATE), so the
// coordinator's `recoverPending` path converges on replay.

export 'boot_integrity.dart'
    show
        BootIntegrityCheck,
        BootIntegrityFailure,
        BootIntegrityReport,
        EmbeddingMarkerProbe,
        Fts5Probe,
        IntegrityProbeResult,
        IntegrityProbeStatus,
        LoadExtensionProbe,
        classifyLoadExtensionCapability,
        defaultEmbeddingMarkerProbe,
        defaultFts5Probe,
        defaultLoadExtensionProbe,
        embeddingModelMarkerPath,
        kEmbeddingModelMarkerFileName;
export 'memory_directory.dart' show MemoryDirectory;
export 'sqlite_tom_brain_memory.dart' show SqliteTomBrainMemory;
export 'schema_migrator.dart'
    show
        SchemaMigration,
        SchemaMigrationReport,
        SchemaMigrator,
        SchemaVersionAhead,
        kSchemaMigrations;
export 'schema_v1.dart'
    show applySchemaV1, readSchemaVersion, schemaV1Statements,
        schemaV1Summary, schemaV1Version;
export 'schema_v2.dart'
    show applySchemaV2, schemaV2Summary, schemaV2Version;
export 'two_db_coordinator.dart'
    show
        PendingVectorWrite,
        PendingVectorWritePayload,
        TwoDbCoordinator,
        TwoDbReplayFailure,
        TwoDbReplayReport,
        VectorApplier;
export 'sqlite_vec_binary_resolver.dart'
    show SqliteVecBinaryResolver, UnsupportedSqliteVecPlatform;
export 'vec_extension_loader.dart'
    show
        DynamicLibraryOpener,
        DynamicLibrarySymbolLookup,
        ExtensionRegistrar,
        VecExtensionLoadResult,
        VecExtensionLoader,
        VecLoadOutcome,
        VecUnavailableReason,
        VectorRuntimeUnavailable,
        loadVecExtensionOrRefuseToBoot;
export 'vector_table.dart'
    show
        PlainBlobTableBackend,
        Vec0VirtualTableBackend,
        VectorIndexBackend,
        VectorIndexInfo,
        VectorMatch,
        VectorTable;
export 'vector_table_applier.dart' show VectorTableApplier;
export 'vector_table_exception.dart'
    show
        EmbeddingDimsMismatch,
        EmbeddingModelMismatch,
        IndexInstallationConflict,
        VectorTableException;
