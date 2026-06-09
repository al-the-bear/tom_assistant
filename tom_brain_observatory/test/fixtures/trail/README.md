<!-- tom-brain observatory test fixtures -->
# Trail fixtures (`fixturehost/`)

A small, **synthetic, secret-free** trail tree in the `tom_brain_logging.md`
full-mode layout, captured for the parser red-tests of every PT-1.* / PT-4.*
todo (`prompt_tracing_plan.md` PT-0.3).

These files are **hand-authored to the documented writer formats** (verified
against the shipped writers in `tom_brain_run/lib/src/` and against a real local
trail tree, read-only). Nothing here was copied from the live bomber store
(`prompt_tracing.md` § 7.2 forbids it): every id, timestamp, prompt, and answer
is invented, so there is no credential or raw-tier secret to scrub. The full raw
tier (`incoming/`, `llm/`, `procedures/`, `memory/`, `brain.log`, `components/`)
is **tracked on purpose** here — a fixture is test data, not a live trail, so the
real tree's raw-tier `.gitignore` is deliberately not reproduced.

## What the fixture exercises

One session (`sess-fixture-0001`, principal `fixture-user`, channel `openai`,
profile `default`, substrate `local/fixture-model`) with three turns:

| Turn | turnId | Shape | Exercises |
|---|---|---|---|
| A | `260101-120000.000001` | multi-sub-run, `accepted` | `RunTree` recursion to depth 3 (`answer_with_memory_v1` → `retrieve_for_prompt_v1` → `recall_semantic_v1`), an LLM call, memory primitives, a tool call (live-trail) — PT-1.1/1.2 |
| B | `260101-120100.000002` | `errored` | the error path: a `ProcedureErrorNode` + `outcome errored`, a failed tool call in the live-trail — PT-1.2/2.3 |
| C | `260101-120200.000003` | in-flight / streaming | a live-trail block with **no `### ✅ DONE` banner**, and absence from `summary/` + `procedures/` (it has not completed) — PT-1.3 (degrade) / PT-4 (live-tail) |

## Layout

```
fixturehost/
  incoming/openai/<turnId>.raw.json          three inbound requests (§5.3)
  llm/<role>/<turnId>__<seq>.raw.json         LLM-call raw dumps (§5.2)
  procedures/answer_with_memory_v1/<turnId>__<runId>.log   run trees (§5.7), turns A+B
  memory/default.log                          per-profile memory accesses (§5.6)
  sessions/sess-fixture-0001.summary.md       per-session transcript (§5.4), turns A+B
  sessions/sess-fixture-0001.live-trail.md    streaming live-trail (§5.9), A+B done, C in-flight
  summary/all-sessions.summary.md             global transcript (§5.5)
  summary/by-role/<role>.summary.md           per-role index (§5.8)
  summary/by-llm/local-fixture-model.summary.md   per-llm index (§5.8)
  brain.log + components/*.log                process/component line logs (§5.1)
```
