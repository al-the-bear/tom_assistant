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
        defaultEmbeddingMarkerProbe,
        defaultFts5Probe,
        defaultLoadExtensionProbe,
        embeddingModelMarkerPath,
        kEmbeddingModelMarkerFileName;
export 'memory_directory.dart';
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
