// yield_if_foreground_waiting — the engine-native cooperative-preemption
// checkpoint primitive (Plan steps C.21 + C.35;
// `tom_brain_procedure_prototype_specification.md` § 5.1, § 9, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// ── Step ownership (C.21 → C.35) ────────────────────────────────────
//
// The d4rt-facing primitive (the global `yield_if_foreground_waiting()`
// reachable from a script, and its installer wiring) was first cut at C.21
// in subphase C.5 ("engine-native primitives"), because the installer
// needed something to register. C.35 — in subphase C.9 ("cooperative
// preemption hooks") — is the *owning* step for the checkpoint's behaviour
// against the finalised [PreemptionState] (C.34): "implement
// `yield_if_foreground_waiting()` against `PreemptionState`". The two plan
// items share the same production object; C.35 finalises it alongside the
// state it reads, the same way C.34 finalised the state object the C.21
// primitive depended on.
//
// ── What C.35 owns ──────────────────────────────────────────────────
//
// `yield_if_foreground_waiting()` is the cooperative checkpoint a
// background procedure calls between steps. It checks the shared
// [PreemptionState]: if no foreground run is waiting it returns
// immediately (the background keeps running); if one is waiting it parks
// on the state's resume signal and resumes only after the foreground run
// finishes and the coordinator signals resume. A foreground arrival thus
// preempts the background at its *next* checkpoint, never mid-step. The
// checkpoint is reusable across cycles: a background loop calls it between
// every step, and once a request→resume cycle completes the state is back
// to idle so the next call returns immediately.
//
// ── What C.35 deliberately does NOT own ─────────────────────────────
//
// *Driving* the [PreemptionState] — setting the foreground-waiting flag on
// arrival and signalling resume on completion — belongs to the Phase D
// dispatcher's `RunCoordinator` / `PreemptionController` (spec § 10.3;
// build order D.23–D.25), not to C.35. The hard step deadline (C.36) is
// also out of scope here. C.35 supplies only the read-side checkpoint; the
// write-side coordinator plugs in later against the same shared state
// object.

import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

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
