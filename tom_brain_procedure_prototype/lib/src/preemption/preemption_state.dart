// PreemptionState — the shared object the engine yields against and the
// dispatcher's coordinator drives (Plan step C.21 needs it; its full owner
// is C.34; `tom_brain_procedure_prototype_specification.md` § 9, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// ── What C.21 owns vs. C.34 ─────────────────────────────────────────
//
// C.21 implements the cooperative-checkpoint *contract* the engine-native
// `yield_if_foreground_waiting()` primitive checks against: a "foreground
// waiting" flag plus a resume signal (a `Completer`) a parked background
// run awaits. C.34 keeps this same shared object but grows the coordinator
// machinery around it — the `PreemptionController`, `PreemptionEvent`
// transitions, and the hard step deadline (C.36). C.21 deliberately stops
// at the flag + resume signal: that is exactly what the yield primitive
// (C.21) and its tests (C.22) need, and nothing the deadline owns.
//
// The state object is referenced by both the engine (which yields against
// it) and the Phase D dispatcher (which sets/clears it), so it is a prime
// candidate for extraction into `tom_brain_shared` at the Phase C review
// (C.48).

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
