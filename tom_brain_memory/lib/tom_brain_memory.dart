/// Self-organizing property-graph memory for Tom Brain.
///
/// This package owns the canonical knowledge graph that every Tom Brain
/// component reads from. It is the **second author** of every answer the
/// brain produces (quest overview, hard principle 4): each thinking trail
/// is augmented by retrieval over the graph, and each completed trail is
/// folded back into the graph by the cognitive agents.
///
/// At A.23 the `lib/src/` folder layout is in place but every
/// subfolder barrel is intentionally empty — the actual surface lands
/// incrementally across the remaining Phase A steps:
///
/// - A.23 ✅ — `lib/src/` folder layout (`store/`, `retrieval/`,
///   `nodes/`, `edges/`, `stacks/`, `classification/`, `trails/`,
///   `migrations/`, `api/`, `mcp_server/`, `isolate_adapter/`,
///   `config/`).
/// - A.24 — `TomBrainMemory` abstract interface + `MemoryConfig`.
/// - A.26 – A.87 — store, retrieval, agents, sleep cycles, MCP server,
///   multi-machine sync, backup.
///
/// See `_ai/quests/tom_brain/prototype_implementation_plan.md` Phase A
/// (steps A.21 – A.94) for the build order, and
/// `_ai/quests/tom_brain/memory_specification.md` for the contract this
/// package implements.
library;

// A.23 — module barrels. Each `src/<folder>/<folder>.dart` is currently
// an empty barrel; the export here ensures the top-level package
// surface mirrors the internal layout from day one. As later A-steps
// add public symbols inside each module, the symbols become visible
// through `package:tom_brain_memory/tom_brain_memory.dart` without
// further changes here.
export 'src/api/api.dart';
export 'src/budget/budget.dart';
export 'src/classification/classification.dart';
export 'src/cognitive_agents/cognitive_agents.dart';
export 'src/config/config.dart';
export 'src/edges/edges.dart';
export 'src/isolate_adapter/isolate_adapter.dart';
export 'src/mcp_server/mcp_server.dart';
export 'src/migrations/migrations.dart';
export 'src/nodes/nodes.dart';
export 'src/retrieval/retrieval.dart';
export 'src/stacks/stacks.dart';
export 'src/store/store.dart';
export 'src/trails/trails.dart';
