/// Self-organizing property-graph memory for Tom Brain.
///
/// This package owns the canonical knowledge graph that every Tom Brain
/// component reads from. It is the **second author** of every answer the
/// brain produces (quest overview, hard principle 4): each thinking trail
/// is augmented by retrieval over the graph, and each completed trail is
/// folded back into the graph by the cognitive agents.
///
/// The public surface is organised into one module per `lib/src/`
/// subfolder (`store/`, `retrieval/`, `nodes/`, `edges/`, `stacks/`,
/// `classification/`, `trails/`, `migrations/`, `sync/`, `api/`,
/// `mcp_server/`, `isolate_adapter/`, `config/`, plus `budget/`,
/// `cognitive_agents/`, and `observability/`). Each module's barrel
/// `show`-exports its own
/// public types; this top-level barrel re-exports those module barrels
/// so the whole surface is reachable through
/// `package:tom_brain_memory/tom_brain_memory.dart`.
///
/// See `_ai/quests/tom_brain/prototype_implementation_plan.md` Phase A
/// (steps A.21 – A.94) for the build order, and
/// `_ai/quests/tom_brain/memory_specification.md` for the contract this
/// package implements.
library;

// Module barrels. Each `src/<folder>/<folder>.dart` re-exports the
// public types of its module behind explicit `show` clauses; the
// top-level package surface mirrors the internal layout.
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
export 'src/observability/observability.dart';
export 'src/profiles/profiles.dart';
export 'src/retrieval/retrieval.dart';
export 'src/stacks/stacks.dart';
export 'src/store/store.dart';
export 'src/sync/sync.dart';
export 'src/trails/trails.dart';
