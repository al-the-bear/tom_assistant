# tom_brain_access_prototype

Prototype **access layer** for Tom Brain — the inbound surface and the
actual running process. It accepts OpenAI-format HTTP/SSE and Telegram
inbound work, produces the `Access` object the dispatcher consumes, runs
`answer_with_memory_v1` through `tom_brain_procedure_prototype`, and
streams the answer back through the originating channel.

> **Status:** E.6 — project skeleton only. A buildable empty package with
> a smoke test. The real surface lands in Phase E steps E.7 – E.50.

## Role in the quest

This is the only package in the Tom Brain prototype that ships a running
process (`bin/tom_brain_access_prototype.dart`, lands at E.9). Everything
upstream of it — `tom_brain_memory`, `tom_brain_substrate`,
`tom_brain_procedure_prototype` — is a library that this process composes.

## What lives here (by plan step)

| Concern | Folder (lands at) | Plan steps |
|---|---|---|
| OpenAI HTTP/SSE adapter | `lib/src/adapters/openai_http_sse/` (E.8) | E.11 – E.18 |
| Telegram adapter | `lib/src/adapters/telegram/` (E.8) | E.19 – E.23 |
| Identity / session / persona | `lib/src/identity/` (E.8) | E.24 – E.27 |
| Edge security | `lib/src/edge_security/` (E.8) | E.28 – E.32 |
| Cheap kind-hint classifier | `lib/src/heuristic_classifier/` (E.8) | E.33 – E.35 |
| Outbound delivery | `lib/src/delivery/` (E.8) | E.36 – E.40 |
| Boot + running process | `lib/src/boot/`, `bin/` (E.8 / E.9) | E.41 – E.45 |
| Configuration | `lib/src/config/` (E.8) | E.44, E.47 |
| Public surface | `lib/src/api/` (E.8) | E.51 – E.52 |

## What does NOT live here

- Memory storage / retrieval / cognitive agents — `tom_brain_memory`.
- LLM / embedding / web / MCP-client surfaces — `tom_brain_substrate`.
- The procedure engine + dispatcher — `tom_brain_procedure_prototype`.
- Identifier / vector / budget / result / event / time / version /
  anchor / `Access` primitives — `tom_brain_shared`.

## Driving documents

- `_ai/quests/tom_brain/tom_brain_access_prototype_specification.md` —
  the authoritative contract.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase E.
- `_ai/quests/tom_brain/prototype_implementation_details.md` —
  append-per-step build log.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open
  questions tagged `Q-E.<step>.<n>`.
