// Barrel for the `preemption/` module (Plan step C.48 reuse extraction).
//
// Module surface:
//
//   * `PreemptionState` — the cooperative single-foreground /
//     single-background preemption state. Carries the "foreground
//     waiting" flag and a `Completer` for the resume signal. The engine
//     reads it (`yield_if_foreground_waiting()`); the dispatcher's
//     coordinator drives it. Pure state object — only `dart:async`.
//
// Origin: extracted from `tom_brain_procedure_prototype` (Plan step
// C.34) at the Phase C review (C.48) because the engine (reader) and the
// dispatcher (writer) reference the identical state contract — a real
// two-component call site, not speculative reuse.
//
// What is deliberately NOT here: the `PreemptionController` /
// `RunCoordinator` that drive this state (Phase D dispatcher, spec
// § 10.3), the engine-native yield primitive, and the hard step deadline.
// Shared carries only the state contract both sides agree on.

export 'preemption_state.dart' show PreemptionState;
