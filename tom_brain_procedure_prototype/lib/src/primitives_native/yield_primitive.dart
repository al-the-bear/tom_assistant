// yield_if_foreground_waiting — the engine-native cooperative-preemption
// checkpoint primitive (Plan step C.21;
// `tom_brain_procedure_prototype_specification.md` § 5.1, § 9, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// ── What C.21 owns ──────────────────────────────────────────────────
//
// `yield_if_foreground_waiting()` is the cooperative checkpoint a
// background procedure calls between steps. It checks the shared
// [PreemptionState]: if no foreground run is waiting it returns
// immediately (the background keeps running); if one is waiting it parks
// on the state's resume signal and resumes only after the foreground run
// finishes and the coordinator signals resume. A foreground arrival thus
// preempts the background at its *next* checkpoint, never mid-step.
//
// ── What C.21 deliberately does NOT own ─────────────────────────────
//
// *Driving* the [PreemptionState] — setting the foreground-waiting flag on
// arrival and signalling resume on completion — belongs to the Phase D
// dispatcher's coordinator (C.34's `PreemptionController`). The hard step
// deadline (C.36) is also out of scope here. C.21 supplies only the
// read-side checkpoint; the write-side coordinator plugs in later against
// the same shared state object.

import '../preemption/preemption_state.dart';

/// The engine-native `yield_if_foreground_waiting` primitive.
///
/// Holds a reference to the shared [state] both the engine and the
/// dispatcher's coordinator see. Stateless apart from that reference: every
/// checkpoint re-reads the state, so a foreground arrival that lands between
/// two checkpoints is observed at the next one.
final class YieldPrimitive {
  /// Builds the primitive over the shared [state].
  YieldPrimitive({required this.state});

  /// The shared cooperative-preemption state this checkpoint reads.
  final PreemptionState state;

  /// Yields to a waiting foreground run, or returns immediately.
  ///
  /// Returns a completed future when no foreground run is waiting — the
  /// background run continues without interruption. When a foreground run
  /// is waiting, the returned future completes only after the coordinator
  /// calls [PreemptionState.signalResume] (i.e. the foreground run has
  /// finished), so the background run parks here rather than continuing
  /// mid-step.
  Future<void> yieldIfForegroundWaiting() async {
    // Capture the resume signal once: between reading it and awaiting it the
    // coordinator must not be able to swap the future out from under us.
    final resume = state.resumeSignal;
    if (resume == null) {
      return;
    }
    await resume;
  }
}
