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
// At A.23 this folder is intentionally empty. No exports yet.
