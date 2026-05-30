// Barrel for the `migrations/` module (A.23 layout; A.24 surface).
//
// At A.24 this barrel exports:
//
//   - `MigrationApi` — the abstract surface returned by
//     `TomBrainMemory.migrations` (§ 11.3).
//   - `MigrationDecl` — registration payload for `start`.
//   - `MigrationCursor` — durable cursor state.
//   - `MigrationStatus` — progress report.
//
// Forward-only per hard invariant § 1.7. The dispatcher's
// `restructure_tree_v1` is the only normal-operation caller.

export 'migration_api.dart'
    show MigrationApi, MigrationCursor, MigrationDecl, MigrationStatus;
