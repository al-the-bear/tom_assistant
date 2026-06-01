// C.21 + C.35 — engine-native `yield_if_foreground_waiting` primitive
// (Dart-level unit tests).
//
// Drives `YieldPrimitive` directly, off the d4rt boundary. The shared
// `PreemptionState` it reads is covered in isolation by
// `preemption_state_test.dart` (C.34); the d4rt-facing half (a script
// calling `yield_if_foreground_waiting()` that parks and resumes) by
// `native_primitives_installer_test.dart`.
//
// These tests pin: the checkpoint returns immediately when no foreground is
// waiting; it parks on the resume signal when one is, completing only after
// the coordinator signals resume; a yield captured before resume still
// completes; and (C.35) a single primitive instance is reusable across
// request→resume cycles — parking when needed, returning immediately once
// the state is idle again.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

void main() {
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

    // C.35 — the checkpoint is reusable across cycles. A background loop
    // calls it between every step; this pins that a single primitive
    // instance parks during a request→resume cycle and then returns
    // immediately again once the state is back to idle, rather than
    // staying parked or holding a stale resume signal.
    test('the same primitive parks then returns immediately across cycles',
        () async {
      final state = PreemptionState();
      final primitive = YieldPrimitive(state: state);

      // Step 1 — idle: returns immediately.
      await expectLater(primitive.yieldIfForegroundWaiting(), completes);

      // Step 2 — foreground arrives: parks until resume.
      state.requestForegroundPreemption();
      var resumed = false;
      final parked = primitive.yieldIfForegroundWaiting().then((_) {
        resumed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(resumed, isFalse);
      state.signalResume();
      await parked;
      expect(resumed, isTrue);

      // Step 3 — back to idle after the cycle: returns immediately again.
      await expectLater(primitive.yieldIfForegroundWaiting(), completes);
    });
  });
}
