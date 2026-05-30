// Barrel for the `api/` module (Plan step A.23).
//
// Owns the primary in-process Dart surface described in
// `memory_specification.md` § 3.1 — the `TomBrainMemory` abstract class
// every other Tom Brain component talks to.
//
// Scope of the public surface:
//
//   - Lifecycle — `open`, `close`, `checkpoint`.
//   - Node CRUD — `persist`, `get`, `getMany`, `demote`, `forget`.
//   - Edges — `edge`, `edgesOf`.
//   - Node-type registry — `registerNodeType`, `listNodeTypes`,
//     `getNodeType`.
//   - Retrieval — `recall`, `stream`.
//   - Classification — `classify`, `updateCentroid`, `findUncertain`.
//   - Stacks — `stacks` (delegates to `stacks/`).
//   - Trails — append/iterate (delegates to `trails/`).
//
// The MCP surface (§ 3.2) wraps a strict read-only slice of this API
// and lives under `mcp_server/`. The procedure-engine bridge (§ 3.3)
// adapts this API for isolate transport and lives under
// `isolate_adapter/`. Both of those modules consume `api/`; the
// reverse is forbidden.
//
// Wiring across later Phase A steps:
//
//   - A.24 — `TomBrainMemory` abstract interface lands here.
//   - A.25 — `MemoryConfig` lands under `config/` (consumed by
//             `open()`).
//   - A.28+ — concrete `SqliteTomBrainMemory` implementation.
//
// At A.23 this folder is intentionally empty. No exports yet.
