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

export 'memory_directory.dart';
