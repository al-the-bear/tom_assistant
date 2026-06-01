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

export 'preemption_state.dart';
export 'step_deadline.dart';
