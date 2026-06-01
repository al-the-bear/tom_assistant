// Barrel for the `primitives_native/` module (Plan step C.8).
//
// Owns the engine-native primitives — the acts that are implemented in
// Dart rather than re-exposed from memory/substrate
// (`tom_brain_procedure_prototype_specification.md` § 5, Plan steps
// C.19–C.22):
//
//   - `runProcedure(id, inputs, {version, depthDelta})` — hard depth
//     cap = 10 (definition § 7.3); no `request_depth_extension` in v1.
//   - `note(category, payload)` — writes to the current run's trail via
//     the recorder (`recorder/`).
//   - `yield_if_foreground_waiting()` — checks the shared
//     `PreemptionState` (`preemption/`) and either returns immediately
//     or awaits a resume signal.
//
// Wiring across later Phase C steps:
//
//   - C.19 — `runProcedure` + `RecursionLimitExceeded`.
//   - C.20 — `note`.
//   - C.21 — `yield_if_foreground_waiting`.
//   - C.22 — depth-cap / note / yield tests.
//
// At C.8 this folder is intentionally empty. No exports yet.
