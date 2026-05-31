// Barrel for the `config/` module.
//
// Owns `MemoryConfig` and supporting configuration types described
// in `memory_specification.md` § 14 — the structured object every
// consumer hands to `TomBrainMemory.open()`.
//
// Scope (per spec § 14):
//
//   - `MemoryConfig` — root configuration record (root path,
//     sqlite-vec extension path, retrieval / trails / classification
//     / budgets / MCP-server / replication tunables).
//   - Path resolution — `<root>/memory.db`, `vectors.db`, `trails/`,
//     `tombstones/`, `checkpoints/`.
//   - Bearer-token configuration for the MCP server (consumed by
//     `mcp_server/`).
//   - Replication topology — `ReplicationRole` (authority / worker /
//     mirror, per spec § 10).
//
// Configuration is loaded from a YAML file at start-up by the host
// component (Tom Assistant, the procedure engine, a test harness).
// `tom_brain_memory` reads the parsed object — it does not parse
// YAML itself.
//
// Wiring across later Phase A steps:
//
//   - A.24 ✅ — `MemoryConfig` + sub-config records land here.
//   - A.26 — consumption in `open()` (paths + WAL config).
//   - A.76 — bearer-token configuration consumed by the MCP server.
//   - A.83 ✅ — `MemoryConfigLoader` parses the YAML in spec § 14 into
//     the typed `MemoryConfig`.

export 'memory_config.dart';
export 'memory_config_loader.dart';
