// Barrel for the `preemption/` module (Plan step C.8).
//
// Owns the engine-local hard step deadline
// (`tom_brain_procedure_specification.md` § 9, Plan steps
// C.36–C.37):
//
//   - The hard step deadline (default 60 s wall clock) — force-yield +
//     mark step truncated.
//
// `PreemptionState` — the cooperative single-foreground / single-
// background state the engine yields against and the Phase D dispatcher
// drives — was extracted to `tom_brain_shared` at the Phase C review
// (C.48), because two distinct components reference the identical state
// contract. Consumers import it from
// `package:tom_brain_shared/tom_brain_shared.dart`; this module no longer
// re-exports it. The engine-native `yield_if_foreground_waiting()`
// checkpoint that reads the state stays in `primitives_native/`.
//
// Wiring across later Phase C steps:
//
//   - C.34 ✅ — `PreemptionState`: the shared object the engine yields
//     against and the dispatcher drives — the flag + resume-signal
//     (`Completer`) contract the yield primitive checks against. First cut
//     early as a dependency of the C.21 yield primitive (which lives in
//     `primitives_native/`) and finalised here. C.34 owns *only* this
//     shared object; the controller and deadline plug in against it later.
//   - C.36 ✅ — `StepDeadline` (`step_deadline.dart`): the hard per-step
//     wall-clock cap (default 60 s) that force-yields a runaway step and
//     reports a `StepTruncated` outcome the engine maps onto a
//     `RunCompletion(status: preempted, …)` + a `step_truncated` trail note.
//     Independent of `PreemptionState`: the state bounds the wait to one step
//     *cooperatively*; the deadline bounds the step itself *hard*.
//   - C.37 — yield / resume / deadline-truncation tests.
//
// The `PreemptionController` / `RunCoordinator` that *drives* this state
// belong to the Phase D dispatcher (spec § 10.3; build order D.23–D.25),
// not to Phase C.

export 'step_deadline.dart';
