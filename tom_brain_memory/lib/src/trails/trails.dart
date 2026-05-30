// Barrel for the `trails/` module (A.23 layout; A.24 surface).
//
// At A.24 this barrel exports:
//
//   - `ProcedureRunRef` — handle passed to `openTrail`.
//   - `TrailEntry` + named constructors (`invocation`,
//     `primitiveCall`, `persist`, `note`, `error`) + `TrailEntryKind`.
//   - `TrailOutcome` + `TrailOutcomeStatus`.
//
// Wiring across later Phase A steps:
//
//   - A.46 – A.49 — JSONL writer, fsync-per-append ordering,
//     date-sharded path layout, corruption-tolerant reader.

export 'trail.dart'
    show
        ProcedureRunRef,
        TrailEntry,
        TrailEntryKind,
        TrailOutcome,
        TrailOutcomeStatus;
