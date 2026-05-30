// Barrel for the `trails/` module (A.23 layout; A.24 surface; A.46
// writer).
//
// At A.46 this barrel exports:
//
//   - `ProcedureRunRef` — handle passed to `openTrail`.
//   - `TrailEntry` + named constructors (`invocation`,
//     `primitiveCall`, `persist`, `note`, `error`) + `TrailEntryKind`.
//   - `TrailOutcome` + `TrailOutcomeStatus`.
//   - `TrailWriter` — append-and-fsync JSONL writer over a single
//     date-sharded trail file (one per `ProcedureRun`).
//
// Wiring across later Phase A steps:
//
//   - A.47 — `openTrail` / `appendTrail` / `closeTrail` lifecycle
//     bound to `Trail` index rows in `memory.db`.
//   - A.48 — corruption-tolerant `readTrail` reader.
//   - A.49 — append-fsync ordering + corruption + roundtrip tests.

export 'trail.dart'
    show
        ProcedureRunRef,
        TrailEntry,
        TrailEntryKind,
        TrailOutcome,
        TrailOutcomeStatus;
export 'trail_writer.dart' show TrailWriter;
