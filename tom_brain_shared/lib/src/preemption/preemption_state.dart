// PreemptionState — the cooperative single-foreground / single-background
// preemption state shared across the procedure engine and the dispatcher
// (`tom_brain_procedure_specification.md` § 9, PE-5, § 10.3;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// ── Origin: the C.48 reuse-extraction pass ──────────────────────────
//
// First cut in `tom_brain_procedure` (Plan step C.34) as the
// shared object the engine-native `yield_if_foreground_waiting()`
// primitive reads against. The Phase D dispatcher's coordinator drives
// the *write* side of the same object (sets / clears the flag, signals
// resume). Because two distinct components — the engine (reader) and the
// dispatcher (writer) — reference the identical state contract, it moved
// here at the Phase C review (C.48). The class is a pure state object
// (only `dart:async`, no I/O), so it fits the A.9 dependency-discipline
// contract for `tom_brain_shared`.
//
// What is NOT here: the `PreemptionController` / `RunCoordinator` that
// *drive* this state belong to the Phase D dispatcher (spec § 10.3; build
// order D.23–D.25). The engine-native yield primitive and the hard step
// deadline that read this state stay in the procedure prototype. Shared
// carries only the state contract both sides agree on.

import 'dart:async';

/// The shared cooperative-preemption state a background run yields against.
///
/// At most one foreground and one background run exist at a time (PE-5). A
/// foreground arrival sets the [isForegroundWaiting] flag via
/// [requestForegroundPreemption]; the background run, at its *next*
/// `yield_if_foreground_waiting()` checkpoint, parks on [resumeSignal]
/// rather than continuing mid-step. When the foreground run finishes the
/// coordinator calls [signalResume], which completes the parked future and
/// clears the flag so the background run resumes.
///
/// Single-writer by design: the dispatcher's coordinator is the only caller
/// of [requestForegroundPreemption] / [signalResume]; the engine only
/// *reads* through [resumeSignal] / [isForegroundWaiting]. Both control
/// methods are idempotent so a redundant call (two foreground arrivals, a
/// resume with nothing parked) is a no-op rather than a corruption.
final class PreemptionState {
  bool _foregroundWaiting = false;
  Completer<void>? _resume;

  /// Whether a foreground run is currently waiting to preempt the
  /// background run. `false` in the steady state; `true` between a
  /// [requestForegroundPreemption] and the matching [signalResume].
  bool get isForegroundWaiting => _foregroundWaiting;

  /// The future a yielding background run awaits, or `null` when no
  /// preemption is pending.
  ///
  /// `null` is the signal the yield primitive uses to return immediately:
  /// no foreground is waiting, so there is nothing to park on. Non-null
  /// means a foreground arrival is pending and the future completes when
  /// [signalResume] fires.
  Future<void>? get resumeSignal => _resume?.future;

  /// Marks that a foreground run has arrived and the background run must
  /// yield at its next cooperative checkpoint.
  ///
  /// Idempotent: a second call while already waiting keeps the existing
  /// resume signal, so a background run parked on the first call is not
  /// orphaned by a redundant second arrival.
  void requestForegroundPreemption() {
    if (_foregroundWaiting) {
      return;
    }
    _foregroundWaiting = true;
    _resume = Completer<void>();
  }

  /// Releases any background run parked in a yield and clears the waiting
  /// flag.
  ///
  /// Called by the coordinator when the foreground run that preempted has
  /// finished. Idempotent: a call with no preemption pending is a no-op.
  void signalResume() {
    if (!_foregroundWaiting) {
      return;
    }
    _foregroundWaiting = false;
    final resume = _resume;
    _resume = null;
    if (resume != null && !resume.isCompleted) {
      resume.complete();
    }
  }
}
