# tom_brain_shared — Local Copilot Guidelines

**Project:** `tom_brain_shared`
**Type:** Dart Package (cross-component shared library)
**Parent quest:** `tom_brain` (`_ai/quests/tom_brain/`)

## Role in the quest

This package holds the cross-component vocabulary for Tom Brain. Every other Tom Brain component (`tom_brain_memory`, `tom_brain_substrate`, `tom_brain_procedure_engine`, `tom_brain_procedure_dispatcher`, `tom_brain_access`) imports from here.

## Hard rules

1. **No side effects.** No I/O, no network, no logging that writes anywhere, no global mutable state.
2. **One runtime dependency only: `tom_basics`.** Any new dependency requires an explicit decision at the quest level. See `prototype_implementation_plan.md` step A.9.
3. **No backwards compatibility.** Per `tom_brain_definition.md` § 0 and quest overview, contracts change in lockstep with consumers in the same commit.
4. **Pure-Dart, library-style code.** No platform conditionals, no `dart:io`, no `dart:isolate` here. Those live in consuming components.
5. **No re-exports of `tom_basics`.** Consumers depend on `tom_basics` directly when they need it.

## What belongs here

| Concern | Module |
|---|---|
| Identifier types (`NodeId`, `EdgeId`, `TrailId`, `RunId`) | `lib/src/ids/` |
| Embedding vector primitive | `lib/src/embedding/` |
| Budget primitive | `lib/src/budget/` |
| Result envelope | `lib/src/result/` |
| Event base classes | `lib/src/events/` |
| Time abstractions (clocks, monotonic) | `lib/src/time/` |
| Version / migration tags | `lib/src/version/` |
| Assistant-dedication anchor constants | `lib/src/anchor/` |

A type belongs here if (a) more than one Tom Brain component will reference it, and (b) it has no behaviour outside its own data shape.

## What does NOT belong here

- Memory store contracts (those live in `tom_brain_memory`).
- LLM provider interfaces (those live in `tom_brain_substrate`).
- d4rt bridged primitives (those live in `tom_brain_procedure_engine`).
- HTTP / SSE / Telegram surfaces (those live in `tom_brain_access`).
- Any helper that needs sqlite3, dart_mcp, dio, http, etc.

## Applicable global guidelines

| Document | Purpose |
|----------|---------|
| [Coding Guidelines](../../../_copilot_guidelines/dart/coding_guidelines.md) | Naming, error handling, structure |
| [Clean Code Principles](../../../_copilot_guidelines/dart/clean_code_principles.md) | DRY, abstraction, code smells |
| [Unit Tests](../../../_copilot_guidelines/dart/unit_tests.md) | Test layout, matchers, mocking |
| [Test-Driven Development](../../../_copilot_guidelines/test_driven_development.md) | Red → green → refactor |

## Driving documents

- `_ai/quests/tom_brain/tom_brain_definition.md` — quest definition (§ 12 lists this project).
- `_ai/quests/tom_brain/memory_specification.md` — first consumer of the shared types.
- `_ai/quests/tom_brain/prototype_implementation_plan.md` — Phase A steps A.7 – A.17 own this project's initial content.
- `_ai/quests/tom_brain/prototype_implementation_details.md` — append-per-step log of what was built.

## Phase A end-gate touch points

This project participates in:
- A.88 **Reuse extraction pass** — anything in `tom_brain_memory` that should have lived here gets moved in this step.
- A.93 **Final `dart analyze`** — zero warnings, zero Problems-pane entries on this project.
