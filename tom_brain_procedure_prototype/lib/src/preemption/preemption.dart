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
//   - C.21 ✅ — `PreemptionState` (the flag + resume-signal contract the
//     yield primitive checks against). The yield primitive itself lives in
//     `primitives_native/`. C.34 keeps this same object and grows the
//     coordinator machinery + deadline around it.
//   - C.34 — `PreemptionController` over `PreemptionState`.
//   - C.36 — hard step deadline.
//   - C.37 — yield / resume / deadline-truncation tests.

export 'preemption_state.dart';
