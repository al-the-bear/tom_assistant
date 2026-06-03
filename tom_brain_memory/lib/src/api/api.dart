// Barrel for the `api/` module.
//
// Owns the primary in-process Dart surface described in
// `memory_specification.md` § 3.1 — the `TomBrainMemory` abstract
// class every other Tom Brain component talks to.
//
// Scope of the public surface (per spec § 3.1):
//
//   - Lifecycle — `open`, `close`, `checkpoint`.
//   - Node CRUD — `persist`, `get`, `getMany`, `demote`, `forget`.
//   - Edges — `edge`, `edgesOf`.
//   - Node-type registry — `registerNodeType`, `listNodeTypes`,
//     `getNodeType`.
//   - Retrieval — `recall`, `stream`.
//   - Classification — `classify`, `updateCentroid`, `findUncertain`.
//   - Stacks — `stacks` getter (delegates to `stacks/`).
//   - Trails — `openTrail`, `appendTrail`, `closeTrail`, `readTrail`
//     (record types live in `trails/`).
//   - Migrations — `migrations` getter (delegates to `migrations/`).
//   - Observability — `events`, `stats`.
//
// The MCP surface (§ 3.2) wraps a narrow slice of this API — six read
// tools plus the single closed-set `memory.persistNote` write — and
// lives under `mcp_server/`. The procedure-engine bridge (§ 3.3)
// adapts this API for isolate transport and lives under
// `isolate_adapter/`. Both of those modules consume `api/`; the
// reverse is forbidden.
//
// Wiring across later Phase A steps:
//
//   - A.24 ✅ — `TomBrainMemory` abstract interface +
//     `Scope` / `DemotionReason` / `ForgetReason` / `MemoryEvent` /
//     `MemoryStats` lands here.
//   - A.28+ — concrete `SqliteTomBrainMemory` implementation.
//   - A.78 ✅ — `TomBrainMemoryClient` consumer-facing interface
//     hoisted out of `TomBrainMemory`. `TomBrainMemory` is now the
//     in-process marker base class that `implements` it.
//
// `MemoryConfig` (consumed by `open()`) lives under `config/` and is
// exported from the top-level package barrel; it is intentionally not
// re-exported here.

export 'memory_event.dart' show MemoryEvent;
export 'memory_stats.dart' show LatencyHistogram, MemoryStats;
export 'scope.dart' show DemotionReason, ForgetReason, Scope;
export 'tom_brain_memory.dart' show TomBrainMemory;
export 'tom_brain_memory_client.dart' show TomBrainMemoryClient;
