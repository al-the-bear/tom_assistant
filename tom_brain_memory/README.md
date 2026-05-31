# tom_brain_memory

Self-organizing property-graph memory for Tom Brain. Storage, retrieval, cognitive agents, sleep cycles, MCP server, multi-machine sync, backup.

## Scope

This package owns the canonical knowledge graph that every Tom Brain component reads from. Per quest overview hard principle 4, memory is the **second author** of every answer the brain produces:

- Each thinking trail is augmented by retrieval over the graph.
- Each completed trail is folded back into the graph by the cognitive agents.

The thinking, planning, creation and procedure subsystems all reach memory through this package — directly (in-process), through an isolate adapter (same machine, different process), or through the MCP server (across machines).

## What lives here (planned per Phase A)

| Module | Source | Plan step |
|---|---|---|
| Top-level `TomBrainMemory` interface + `MemoryConfig` | `lib/src/api/` | A.24 |
| SQLite store + sqlite-vec + FTS5 driver | `lib/src/store/` | A.26 – A.34 |
| Migrations | `lib/src/migrations/` | A.35 |
| Node typing (Event, Claim, Concept, …) | `lib/src/nodes/` | A.36 – A.42 |
| Closed 12-edge alphabet | `lib/src/edges/` | A.43 – A.46 |
| Stacks (first-class mind-state lists) | `lib/src/stacks/` | A.47 – A.52 |
| Trails (JSONL append-only history) | `lib/src/trails/` | A.53 – A.56 |
| Four-mode retrieval (BM25, vector, graph, symbolic) | `lib/src/retrieval/` | A.57 – A.70 |
| LLM-independent classification | `lib/src/classification/` | A.71 – A.74 |
| MCP server (read-only v1) | `lib/src/mcp_server/` | A.75 – A.80 |
| Isolate adapter (in-process, same machine) | `lib/src/isolate_adapter/` | A.81 – A.84 |
| Configuration | `lib/src/config/` | A.85 |

## What does NOT live here

- Cognitive agents that *write* into memory live in `tom_brain_memory` itself, but the **scheduling** of sleep cycles is owned by the dispatcher (`tom_brain_procedure_dispatcher`).
- LLM provider integration — that is in `tom_brain_substrate`. Memory takes already-embedded vectors and already-classified texts; it does not call LLMs directly.
- The OpenAI-format gateway and Telegram bot — those are in `tom_brain_access`.

## Status

Phase A — step A.21 scaffold complete. Empty barrel; smoke test only. Real surface lands from A.22 onwards.

## See also

- `_ai/quests/tom_brain/memory_specification.md` — the authoritative contract this package implements.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase A steps A.21 – A.94 own this project's prototype.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
