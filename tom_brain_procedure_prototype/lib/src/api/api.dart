// Barrel for the `api/` module (Plan step C.8).
//
// Owns the engine's consumer-facing surface — the entry point the
// Phase D dispatcher binds against
// (`tom_brain_procedure_prototype_specification.md` § 10, Plan steps
// C.38–C.41):
//
//   - `ProcedureEngine.invoke(ProcedureInvocation, …)` — returns a
//     `ProcedureRun` handle that streams trail entries and resolves to
//     a `ProcedureOutcome`.
//   - Cancellation + timeout on the handle.
//   - The bridged sugar (`think`, `plan`, `create`, `critique`,
//     `decide`) as aliases over `runProcedure('<name>_v1', …)`. For the
//     prototype only `think_v1` exists as a no-op stub; the others
//     throw `ProcedureNotFound` informatively until Phase D loads the
//     system library.
//
// Wiring across later Phase C steps:
//
//   - C.38 — `ProcedureEngine.invoke` + run handle.
//   - C.39 — cancellation + timeout.
//   - C.40 — sugar aliases (`think_v1` stub; others throw).
//   - C.41 — invoke / cancellation / sugar-resolution tests.
//
// At C.8 this folder is intentionally empty. No exports yet.
