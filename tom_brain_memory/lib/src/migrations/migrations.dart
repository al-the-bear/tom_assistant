// Barrel for the `migrations/` module (A.23 layout; A.24 surface;
// A.72 implementation).
//
// Exports:
//
//   - `MigrationApi` — the abstract surface returned by
//     `TomBrainMemory.migrations` (§ 11.3).
//   - `MigrationDecl` — registration payload for `start`.
//   - `MigrationCursor` — durable cursor state.
//   - `MigrationStatus` — progress report.
//   - `JsonFileMigrationApi` — A.72 file-backed concrete
//     implementation, one `restructure_<id>.json` per migration
//     under `<root>/checkpoints/`.
//
// Forward-only per hard invariant § 1.7. The dispatcher's
// `restructure_tree_v1` is the only normal-operation caller.

export 'json_file_migration_api.dart' show JsonFileMigrationApi;
export 'migration_api.dart'
    show MigrationApi, MigrationCursor, MigrationDecl, MigrationStatus;
