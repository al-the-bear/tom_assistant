# tom_brain_substrate

Substrate layer for Tom Brain — LLM provider abstraction, role / persona system, embedding service, web tools, MCP client.

## Scope

Every prompt the brain issues is dispatched through this layer wrapped in the `AssistantDedicationAnchor` (from `tom_brain_shared`). The substrate is the only path between the procedure engine and any external model. It owns:

- **LLM providers** — Ollama (default local), OpenAI-format passthrough (cloud fallback), Stub (tests).
- **Provider routing** — per-role provider selection, free-tier rotation, paid-tier opt-in, failover.
- **Roles** — `assistant_to_user`, `analyser`, `sub_thinker`, `recaller`, `evaluator`; each carries its persona text, objective, allowed-action set, and budget defaults.
- **Embedding service** — `nomic-embed-text` via Ollama, 768 dims; single + batched (B.5 decision).
- **Web tools** — `WebSearch` + `WebFetch`, retry / circuit-breaker via `tom_core_kernel`.
- **MCP client** — talks to `tom_brain_memory`'s MCP server and to external MCP servers, with bearer-token auth.
- **Anchor injection** — every prompt is wrapped via `AssistantDedicationAnchor.wrap(...)`; there is no public path that bypasses it.

The substrate **does not** call memory directly; it asks for embeddings, classifications, and LLM completions, and returns them to the procedure engine which decides what to persist.

## What lives here (planned per Phase B)

| Module | Source | Plan step |
|---|---|---|
| Top-level `TomBrainSubstrate` interface | `lib/src/api/` | B.9 |
| LLM provider abstraction + impls (Ollama, OpenAI passthrough, Stub) | `lib/src/llm/` | B.11 – B.17 |
| Provider routing | `lib/src/llm/` | B.18 – B.20 |
| Role templates + anchor injection | `lib/src/roles/` | B.21 – B.24 |
| Embedding service | `lib/src/embed/` | B.25 – B.28 |
| Web tools (search + fetch) | `lib/src/web/` | B.29 – B.32 |
| MCP client | `lib/src/mcp_client/` | B.33 – B.35 |
| Configuration + observability | `lib/src/config/` | B.36 – B.39 |
| In-process client | `lib/src/api/` | B.40 – B.42 |

## What does NOT live here

- The recursive thinking loop — that is the procedure engine's job (`tom_brain_procedure_engine`).
- Memory storage and retrieval — those live in `tom_brain_memory`. The substrate produces embeddings; memory consumes them.
- HTTP / SSE / Telegram surfaces — those are in `tom_brain_access`.
- JWT validation — the substrate is a client; it consumes bearer tokens, it does not parse or mint them.

## Status

Phase B — step B.6 scaffold complete. Empty barrel; smoke test only. Runtime dependencies land at B.7; folder layout at B.8; `TomBrainSubstrate` interface at B.9.

## See also

- `_ai/quests/tom_brain/substrate_specification.md` — the authoritative contract this package implements.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase B steps B.6 – B.48 own this project's prototype.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open questions tagged `Q-B.<step>.<n>`.
