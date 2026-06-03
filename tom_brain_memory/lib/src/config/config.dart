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

// `MemoryConfig` and its sub-config records moved to `tom_brain_shared`
// at A.88 (so substrate / engine / access can consume the memory
// interface without pulling sqlite3 / dart_mcp). Re-exported here so
// the memory barrel keeps the same surface. The filesystem path
// getters stay in this package on the `MemoryConfigPaths` extension
// (they need `dart:io`).
export 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BudgetsConfig,
        ClassificationConfig,
        DefaultWriteBudgetConfig,
        McpServerConfig,
        MemoryConfig,
        ReplicationConfig,
        ReplicationRole,
        RetrievalConfig,
        SqliteVecConfig,
        TrailsConfig;
export 'memory_config_loader.dart'
    show MemoryConfigException, MemoryConfigLoader;
export 'memory_config_paths.dart' show MemoryConfigPaths;
