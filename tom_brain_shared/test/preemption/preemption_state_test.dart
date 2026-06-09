// PreemptionState unit tests (moved here at the C.48 reuse-extraction
// pass from `tom_brain_procedure`).
//
// Dart-level unit tests for the state object in isolation: the
// foreground-waiting flag, the resume-signal (`Completer`) lifecycle, and
// the idempotency of both control methods. The read-side checkpoint that
// *consumes* this object (`YieldPrimitive`) and the dispatcher coordinator
// that drives it live in their owning components; this suite covers only
// the shared state contract.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

void main() {
  group('PreemptionState', () {
    test('starts idle: no foreground waiting, no resume signal', () {
      final state = PreemptionState();
      expect(state.isForegroundWaiting, isFalse);
      expect(state.resumeSignal, isNull);
    });

    test('requestForegroundPreemption raises the flag and exposes a resume '
        'signal', () {
      final state = PreemptionState()..requestForegroundPreemption();
      expect(state.isForegroundWaiting, isTrue);
      expect(state.resumeSignal, isNotNull);
    });

    test('signalResume clears the flag and completes the resume signal',
        () async {
      final state = PreemptionState()..requestForegroundPreemption();
      final resume = state.resumeSignal;

      state.signalResume();

      expect(state.isForegroundWaiting, isFalse);
      expect(state.resumeSignal, isNull);
      // The future captured before resume still completes.
      await expectLater(resume, completes);
    });

    test('a second requestForegroundPreemption keeps the same resume signal',
        () {
      final state = PreemptionState()..requestForegroundPreemption();
      final first = state.resumeSignal;

      state.requestForegroundPreemption();

      expect(identical(state.resumeSignal, first), isTrue);
      // The flag stays raised; no second completer was minted.
      expect(state.isForegroundWaiting, isTrue);
    });

    test('signalResume with nothing pending is a no-op', () {
      final state = PreemptionState();
      // Must not throw and must leave the state idle.
      state.signalResume();
      expect(state.isForegroundWaiting, isFalse);
      expect(state.resumeSignal, isNull);
    });

    test('a redundant signalResume after a completed cycle is a no-op', () {
      final state = PreemptionState()..requestForegroundPreemption();
      state.signalResume();
      // Second resume with nothing parked must not throw and stays idle.
      state.signalResume();
      expect(state.isForegroundWaiting, isFalse);
      expect(state.resumeSignal, isNull);
    });

    test('the cycle can repeat: request → resume → request again', () async {
      final state = PreemptionState()..requestForegroundPreemption();
      final firstResume = state.resumeSignal;
      state.signalResume();
      await expectLater(firstResume, completes);

      state.requestForegroundPreemption();
      expect(state.isForegroundWaiting, isTrue);
      expect(state.resumeSignal, isNotNull);
      // The second cycle's signal is a fresh, not-yet-completed future.
      expect(identical(state.resumeSignal, firstResume), isFalse);
    });
  });
}
