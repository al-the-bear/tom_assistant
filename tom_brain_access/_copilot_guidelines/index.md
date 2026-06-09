# tom_brain_access — Local Copilot Guidelines

**Project:** `tom_brain_access`
**Type:** Dart Package + executable (Tom Brain access layer — OpenAI HTTP/SSE + Telegram inbound surface)
**Parent quest:** `tom_brain` (`_ai/quests/tom_brain/`)

## Role in the quest

This package is the inbound surface and the **actual running process** of
the Tom Brain prototype. It accepts OpenAI-format HTTP/SSE and Telegram
work, produces the `Access` object the dispatcher
(`tom_brain_procedure`) consumes, resolves identity / session /
persona, enforces edge security, runs the cheap kind-hint classifier, and
streams answers back out. Everything upstream is a library; this is what
gets started.

## Hard rules

1. **No backwards compatibility** (quest overview hard principle 1).
   Channel, config, and `Access`-contract changes ship in lockstep with
   consumers in the same commit.
2. **The anchor pre-check is structural, not advisory.** No inbound prompt
   reaches the dispatcher without passing the edge anchor pre-check
   (E.31 / E.56). There is no bypass path.
3. **Consume upstream at the interface boundary only.** The access layer
   talks to `tom_brain_procedure` through its dispatcher
   surface; it never reaches into any `lib/src/` of an upstream package.
4. **CLI infrastructure belongs to `tom_build_base`.** The
   `bin/tom_brain_access.dart` executable (E.9) is built via
   `ToolDefinition` — no hand-rolled arg parsing / version / help.
5. **`tom_core_kernel`'s `HttpClient` is the only outbound HTTP path** for
   conformance / bench clients; the inbound server side uses
   `tom_core_server`'s shelf surface.
6. **Test loopbacks live in `test/`** until a second consumer earns a
   promotion (Q-E.5.3). The OpenAI loopback drives the mounted shelf
   handler socket-free; the Telegram loopback is a locally-authored
   `LoopbackChatApi implements ChatApi` (Q-E.5.1).

## What belongs here

| Concern | Module (lands at E.8) |
|---|---|
| OpenAI HTTP/SSE adapter | `lib/src/adapters/openai_http_sse/` |
| Telegram adapter | `lib/src/adapters/telegram/` |
| Identity / session / persona | `lib/src/identity/` |
| Edge security | `lib/src/edge_security/` |
| Cheap kind-hint classifier | `lib/src/heuristic_classifier/` |
| Outbound delivery | `lib/src/delivery/` |
| Boot + running process | `lib/src/boot/`, `bin/` |
| Configuration + public surface | `lib/src/config/`, `lib/src/api/` |

## What does NOT belong here

- Memory storage / retrieval / cognitive agents — `tom_brain_memory`.
- LLM / embedding / web / MCP-client surfaces — `tom_brain_substrate`.
- The procedure engine + dispatcher — `tom_brain_procedure`.
- Identifier / vector / budget / result / event / time / version /
  anchor / `Access` primitives — `tom_brain_shared`. If a helper here
  would be useful to the dispatcher or engine too, the E.52 reuse pass
  moves it up to shared.

## Applicable global guidelines

| Document | Purpose |
|----------|---------|
| [Coding Guidelines](/_copilot_guidelines/dart/coding_guidelines.md) | Naming, error handling, structure |
| [Clean Code Principles](/_copilot_guidelines/dart/clean_code_principles.md) | DRY, abstraction, code smells |
| [Unit Tests](/_copilot_guidelines/dart/unit_tests.md) | Test layout, matchers, mocking |
| [Test-Driven Development](/_copilot_guidelines/test_driven_development.md) | Red → green → refactor |
| [Issue Implementation](/_copilot_guidelines/issue_implementation.md) | Investigate → test → implement → verify |

## Driving documents

- `_ai/quests/tom_brain/tom_brain_access_specification.md` — the authoritative contract.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase E steps E.6 – E.60 own this project.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open questions tagged `Q-E.<step>.<n>`.

## Phase E end-gate touch points

This project participates in:

- E.51 **Code review pass E1** — every file vs. the spec section that owns it.
- E.52 **Reuse extraction pass** — `OutboundChunk`, `InboundRequest`, `DeliveryStalled`, `BackpressureSignal` likely move up to `tom_brain_shared`.
- E.53 **API conformance — OpenAI** (real HTTP client against the running process).
- E.54 **API conformance — Telegram** (loopback `ChatApi`).
- E.55 **End-to-end conformance** (start process → request → memory inspect).
- E.56 **Anchor enforcement at the edge**.
- E.57 **Completeness check** — per-invariant table.
- E.58 **Process-level bench** — inbound → first-SSE-chunk latency.
