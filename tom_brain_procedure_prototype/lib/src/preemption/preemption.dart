// Barrel for the `preemption/` module (Plan step C.8).
//
// Owns the cooperative single-foreground / single-background
// preemption primitives
// (`tom_brain_procedure_prototype_specification.md` § 9, Plan steps
// C.34–C.37):
//
//   - `PreemptionState` — the shared object the engine and dispatcher
//     both reference; carries the "foreground waiting" flag and a
//     `Completer` for the resume signal.
//   - `yield_if_foreground_waiting()` implementation against
//     `PreemptionState`.
//   - The hard step deadline (default 60 s wall clock) — force-yield +
//     mark step truncated.
//
// `PreemptionState` and any shared effort/trail shapes are flagged for
// extraction to `tom_brain_shared` at the Phase C review (C.48), since
// the Phase D dispatcher references the same state object.
//
// Wiring across later Phase C steps:
//
//   - C.34 — `PreemptionState`.
//   - C.35 — `yield_if_foreground_waiting`.
//   - C.36 — hard step deadline.
//   - C.37 — yield / resume / deadline-truncation tests.
//
// At C.8 this folder is intentionally empty. No exports yet.
