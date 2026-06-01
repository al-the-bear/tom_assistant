// Barrel for the `config/` module (Plan step C.8).
//
// Owns engine configuration and observability
// (`tom_brain_procedure_prototype_specification.md` § 11, Plan steps
// C.42–C.45):
//
//   - `EngineConfig` — YAML loader for the `scripts/system/` path,
//     `scripts/user/` path, sandbox switches, and deadline defaults.
//   - `TomLogger` categories: `tom_brain.engine.host`, `…bridge`,
//     `…store`, `…recorder`, `…preemption`.
//   - `EngineEvent` stream: `InvocationStarted`, `PrimitiveCalled`,
//     `StepYielded`, `InvocationCompleted`, `InvocationFailed`.
//
// Wiring across later Phase C steps:
//
//   - C.42 — `EngineConfig` YAML loader.
//   - C.43 — `TomLogger` category wiring.
//   - C.44 — `EngineEvent` stream.
//   - C.45 — config-roundtrip / event-ordering / logger tests.
//
// At C.8 this folder is intentionally empty. No exports yet.
