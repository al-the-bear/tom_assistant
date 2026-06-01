# tom_brain_procedure_prototype

Procedure prototype for Tom Brain — a thin d4rt-hosted **engine** (Phase C) plus a thin **dispatcher** (Phase D) combined into one project per `tom_brain_definition.md` § 12.

## Scope

The prototype ships exactly one hand-written sequence — `answer_with_memory_v1` (recall → answer → persist) — and proves the *machinery* that runs it:

- **A sandboxed d4rt host** built on `tom_d4rt_dcli` / `tom_core_d4rt`. A procedure is a d4rt script, never a workflow definition (PE-2).
- **A bridged primitive API** that re-exposes `tom_brain_memory` + `tom_brain_substrate` plus four engine-native primitives (`runProcedure`, `note`, `yield_if_foreground_waiting`, depth handling). This bridged surface is the *only* thing a procedure can touch (PE-1).
- **A run recorder** — every run (success or fail) opens a memory trail, appends every primitive call, and persists a `ProcedureRun` node with the closed effort-metric set (PE-4).
- **A fallback chain** — the dispatcher steps down the version chain `[v_latest, …, v1]` on the four typed run-failure classes only (PE-6).
- **Cooperative single-foreground / single-background preemption** — a foreground arrival preempts a background run at its *next* checkpoint, never mid-step; a hard step deadline force-yields (PE-5).

Every prompt the machinery issues carries the assistant-dedication anchor because the `llm(...)` primitive always routes through substrate — there is no raw-completion path that skips it (PE-7).

## What this prototype is NOT

- Not the final `tom_brain_procedure_engine` + `tom_brain_procedure_dispatcher` split (those are two projects; the prototype combines a thin version of each into one).
- Not an authoring environment — no `author_new_procedure_v1`, no `procedure_author` role, no draft → critique → persist loop.
- Not the full bootstrap library — ships `answer_with_memory_v1` (real) plus a `think_v1` no-op stub; the other sugar verbs resolve to `ProcedureNotFound` informatively until the final dispatcher loads the system library.
- Not the dreaming agents, long-running migrations, or multi-machine topology.

## What lives here (planned per Phases C and D)

| Module | Source | Plan step |
|---|---|---|
| D4rt bridge-generator config + `MemoryBridge` / `SubstrateBridge` | `lib/src/bridges/`, `build.yaml` | C.11 – C.15 |
| D4rt-DCli host | `lib/src/d4rt_host/` | C.16 – C.18 |
| Engine-native primitives | `lib/src/primitives_native/` | C.19 – C.22 |
| Procedure store + loader + resolver | `lib/src/procedure_store/` | C.23 – C.26 |
| Validator | `lib/src/validator/` | C.27 – C.30 |
| Run recorder | `lib/src/recorder/` | C.31 – C.33 |
| Cooperative preemption hooks | `lib/src/preemption/` | C.34 – C.37 |
| Engine API surface (`ProcedureEngine`) | `lib/src/api/` | C.38 – C.41 |
| Configuration + observability | `lib/src/config/` | C.42 – C.45 |
| Dispatcher + `scripts/system/answer_with_memory_v1.dart` | `lib/src/dispatcher/`, `scripts/` | Phase D |

## What does NOT live here

- Memory storage / retrieval / cognitive agents — those live in `tom_brain_memory`. The engine consumes them at the interface boundary only (`TomBrainMemoryClient`), never reaching into `lib/src/`.
- LLM providers / embeddings / web tools / anchor injection — those live in `tom_brain_substrate`. The engine consumes them at the interface boundary only.
- HTTP / SSE / Telegram surfaces — those are in `tom_brain_access_prototype` (Phase E).
- Identifier / vector / budget / result / event / time / version / anchor primitives — those live in `tom_brain_shared`.

## Status

Phase C — step C.6 scaffold complete. Empty barrel; smoke test only. Runtime dependencies land at C.7; folder layout at C.8; dev-dependencies (bridge generator + build_runner) at C.9.

## See also

- `_ai/quests/tom_brain/tom_brain_procedure_prototype_specification.md` — the authoritative contract this package implements.
- `_ai/quests/tom_brain/tom_brain_definition.md` — the authoritative five-component split.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase C steps C.6 – C.53 (engine portion) and Phase D (dispatcher portion) own this project.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open questions tagged `Q-C.<step>.<n>`.
