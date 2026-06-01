// C.21 — engine-native `yield_if_foreground_waiting` primitive and the
// shared `PreemptionState` it reads (Dart-level unit tests).
//
// Drives `YieldPrimitive` and `PreemptionState` directly, off the d4rt
// boundary. The companion `native_primitives_installer_test.dart` proves
// the d4rt-facing half (a script calling `yield_if_foreground_waiting()`
// parks and resumes).
//
// These tests pin: the checkpoint returns immediately when no foreground is
// waiting; it parks on the resume signal when one is, completing only after
// the coordinator signals resume; the state's flag / resume-signal contract
// behaves (set on request, cleared on resume); both control methods are
// idempotent; and a yield captured before resume still completes.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

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
    });

    test('signalResume with nothing pending is a no-op', () {
      final state = PreemptionState();
      // Must not throw and must leave the state idle.
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

  group('YieldPrimitive', () {
    test('returns immediately when no foreground is waiting', () async {
      final primitive = YieldPrimitive(state: PreemptionState());
      // Completes without needing any resume signal.
      await expectLater(primitive.yieldIfForegroundWaiting(), completes);
    });

    test('parks until the coordinator signals resume', () async {
      final state = PreemptionState()..requestForegroundPreemption();
      final primitive = YieldPrimitive(state: state);

      var resumed = false;
      final yielding = primitive.yieldIfForegroundWaiting().then((_) {
        resumed = true;
      });

      // The checkpoint is parked while the foreground is still waiting.
      await Future<void>.delayed(Duration.zero);
      expect(resumed, isFalse);

      state.signalResume();
      await yielding;
      expect(resumed, isTrue);
    });

    test('a yield that started before resume completes when resume fires',
        () async {
      final state = PreemptionState()..requestForegroundPreemption();
      final primitive = YieldPrimitive(state: state);

      final yielding = primitive.yieldIfForegroundWaiting();
      state.signalResume();

      await expectLater(yielding, completes);
    });
  });
}
