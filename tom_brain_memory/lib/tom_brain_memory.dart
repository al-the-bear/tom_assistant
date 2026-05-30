/// Self-organizing property-graph memory for Tom Brain.
///
/// This package owns the canonical knowledge graph that every Tom Brain
/// component reads from. It is the **second author** of every answer the
/// brain produces (quest overview, hard principle 4): each thinking trail
/// is augmented by retrieval over the graph, and each completed trail is
/// folded back into the graph by the cognitive agents.
///
/// At the A.21 scaffold step this barrel is intentionally empty. The
/// surface lands incrementally across Phase A:
///
/// - A.23 — `lib/src/` folder layout (`store/`, `retrieval/`, `nodes/`,
///   `edges/`, `stacks/`, `classification/`, `trails/`, `migrations/`,
///   `api/`, `mcp_server/`, `isolate_adapter/`, `config/`).
/// - A.24 — `TomBrainMemory` abstract interface + `MemoryConfig`.
/// - A.26 – A.87 — store, retrieval, agents, sleep cycles, MCP server,
///   multi-machine sync, backup.
///
/// See `_ai/quests/tom_brain/prototype_implementation_plan.md` Phase A
/// (steps A.21 – A.94) for the build order, and
/// `_ai/quests/tom_brain/memory_specification.md` for the contract this
/// package implements.
library;

// Exports land here, one per module, as A.23+ steps ship.
