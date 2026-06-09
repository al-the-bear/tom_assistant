// Barrel for the `api/` module (Plan step C.8).
//
// Owns the engine's consumer-facing surface — the entry point the
// Phase D dispatcher binds against
// (`tom_brain_procedure_specification.md` § 10, Plan steps
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
//   - C.19 ✅ — the typed procedure I/O contract (`ProcedureInputs`,
//     `ProcedureResult`, `ProcedureStatus`) that `runProcedure(...)`
//     consumes and returns (§ 4.3, § 5.3). Introduced here because the
//     first engine-native primitive (C.19) needs it; the rest of the
//     surface below builds on it.
//   - C.38 ✅ — `ProcedureEngine.invoke` + run handle.
//   - C.39 ✅ — cancellation + timeout (`run.cancel()`, `invoke(..., timeout:)`;
//     `RunCancellation`).
//   - C.40 ✅ — sugar aliases (`think` / `plan` / `create` / `critique` /
//     `decide`) wired as fixed-id projections of `runProcedure`
//     (`primitives_native/sugar_aliases.dart`). `think_v1` runs the no-op
//     stub (`scripts/system/think_v1.dart`); the others surface
//     `ProcedureNotFound`.
//   - C.41 ✅ — invoke / cancellation / sugar-resolution tests
//     (`test/c41_engine_api_consolidation_test.dart`): black-box suite
//     driving `ProcedureEngine` only, folding the C.38/C.39/C.40 promises
//     into one contract pass plus cancellation through a sugar call.

export 'procedure_engine.dart';
export 'procedure_inputs.dart';
export 'procedure_invocation.dart';
export 'procedure_outcome.dart';
export 'procedure_result.dart';
export 'procedure_run.dart';
export 'run_cancellation.dart';
