// Foreground / background run coordinator tests (Plan step D.18;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1).
//
// D.18 delivers the coordinator core: the single-foreground /
// single-background invariant, the `submitForeground` / `submitBackground`
// surface, and the shared `PreemptionState` the engine yields against. These
// tests pin exactly that scope — they do NOT exercise the FIFO foreground
// queue (D.19, see `d19_foreground_queue_test.dart`), the preemption driving
// (D.20), or the hard deadline (D.21), which land in later substeps. (The
// full D.22 invariant suite supersedes these once the queue and preemption
// mechanics exist; D.18 still ships its own tests per the test-first
// discipline.)
//
// What is pinned here:
//
//   - a foreground / background run occupies its slot from submission until
//     its body completes, and the slot is clear once the submission's future
//     resolves (success and error);
//   - foreground and background are independent slots — both can be live at
//     once;
//   - a second concurrent *background* submission is rejected loudly with
//     `RunSlotBusy` (there is no background queue), and the existing run is
//     untouched. (The foreground slot no longer rejects since D.19 — it
//     queues; that behaviour is pinned in `d19_foreground_queue_test.dart`.)
//   - the coordinator exposes a shared `PreemptionState` (default fresh, or
//     an injected instance), so the engine and coordinator reference one
//     object.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show RunCoordinator, RunSlot, RunSlotBusy;
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

void main() {
  group('D.18 RunCoordinator — slot occupancy', () {
    test('a foreground run occupies the foreground slot until it completes',
        () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();

      expect(coordinator.hasForegroundRun, isFalse);

      final run = coordinator.submitForeground<int>(() => gate.future);

      // Submitted but not finished: the slot is occupied.
      expect(coordinator.hasForegroundRun, isTrue);
      // The background slot is untouched.
      expect(coordinator.hasBackgroundRun, isFalse);

      gate.complete(42);
      expect(await run, 42);

      // Once the submission's future resolves, the slot is clear.
      expect(coordinator.hasForegroundRun, isFalse);
    });

    test('a background run occupies the background slot until it completes',
        () async {
      final coordinator = RunCoordinator();
      final gate = Completer<String>();

      final run = coordinator.submitBackground<String>(() => gate.future);

      expect(coordinator.hasBackgroundRun, isTrue);
      expect(coordinator.hasForegroundRun, isFalse);

      gate.complete('done');
      expect(await run, 'done');

      expect(coordinator.hasBackgroundRun, isFalse);
    });

    test('the slot is released even when the run body fails', () async {
      final coordinator = RunCoordinator();
      final failure = StateError('boom');

      final run = coordinator.submitForeground<void>(() => Future.error(failure));

      expect(coordinator.hasForegroundRun, isTrue);
      await expectLater(run, throwsA(same(failure)));

      // A failed run still frees its slot — no leak.
      expect(coordinator.hasForegroundRun, isFalse);
    });

    test('a synchronous throw inside the body surfaces as a future error and '
        'still frees the slot', () async {
      final coordinator = RunCoordinator();
      final failure = ArgumentError('sync boom');

      final run = coordinator.submitForeground<int>(() => throw failure);

      await expectLater(run, throwsA(same(failure)));
      expect(coordinator.hasForegroundRun, isFalse);
    });

    test('the run body returns its own value to the caller', () async {
      final coordinator = RunCoordinator();

      final value = await coordinator.submitBackground<List<int>>(
        () async => <int>[1, 2, 3],
      );

      expect(value, <int>[1, 2, 3]);
    });
  });

  group('D.18 RunCoordinator — independent slots', () {
    test('a foreground and a background run can be live at the same time',
        () async {
      final coordinator = RunCoordinator();
      final fgGate = Completer<int>();
      final bgGate = Completer<int>();

      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      final bg = coordinator.submitBackground<int>(() => bgGate.future);

      expect(coordinator.hasForegroundRun, isTrue);
      expect(coordinator.hasBackgroundRun, isTrue);

      bgGate.complete(2);
      expect(await bg, 2);
      // Closing the background does not disturb the foreground.
      expect(coordinator.hasForegroundRun, isTrue);
      expect(coordinator.hasBackgroundRun, isFalse);

      fgGate.complete(1);
      expect(await fg, 1);
      expect(coordinator.hasForegroundRun, isFalse);
    });

    test('a slot can be reused once its previous run finished', () async {
      final coordinator = RunCoordinator();

      await coordinator.submitForeground<int>(() async => 1);
      expect(coordinator.hasForegroundRun, isFalse);

      // The slot is free again, so a new foreground run is admitted.
      final second = await coordinator.submitForeground<int>(() async => 2);
      expect(second, 2);
    });
  });

  group('D.18 RunCoordinator — single-background invariant (no queue)', () {
    test('a second concurrent background submission is rejected loudly',
        () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();
      final first = coordinator.submitBackground<int>(() => gate.future);

      expect(
        () => coordinator.submitBackground<int>(() async => 99),
        throwsA(isA<RunSlotBusy>()
            .having((e) => e.slot, 'slot', RunSlot.background)),
      );

      expect(coordinator.hasBackgroundRun, isTrue);
      gate.complete(1);
      expect(await first, 1);
    });

    test('the rejected background submission body never runs', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();
      final first = coordinator.submitBackground<int>(() => gate.future);
      var rejectedBodyRan = false;

      expect(
        () => coordinator.submitBackground<int>(() async {
          rejectedBodyRan = true;
          return 0;
        }),
        throwsA(isA<RunSlotBusy>()),
      );

      expect(rejectedBodyRan, isFalse);
      gate.complete(1);
      await first;
    });

    test('RunSlotBusy.toString names the busy slot', () {
      const error = RunSlotBusy(RunSlot.background);
      expect(error.toString(), startsWith('RunSlotBusy:'));
      expect(error.message, contains('background'));
    });
  });

  group('D.18 RunCoordinator — shared preemption state', () {
    test('exposes a fresh PreemptionState by default', () {
      final coordinator = RunCoordinator();
      expect(coordinator.preemption, isA<PreemptionState>());
      expect(coordinator.preemption.isForegroundWaiting, isFalse);
    });

    test('uses an injected PreemptionState so the engine shares one object',
        () {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);

      expect(identical(coordinator.preemption, shared), isTrue);

      // The engine yields against the same instance the coordinator holds:
      // a write through the shared state is visible via the coordinator.
      shared.requestForegroundPreemption();
      expect(coordinator.preemption.isForegroundWaiting, isTrue);
    });
  });
}
