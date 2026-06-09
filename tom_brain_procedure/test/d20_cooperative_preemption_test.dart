// Cooperative-preemption driving tests (Plan step D.20;
// `tom_brain_procedure_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// D.18 gave the coordinator the shared `PreemptionState` but did not drive
// it. D.19 added the FIFO foreground queue. D.20 makes the coordinator the
// *writer* of that shared state: a foreground submission admitted while a
// background run is live requests preemption, and the background — at its
// *next* `yield_if_foreground_waiting()` checkpoint — parks until the
// foreground workload fully drains and the coordinator signals resume.
//
// These tests pin exactly the D.20 contract:
//
//   - preemption is requested when (and only when) a foreground submission is
//     admitted while a background run is live (immediate-start *and* queued);
//   - no spurious preemption when no background is live;
//   - a background loop yielding through the real `YieldPrimitive` parks at
//     its *next* checkpoint (never mid-step) and resumes after the foreground
//     completes;
//   - resume fires only once the *whole* foreground chain (running + queued)
//     drains; back-to-back foreground arrivals resume the background exactly
//     once (idempotent);
//   - a failing foreground run still drains and resumes the background;
//   - an overflowing submission (`ForegroundQueueFull`) is not admitted and
//     leaves the resume bookkeeping to the admitted submissions.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ForegroundQueueFull, RunCoordinator, YieldPrimitive;
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

