# tom_brain_procedure — Local Copilot Guidelines

**Project:** `tom_brain_procedure`
**Type:** Dart Package (Tom Brain procedure prototype — thin engine + thin dispatcher)
**Parent quest:** `tom_brain` (`_ai/quests/tom_brain/`)

## Role in the quest

This package is the **glue + a script host + a recorder + a dispatcher policy**. It runs hand-written cognitive sequences as sandboxed d4rt scripts over a bridged primitive API that re-exposes `tom_brain_memory` + `tom_brain_substrate`. The prototype ships exactly one real sequence (`answer_with_memory_v1`: recall → answer → persist) and proves the machinery that runs it.

It owns nothing memory or substrate already owns. The engine half (Phase C) runs the procedure it is told to; the dispatcher half (Phase D) decides which procedure runs and when, consuming an `Access` object produced by Phase E.

## Hard invariants (prototype-scoped projection of `tom_brain_definition.md` § 14)

1. **PE-1 — The bridged primitive API is the only surface a procedure can touch.** A d4rt procedure cannot `import` SDK libraries, open files, make network calls, spawn isolates, or reach memory/substrate except through a bridged primitive. Enforced at two layers (d4rt sandbox + bridge); both must agree.
2. **PE-2 — A procedure is a d4rt script, not a workflow definition.** Stored verbatim, never transpiled into a graph. No YAML procedure language.
3. **PE-3 — Recursion is hard-capped at 10.** The 11th level errors with `RecursionLimitExceeded`. No `request_depth_extension` in the prototype.
4. **PE-4 — Every run is recorded as a first-class memory object** with the closed effort-metric set (`wallClockMs`, `llmCalls`, `inputTokens`, `outputTokens`, `toolCalls`, `memoryReads`, `memoryWrites`).
5. **PE-5 — Single foreground, single background, cooperative preemption.** Preemption happens at the *next* `yield_if_foreground_waiting()`, never mid-step. Hard step deadline (default 60 s) force-yields.
6. **PE-6 — System procedure v1 is permanent; fallback walks the version chain** on the four typed run-failure classes only (not environmental failures).
7. **PE-7 — Every prompt the machinery issues carries the assistant-dedication anchor.** `llm(...)` always routes through substrate; the engine has no raw-completion path that skips it.
8. **PE-8 — Sandboxed and budgeted.** A bridged call that would exceed any applicable budget is refused with `procedure.budget.exceeded`; the smallest applicable budget wins.
9. **PE-9 — No backwards compatibility.** Bridged-API surface, procedure headers, run-record shape, and config schema roll forward only; consumers migrate in the same change. No compat shim.
10. **PE-10 — Reuse before rebuild.** Built on `tom_d4rt_dcli` / `tom_core_d4rt` (d4rt host), `tom_brain_memory` + `tom_brain_substrate` *at the interface boundary only* (never reaching into `lib/src/`), `tom_core_kernel` (logging/locator), `tom_brain_shared` (shared types). No new d4rt interpreter, no new logger, no new HTTP stack.
11. **PE-11 — The dispatcher consumes `Access`, never a channel.** Single entry point `accept(Access)`; delivery happens through the `Access.deliver` callback.

## What belongs here

| Concern | Module |
|---|---|
| D4rt bridge config + `MemoryBridge` / `SubstrateBridge` | `lib/src/bridges/`, `build.yaml` |
| D4rt-DCli host | `lib/src/d4rt_host/` |
| Engine-native primitives | `lib/src/primitives_native/` |
| Procedure store + loader + resolver | `lib/src/procedure_store/` |
| Validator | `lib/src/validator/` |
| Run recorder | `lib/src/recorder/` |
| Cooperative preemption hooks | `lib/src/preemption/` |
| Engine API surface (`ProcedureEngine`) | `lib/src/api/` |
| Configuration + observability | `lib/src/config/` |
| Dispatcher + system procedure scripts | `lib/src/dispatcher/`, `scripts/` (Phase D) |

## What does NOT belong here

- Memory storage / retrieval / cognitive agents — those live in `tom_brain_memory`. Consume them at the interface boundary only.
- LLM providers / embeddings / web tools / anchor injection — those live in `tom_brain_substrate`. Consume them at the interface boundary only.
- HTTP / SSE / Telegram surfaces — those are in `tom_brain_access` (Phase E).
- Identifier / vector / budget / result / event / time / version / anchor primitives — those live in `tom_brain_shared`. If a helper here would also serve the dispatcher's later harvester, the C.48 reuse pass moves it up to shared.

## Applicable global guidelines

| Document | Purpose |
|----------|---------|
| [Coding Guidelines](/_copilot_guidelines/dart/coding_guidelines.md) | Naming, error handling, structure |
| [Clean Code Principles](/_copilot_guidelines/dart/clean_code_principles.md) | DRY, abstraction, code smells |
| [Unit Tests](/_copilot_guidelines/dart/unit_tests.md) | Test layout, matchers, mocking |
| [Test-Driven Development](/_copilot_guidelines/test_driven_development.md) | Red → green → refactor |
| [Issue Implementation](/_copilot_guidelines/issue_implementation.md) | Investigate → test → implement → verify |
| [D4rt BridgedClass Guidelines](/_copilot_guidelines/d4rt/d4rt_bridgedclass_guidelines.md) | Bridge registration patterns (C.11 – C.15) |
| [Testing D4rt Bridges](/_copilot_guidelines/d4rt/testing_d4rt_bridges.md) | Bridge e2e testing (C.47) |

## Driving documents

- `_ai/quests/tom_brain/tom_brain_procedure_specification.md` — the authoritative contract.
- `_ai/quests/tom_brain/tom_brain_definition.md` — the five-component split this is a prototype of (wins where it disagrees with the prototype spec).
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase C steps C.6 – C.53 and Phase D own this project's prototype.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.
- `_ai/quests/tom_brain/prototype_implementation_questions.md` — open questions tagged `Q-C.<step>.<n>`.

## Phase C end-gate touch points

This project participates in:

- C.46 **Code review pass C1** — every file vs. the spec section that owns it.
- C.47 **Bridge audit** — every bridged memory + substrate method has a passing roundtrip test; signature drift fails loudly.
- C.48 **Reuse extraction pass** — `PreemptionState`, `EffortMetric`, shared trail-entry shapes move up to `tom_brain_shared`.
- C.49 **API conformance tests** — black-box `ProcedureEngine` coverage (invoke / cancel / deadline / depth-cap / fallback).
- C.50 **D4rt sandbox proof** — a malicious script (importing `dart:io`, calling `Process.run`) is rejected by the validator.
- C.51 **Completeness check** — per-invariant table.
