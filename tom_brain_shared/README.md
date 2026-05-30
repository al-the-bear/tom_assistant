# tom_brain_shared

Shared types and primitives used across all Tom Brain components.

## Scope

This package is the cross-component vocabulary for the Tom Brain quest. It holds the types and constants every Tom Brain component (`tom_brain_memory`, `tom_brain_substrate`, `tom_brain_procedure_engine`, `tom_brain_procedure_dispatcher`, `tom_brain_access`) imports. It carries **no behaviour with side effects**, no I/O, no LLM calls, no storage. It is allowed exactly one dependency: `tom_basics`.

Per `_ai/quests/tom_brain/prototype_implementation_plan.md` step **A.9**, this dependency rule is load-bearing: every consumer can pull `tom_brain_shared` in without inheriting transitive runtime concerns.

## What lives here (planned per Phase A)

| Module | Source | Plan step |
|---|---|---|
| Identifier types (`NodeId`, `EdgeId`, `TrailId`, `RunId`) | `lib/src/ids/` | A.10 |
| Embedding vector primitive (`Vec`, cosine, normalisation) | `lib/src/embedding/` | A.11 |
| Budget primitive (`Budget`, `BudgetExceeded`) | `lib/src/budget/` | A.12 |
| Result envelope (`Result<T>`, `Ok`, `Err`) | `lib/src/result/` | A.13 |
| Event base classes (`MemoryEvent`, `BrainEvent`) | `lib/src/events/` | A.14 |
| Time abstractions (`MonotonicClock`, `WallClock`) | `lib/src/time/` | A.15 |
| Version / migration tags | `lib/src/version/` | A.16 |
| Assistant-dedication anchor constants | `lib/src/anchor/` | A.17 |

All of the above ship as part of Phase A.

## What does NOT live here

- LLM provider abstractions → `tom_brain_substrate`
- Memory store contracts → `tom_brain_memory`
- d4rt bridged primitives → `tom_brain_procedure_engine`
- HTTP / SSE / Telegram surfaces → `tom_brain_access`
- Anything with I/O, side effects, or a runtime dependency outside `tom_basics`

## Status

Phase A — step A.7 scaffold complete. Modules A.10 – A.17 land in subsequent steps.

## See also

- `_ai/quests/tom_brain/tom_brain_definition.md` — quest definition (§ 12 lists the component projects)
- `_ai/quests/tom_brain/memory_specification.md` — final memory spec (references the shared types this package will own)
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — driving plan (Phase A § A.7–A.17)
