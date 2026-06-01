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
//   - C.19 ✅ — `runProcedure` (depth-capped) + `RecursionLimitExceeded`
//     + the d4rt `installNativePrimitives` wiring.
//   - C.20 ✅ — `note(category, payload)` (`NotePrimitive`) + `TrailNote`
//     value + `TrailSink` seam + the d4rt wiring.
//   - C.21 ✅ — `yield_if_foreground_waiting` (`YieldPrimitive`) d4rt wiring
//     + the first cut of the checkpoint against the shared `PreemptionState`
//     (`preemption/`).
//   - C.22 — depth-cap / note / yield tests.
//   - C.35 ✅ — owning step for the yield checkpoint against the finalised
//     `PreemptionState` (C.34). Doc framing corrected (the driving
//     coordinator is Phase D, D.23–D.25; the deadline is C.36) and the
//     reusable-across-cycles contract pinned.
//   - C.40 ✅ — the sugar aliases (`think` / `plan` / `create` /
//     `critique` / `decide`) as fixed-id projections of `runProcedure`
//     (`sugar_aliases.dart`, § 5.2). Only `think_v1` exists in the
//     prototype (a no-op stub); the rest surface `ProcedureNotFound`.

export 'native_primitives_installer.dart';
export 'note_primitive.dart';
export 'recursion_limit_exceeded.dart';
export 'run_procedure_primitive.dart';
export 'sugar_aliases.dart';
export 'trail_note.dart';
export 'yield_primitive.dart';
