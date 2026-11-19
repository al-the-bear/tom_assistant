# tom_brain_substrate — Local Copilot Guidelines

**Project:** `tom_brain_substrate`
**Type:** Dart Package (Tom Brain substrate — LLM / embedding / web / MCP-client layer)
**Parent quest:** `tom_brain` (`_ai/quests/tom_brain/`)

## Role in the quest

This package is the only path between the procedure engine and any external model. Every prompt the brain issues passes through here, wrapped in the `AssistantDedicationAnchor`. It owns LLM providers (Ollama, OpenAI passthrough, Stub), provider routing, role / persona templates, the embedding service (`nomic-embed-text` via Ollama, 768 dims), web tools, and the MCP client used to talk to `tom_brain_memory`'s MCP server.

The substrate is a **client of memory**, not a writer to it. It produces embeddings and classifications; the procedure engine and memory decide what to persist.

## Hard rules

1. **No backwards compatibility** (quest overview hard principle 1). Provider, role, and config contract changes ship in lockstep with consumers in the same commit.
2. **Anchor injection is structural, not advisory.** Every public method that emits a prompt wraps it via `AssistantDedicationAnchor.wrap(...)` from `tom_brain_shared`. There is no flag, no overload, no path that bypasses it. B.23 / B.24 / B.46 are the load-bearing tests for this.
3. **Substrate does not write to memory.** It returns embeddings, completions, and tool outputs; the procedure engine decides what to persist via memory's surface.
4. **`tom_core_kernel`'s `HttpClient` is the only HTTP path.** No `package:http`, no `package:dio`. Retry / circuit-breaker / timeout policy is owned by kernel.
5. **No JWT minting or parsing here.** The substrate consumes bearer tokens for outbound MCP / OpenAI calls. Token issuance lives elsewhere.
6. **Stub provider is permanent infrastructure.** Tests exercising the substrate run the conformance suite against `StubLlmProvider` (deterministic, no network); Ollama is exercised opportunistically when present. This is so CI stays hermetic.
7. **Embedding identity travels with every embedding.** `EmbeddingService.embeddingIdentity` (model name + digest + dim + invocation mode) is consumed by memory's marker file (A.29) and the vec0 row layout (A.51). Drift is a hard fault, not a soft fallback.

## What belongs here

| Concern | Module |
|---|---|
| Top-level `TomBrainSubstrate` interface + in-process client | `lib/src/api/` |
| LLM provider abstraction + impls + routing | `lib/src/llm/` |
| Role / persona templates + anchor injection | `lib/src/roles/` |
| Embedding service | `lib/src/embed/` |
| Web tools (search + fetch) | `lib/src/web/` |
| MCP client | `lib/src/mcp_client/` |
| Configuration + observability | `lib/src/config/` |

## What does NOT belong here

- Memory storage / retrieval / cognitive agents — those live in `tom_brain_memory`.
- The recursive thinking / planning / creation loops — those live in the procedure engine (`tom_brain_procedure_engine`).
- HTTP / SSE / Telegram surfaces — those are in `tom_brain_access`.
- Identifier / vector / budget / result / event / time / version / anchor primitives — those live in `tom_brain_shared`. If a helper here would be useful to memory or the procedure engine too, the B.44 reuse pass moves it up to shared.
- JWT validation / minting; bearer-token handling beyond passing the token to outbound calls.

## Applicable global guidelines

| Document | Purpose |
|----------|---------|
| [Coding Guidelines](../../../_agent_guidelines/dart/coding_guidelines.md) | Naming, error handling, structure |
| [Clean Code Principles](../../../_agent_guidelines/dart/clean_code_principles.md) | DRY, abstraction, code smells |
| [Unit Tests](../../../_agent_guidelines/dart/unit_tests.md) | Test layout, matchers, mocking |
| [Test-Driven Development](../../../../../../../_agent_guidelines/test_driven_development.md) | Red → green → refactor |
| [Issue Implementation](../../../../../../../_agent_guidelines/issue_implementation.md) | Investigate → test → implement → verify |

## Driving documents

- `_ai/quests/tom_brain/substrate_specification.md` — the authoritative contract.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase B steps B.6 – B.48 own this project's prototype.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open questions tagged `Q-B.<step>.<n>`.

## Phase B end-gate touch points

This project participates in:

- B.43 **Code review pass B1** — every file vs. the spec section that owns it.
- B.44 **Reuse extraction pass** — anything here that should have lived in `tom_brain_shared` gets moved up.
- B.45 **API conformance tests** — black-box `TomBrainSubstrateClient` coverage.
- B.46 **Anchor enforcement test** — proves no public method can emit an unwrapped prompt.
- B.47 **Completeness check** — per-invariant table.
- B.48 **Provider matrix smoke** — Stub through the full suite; Ollama opportunistically.
