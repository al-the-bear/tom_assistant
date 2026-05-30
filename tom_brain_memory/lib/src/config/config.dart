// Barrel for the `config/` module (Plan step A.23).
//
// Owns `MemoryConfig` and supporting configuration types described in
// `memory_specification.md` § 14 — the structured object every
// consumer hands to `TomBrainMemory.open()`.
//
// Scope:
//
//   - `MemoryConfig` — root configuration record (paths, transport
//     options, retention thresholds, classification bands).
//   - Path resolution — `<memory-root>/memory.db`, `vectors.db`,
//     `trails/`, `tombstones/`, `checkpoints/`.
//   - Embedding-model identity (§ 10.4) — the model name + dimensions
//     the store will refuse to mix with vectors of another model.
//   - Bearer-token configuration for the MCP server (consumed by
//     `mcp_server/` at A.76).
//   - Tunables: WAL checkpoint cadence, JSONL fsync mode, retrieval
//     budgets, classification bands.
//
// Configuration is loaded from a YAML file at start-up by the host
// component (Tom Assistant, the procedure engine, a test harness).
// `tom_brain_memory` reads the parsed object — it does not parse YAML
// itself.
//
// Wiring across later Phase A steps:
//
//   - A.25 — `MemoryConfig` record lands here.
//   - A.26 — consumption in `open()` (paths + WAL config).
//   - A.76 — bearer-token configuration consumed by the MCP server.
//
// At A.23 this folder is intentionally empty. No exports yet.
