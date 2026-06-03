// Barrel for the `migrations/` module (A.23 layout; A.24 surface;
// A.72 implementation; A.73 operator-UI view).
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
//   - `MigrationsInProgressView` — A.73 operator-UI view over
//     `MigrationApi.listInProgress` (§ 11.3 "a view
//     (`migrations_in_progress`)").
//   - `MigrationsInProgressSnapshot` / `MigrationProgressRow` /
//     `MigrationHealth` — the snapshot value types the view
//     produces.
//
// Forward-only per hard invariant § 1.7. The dispatcher's
// `restructure_tree_v1` is the only normal-operation caller of
// `MigrationApi`; Tom Forge's brain inspector is the only normal-
// operation caller of `MigrationsInProgressView`.

export 'json_file_migration_api.dart' show JsonFileMigrationApi;
export 'migration_api.dart'
    show MigrationApi, MigrationCursor, MigrationDecl, MigrationStatus;
export 'migration_events.dart' show MigrationProgressed;
export 'migrations_in_progress_view.dart'
    show
        MigrationHealth,
        MigrationProgressRow,
        MigrationsInProgressSnapshot,
        MigrationsInProgressView;
