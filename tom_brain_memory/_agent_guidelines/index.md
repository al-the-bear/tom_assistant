# tom_brain_memory — Local Copilot Guidelines

**Project:** `tom_brain_memory`
**Type:** Dart Package (Tom Brain canonical memory)
**Parent quest:** `tom_brain` (`_ai/quests/tom_brain/`)

## Role in the quest

This package owns the canonical property-graph memory for Tom Brain. Storage (SQLite + sqlite-vec + FTS5 + JSONL trails), retrieval (BM25 + vector + graph walk + symbolic, fused), the closed 12-edge alphabet, the stacks, the cognitive agents, sleep cycles, dreaming, shaking-event reconsolidation, the MCP server, multi-machine sync, and tiered backup all live here.

Every Tom Brain component reads memory through this package, either in-process or through the MCP server. Memory does not call LLMs directly — embeddings and classifications arrive already computed (substrate is the caller).

## Hard rules

1. **No backwards compatibility** (quest overview hard principle 1). Schema migrations are forward-only; consumers migrate in the same commit.
2. **No event is ever truly lost** (quest overview hard principle 6). Episodic records are immutable; consolidation produces derived records, never overwrites originals. The backup topology is engineered until this invariant holds.
3. **Memory does not call LLMs.** Embeddings and classifications arrive from `tom_brain_substrate` already computed. If a memory module finds itself needing to invoke a model, the design is wrong.
4. **Closed edge alphabet.** There are exactly 12 edge types (defined in `memory_specification.md` § 4). Adding a thirteenth is a spec change, not an implementation change.
5. **Open node-type registry, closed core.** New node subtypes can be registered, but the seven canonical types (Event, Claim, Concept, Conclusion, Question, Pattern, Contradiction, Source) are non-negotiable.
6. **MCP server stays read-only at v1.** Writes are reserved for in-process callers and the isolate adapter until the spec evolves.
7. **Determinism in retrieval scoring.** RRF + MMR + LLM re-rank are deterministic given the same inputs and the same seeds. Tests rely on this.

## What belongs here

| Concern | Module |
|---|---|
| Top-level interface + config | `lib/src/api/` |
| SQLite + sqlite-vec + FTS5 driver | `lib/src/store/` |
| Schema migrations | `lib/src/migrations/` |
| Node typing | `lib/src/nodes/` |
| Closed 12-edge alphabet | `lib/src/edges/` |
| Stacks | `lib/src/stacks/` |
| Trail (JSONL) ingestion | `lib/src/trails/` |
| Retrieval (BM25, vector, graph walk, symbolic, fused) | `lib/src/retrieval/` |
| LLM-independent classification (centroid-embedding) | `lib/src/classification/` |
| MCP server | `lib/src/mcp_server/` |
| Isolate adapter | `lib/src/isolate_adapter/` |
| Configuration | `lib/src/config/` |

## What does NOT belong here

- LLM provider calls — those live in `tom_brain_substrate`.
- The recursive thinking loop — that is `tom_brain_thinking` (consumes memory; does not implement it).
- Planning / creation / procedure loops — same.
- HTTP / SSE / Telegram surfaces — those are in `tom_brain_access`.
- Coding-agent ops, project cards, Docker orchestration, GIT.dev publishing — explicitly out of quest scope (overview § "Out of scope").

## Applicable global guidelines

| Document | Purpose |
|----------|---------|
| [Coding Guidelines](../../../_copilot_guidelines/dart/coding_guidelines.md) | Naming, error handling, structure |
| [Clean Code Principles](../../../_copilot_guidelines/dart/clean_code_principles.md) | DRY, abstraction, code smells |
| [Unit Tests](../../../_copilot_guidelines/dart/unit_tests.md) | Test layout, matchers, mocking |
| [Test-Driven Development](../../../../../../../_agent_guidelines/test_driven_development.md) | Red → green → refactor |
| [Issue Implementation](../../../../../../../_agent_guidelines/issue_implementation.md) | Investigate → test → implement → verify |

## Driving documents

- `_ai/quests/tom_brain/memory_specification.md` — the authoritative contract.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase A steps A.21 – A.94 own this project's prototype.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open questions tagged Q-A.<step>.<n>.

## Phase A end-gate touch points

This project participates in:

- A.88 **Reuse extraction pass** — anything here that should have lived in `tom_brain_shared` gets moved.
- A.89 – A.92 **Quality gates** — `dart analyze` zero warnings, `dart test` all green, coverage threshold met, dependency discipline test passes.
- A.94 **Phase A close** — `tom_brain_memory` v0.1.0 cut and consumed by Phase B (`tom_brain_substrate`).