void main() {
  group('D.20 RunCoordinator — preemption requested on foreground arrival', () {
    test('a foreground submission admitted while a background run is live '
        'sets the foreground-waiting flag', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final bgGate = Completer<int>();
      final fgGate = Completer<int>();

      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      expect(shared.isForegroundWaiting, isFalse,
          reason: 'a lone background run is not preempted');

      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      expect(shared.isForegroundWaiting, isTrue,
          reason: 'a foreground arrival during a live background asks it to '
              'yield');

      fgGate.complete(1);
      bgGate.complete(2);
      expect(await fg, 1);
      expect(await bg, 2);
    });

    test('no preemption is requested when no background run is live', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final fgGate = Completer<int>();

      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      expect(shared.isForegroundWaiting, isFalse,
          reason: 'there is nothing to preempt, so the flag stays clear');

      fgGate.complete(9);
      expect(await fg, 9);
      expect(shared.isForegroundWaiting, isFalse);
    });

    test('a *queued* foreground submission (slot busy) still requests '
        'preemption while a background run is live', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final bgGate = Completer<int>();
      final fg1Gate = Completer<int>();
      final fg2Gate = Completer<int>();

      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      // First foreground occupies the slot and requests preemption.
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      expect(shared.isForegroundWaiting, isTrue);

      // The slot is busy, so the second submission is *queued*, not started.
      // An admitted-by-queue arrival must also keep the background preempted.
      final fg2 = coordinator.submitForeground<int>(() => fg2Gate.future);
      expect(coordinator.foregroundQueueLength, 1,
          reason: 'the second foreground waits behind the running first one');
      expect(shared.isForegroundWaiting, isTrue,
          reason: 'an admitted (queued) foreground keeps the background '
              'preempted');

      fg1Gate.complete(1);
      expect(await fg1, 1);
      // The queued fg2 now runs; the background stays preempted.
      expect(shared.isForegroundWaiting, isTrue);
      fg2Gate.complete(2);
      expect(await fg2, 2);

      bgGate.complete(3);
      expect(await bg, 3);
    });
  });

  group('D.20 RunCoordinator — background parks at next checkpoint, resumes',
      () {
    test('a background loop parks at its next checkpoint when a foreground '
        'arrives, completing its in-flight step, then resumes', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final checkpoint = YieldPrimitive(state: shared);

      final steps = <String>[];
      final step1Started = Completer<void>();
      final allowStep1Finish = Completer<void>();

      Future<String> background() async {
        steps.add('step0');
        await checkpoint.yieldIfForegroundWaiting(); // no fg yet → immediate
        steps.add('step1-start');
        step1Started.complete();
        await allowStep1Finish.future; // step still running when fg arrives
        steps.add('step1-end');
        await checkpoint.yieldIfForegroundWaiting(); // parks if fg waiting
        steps.add('step2');
        return 'bg-done';
      }

      final bg = coordinator.submitBackground<String>(background);
      await step1Started.future; // background is mid step1

      // Foreground arrives while the background is mid-step.
      final fgGate = Completer<int>();
      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      expect(shared.isForegroundWaiting, isTrue);

      // Let the in-flight step finish: the background completes step1 (never
      // mid-step) and then parks at the next checkpoint — it must NOT reach
      // step2 while the foreground is waiting.
      allowStep1Finish.complete();
      await pumpEventQueue();
      expect(steps, contains('step1-end'),
          reason: 'the in-flight step completes — preemption is at the next '
              'checkpoint, never mid-step');
      expect(steps, isNot(contains('step2')),
          reason: 'parked at the checkpoint while the foreground is waiting');

      // Foreground completes → coordinator signals resume → background runs on.
      fgGate.complete(7);
      expect(await fg, 7);
      expect(await bg, 'bg-done');
      expect(steps, contains('step2'));
      expect(shared.isForegroundWaiting, isFalse,
          reason: 'resume cleared the flag once the foreground drained');
    });

    test('a background already parked at a checkpoint resumes when the '
        'foreground completes', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final checkpoint = YieldPrimitive(state: shared);

      final fgGate = Completer<int>();
      final fg = coordinator.submitForeground<int>(() => fgGate.future);

      // No background yet, so no preemption was requested by the foreground.
      expect(shared.isForegroundWaiting, isFalse);

      // Submit a background that immediately hits a checkpoint. Because no
      // foreground preemption is pending (the fg arrived first, with no bg),
      // the checkpoint returns immediately and the background completes even
      // while the foreground still runs.
      var resumed = false;
      final bg = coordinator.submitBackground<void>(() async {
        await checkpoint.yieldIfForegroundWaiting();
        resumed = true;
      });

      await bg;
      expect(resumed, isTrue,
          reason: 'a background submitted after a lone foreground is not '
              'preempted (D.20 drives from the foreground side only)');

      fgGate.complete(1);
      expect(await fg, 1);
    });
  });

  group('D.20 RunCoordinator — resume timing across the foreground chain', () {
    test('resume fires only once the whole foreground chain (running + '
        'queued) drains', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final bgGate = Completer<int>();
      final fg1Gate = Completer<int>();
      final fg2Gate = Completer<int>();

      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      final fg2 = coordinator.submitForeground<int>(() => fg2Gate.future);

      expect(coordinator.foregroundQueueLength, 1);
      expect(shared.isForegroundWaiting, isTrue);

      // First foreground finishes; the queued second one starts. The chain is
      // not yet drained, so the background stays preempted.
      fg1Gate.complete(1);
      expect(await fg1, 1);
      expect(shared.isForegroundWaiting, isTrue,
          reason: 'a queued foreground is still pending — no resume yet');

      // Second (last) foreground finishes; the chain drains → resume.
      fg2Gate.complete(2);
      expect(await fg2, 2);
      expect(shared.isForegroundWaiting, isFalse,
          reason: 'the whole foreground chain drained, so the background '
              'resumes');

      bgGate.complete(3);
      expect(await bg, 3);
    });

    test('back-to-back foreground arrivals resume the background exactly once',
        () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final checkpoint = YieldPrimitive(state: shared);

      // A background loop that records each step. Step 1 is gated so the
      // foreground runs are guaranteed to arrive (setting the preemption
      // flag) *before* the loop reaches its first checkpoint — otherwise the
      // first checkpoint would be evaluated before any foreground was waiting.
      final steps = <int>[];
      final firstStepStarted = Completer<void>();
      final allowFirstStep = Completer<void>();
      Future<void> background() async {
        for (var step = 1; step <= 3; step++) {
          steps.add(step);
          if (step == 1) {
            firstStepStarted.complete();
            await allowFirstStep.future; // hold inside step 1
          }
          await checkpoint.yieldIfForegroundWaiting();
        }
      }

      final bg = coordinator.submitBackground<void>(background);
      await firstStepStarted.future; // bg is mid step 1, before any checkpoint

      // Two foreground runs arrive, one queued behind the other.
      final fg1Gate = Completer<int>();
      final fg2Gate = Completer<int>();
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      final fg2 = coordinator.submitForeground<int>(() => fg2Gate.future);
      expect(shared.isForegroundWaiting, isTrue);

      allowFirstStep.complete();
      await pumpEventQueue();
      // The background parked after step 1 (the second arrival did not orphan
      // it: the resume signal is shared, so it parks once).
      expect(steps, <int>[1]);

      // Drain the first foreground; the queued second keeps the background
      // parked.
      fg1Gate.complete(1);
      await fg1;
      await pumpEventQueue();
      expect(steps, <int>[1], reason: 'still parked — fg2 is pending');
      expect(shared.isForegroundWaiting, isTrue);

      // Drain the last foreground → single resume → the loop finishes.
      fg2Gate.complete(2);
      await fg2;
      await bg;
      expect(steps, <int>[1, 2, 3]);
      expect(shared.isForegroundWaiting, isFalse);
    });

    test('a foreground run that fails still drains and resumes the background',
        () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final bgGate = Completer<int>();
      final failure = StateError('boom');

      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      final fg = coordinator.submitForeground<int>(() => Future.error(failure));
      expect(shared.isForegroundWaiting, isTrue);

      await expectLater(fg, throwsA(same(failure)));
      expect(shared.isForegroundWaiting, isFalse,
          reason: 'a failing foreground still frees the slot and resumes the '
              'background');

      bgGate.complete(5);
      expect(await bg, 5);
    });
  });

  group('D.20 RunCoordinator — edges', () {
    test('an overflowing foreground submission is not admitted and does not '
        'disturb the preemption already requested by admitted runs', () async {
      final shared = PreemptionState();
      // depth 0 → a busy slot overflows immediately.
      final coordinator =
          RunCoordinator(preemption: shared, foregroundQueueDepth: 0);
      final bgGate = Completer<int>();
      final fg1Gate = Completer<int>();

      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      expect(shared.isForegroundWaiting, isTrue);

      var overflowBodyRan = false;
      expect(
        () => coordinator.submitForeground<int>(() async {
          overflowBodyRan = true;
          return 0;
        }),
        throwsA(isA<ForegroundQueueFull>()),
      );
      expect(overflowBodyRan, isFalse,
          reason: 'an overflowing submission is not admitted');
      expect(shared.isForegroundWaiting, isTrue,
          reason: 'the running foreground still keeps the background '
              'preempted');

      // Draining the single admitted foreground resumes the background.
      fg1Gate.complete(1);
      expect(await fg1, 1);
      expect(shared.isForegroundWaiting, isFalse);

      bgGate.complete(2);
      expect(await bg, 2);
    });

    test('a lone foreground run completing with no background is a resume '
        'no-op (no error, flag stays clear)', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);

      final value = await coordinator.submitForeground<int>(() async => 42);
      expect(value, 42);
      expect(shared.isForegroundWaiting, isFalse);
    });
  });
}
