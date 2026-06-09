// FIFO foreground queue tests (Plan step D.19;
// `tom_brain_procedure_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1).
//
// D.19 fills the FIFO foreground queue behind the unchanged
// `submitForeground` signature: a busy foreground slot enqueues the
// submission (configurable depth, default 4) and starts queued runs in
// submission order as the slot frees, instead of failing loudly. Overflow —
// slot busy *and* queue at capacity — raises `ForegroundQueueFull`. The
// background slot keeps its single-run, no-queue behaviour (pinned in
// `d18_run_coordinator_test.dart`).
//
// What is pinned here:
//
//   - default queue depth is 4; depth is configurable; negative depth is
//     rejected at construction;
//   - a busy-foreground submission enqueues (does not throw, does not run its
//     body) and `foregroundQueueLength` reflects the wait count;
//   - queued runs start in FIFO order once the slot frees, each carrying its
//     own result back to its own caller;
//   - the queue drains fully, the slot ends free, and the queue continues
//     past a failed queued run (each failure reaches only its own caller);
//   - overflow raises `ForegroundQueueFull(depth)`, leaving the queue
//     untouched; depth 0 disables queueing entirely;
//   - foreground queueing leaves the independent background slot alone.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ForegroundQueueFull, RunCoordinator;

void main() {
  group('D.19 foreground queue — construction', () {
    test('default foreground queue depth is 4 and starts empty', () {
      final coordinator = RunCoordinator();
      expect(coordinator.foregroundQueueDepth, 4);
      expect(coordinator.foregroundQueueLength, 0);
    });

    test('the foreground queue depth is configurable', () {
      final coordinator = RunCoordinator(foregroundQueueDepth: 7);
      expect(coordinator.foregroundQueueDepth, 7);
    });

    test('a negative foreground queue depth is rejected at construction', () {
      expect(
        () => RunCoordinator(foregroundQueueDepth: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('D.19 foreground queue — enqueueing', () {
    test('a busy-foreground submission enqueues instead of throwing',
        () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();
      final first = coordinator.submitForeground<int>(() => gate.future);

      // The slot is busy, so a second submission waits rather than raising.
      var secondBodyStarted = false;
      final second = coordinator.submitForeground<int>(() async {
        secondBodyStarted = true;
        return 2;
      });

      expect(coordinator.hasForegroundRun, isTrue);
      expect(coordinator.foregroundQueueLength, 1);
      // The queued body has not run yet — the slot is not free.
      expect(secondBodyStarted, isFalse);

      gate.complete(1);
      expect(await first, 1);
      // Once the slot frees the queued run starts and carries its own result.
      expect(await second, 2);
      expect(secondBodyStarted, isTrue);
      expect(coordinator.hasForegroundRun, isFalse);
      expect(coordinator.foregroundQueueLength, 0);
    });

    test('queued foreground runs execute in FIFO submission order', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<void>();
      final order = <int>[];

      final run0 = coordinator.submitForeground<void>(() async {
        await gate.future;
        order.add(0);
      });
      coordinator.submitForeground<void>(() async => order.add(1));
      coordinator.submitForeground<void>(() async => order.add(2));
      final run3 = coordinator.submitForeground<void>(() async => order.add(3));

      expect(coordinator.foregroundQueueLength, 3);

      gate.complete();
      await run0;
      await run3;

      expect(order, <int>[0, 1, 2, 3]);
      expect(coordinator.hasForegroundRun, isFalse);
      expect(coordinator.foregroundQueueLength, 0);
    });

    test('the queue continues past a failed queued run, each failure reaching '
        'only its own caller', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<void>();
      final failure = StateError('queued boom');

      final run0 = coordinator.submitForeground<void>(() => gate.future);
      final failing =
          coordinator.submitForeground<void>(() => Future<void>.error(failure));
      final after = coordinator.submitForeground<int>(() async => 7);

      gate.complete();
      await run0;

      await expectLater(failing, throwsA(same(failure)));
      // The failure did not stall the queue — the next run still ran.
      expect(await after, 7);
      expect(coordinator.hasForegroundRun, isFalse);
    });

    test('the slot is reusable after the queue fully drains', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<void>();

      final run0 = coordinator.submitForeground<int>(() async {
        await gate.future;
        return 0;
      });
      final run1 = coordinator.submitForeground<int>(() async => 1);

      gate.complete();
      await run0;
      await run1;

      expect(coordinator.hasForegroundRun, isFalse);
      // A fresh submission starts immediately on the now-free slot.
      final run2 = await coordinator.submitForeground<int>(() async => 2);
      expect(run2, 2);
    });
  });

  group('D.19 foreground queue — overflow', () {
    test('a submission past a full queue raises ForegroundQueueFull', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<void>();

      // One run occupies the slot; four more fill the default-depth-4 queue.
      coordinator.submitForeground<void>(() => gate.future);
      for (var i = 0; i < 4; i++) {
        coordinator.submitForeground<void>(() async {});
      }
      expect(coordinator.foregroundQueueLength, 4);

      // The fifth waiting run overflows.
      expect(
        () => coordinator.submitForeground<void>(() async {}),
        throwsA(isA<ForegroundQueueFull>().having((e) => e.depth, 'depth', 4)),
      );
      // The overflow leaves the queue untouched.
      expect(coordinator.foregroundQueueLength, 4);

      gate.complete();
    });

    test('overflow respects a custom queue depth', () async {
      final coordinator = RunCoordinator(foregroundQueueDepth: 1);
      final gate = Completer<void>();

      coordinator.submitForeground<void>(() => gate.future);
      coordinator.submitForeground<void>(() async {});
      expect(coordinator.foregroundQueueLength, 1);

      expect(
        () => coordinator.submitForeground<void>(() async {}),
        throwsA(isA<ForegroundQueueFull>().having((e) => e.depth, 'depth', 1)),
      );

      gate.complete();
    });

    test('depth 0 disables queueing — a busy slot overflows immediately',
        () async {
      final coordinator = RunCoordinator(foregroundQueueDepth: 0);
      final gate = Completer<void>();

      coordinator.submitForeground<void>(() => gate.future);

      expect(
        () => coordinator.submitForeground<void>(() async {}),
        throwsA(isA<ForegroundQueueFull>().having((e) => e.depth, 'depth', 0)),
      );
      expect(coordinator.foregroundQueueLength, 0);

      gate.complete();
    });

    test('ForegroundQueueFull names its depth', () {
      const error = ForegroundQueueFull(4);
      expect(error.depth, 4);
      expect(error.toString(), startsWith('ForegroundQueueFull:'));
      expect(error.message, contains('4'));
    });
  });

  group('D.19 foreground queue — slot independence', () {
    test('a foreground queue does not block the background slot', () async {
      final coordinator = RunCoordinator();
      final fgGate = Completer<void>();

      coordinator.submitForeground<void>(() => fgGate.future);
      coordinator.submitForeground<void>(() async {});
      expect(coordinator.foregroundQueueLength, 1);

      // The background slot is independent and admits a run immediately.
      final bg = await coordinator.submitBackground<int>(() async => 9);
      expect(bg, 9);
      // The foreground run + its queue are untouched by the background run.
      expect(coordinator.hasForegroundRun, isTrue);
      expect(coordinator.foregroundQueueLength, 1);

      fgGate.complete();
    });
  });
}
