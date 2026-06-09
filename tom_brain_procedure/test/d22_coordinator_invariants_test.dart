// Foreground / background coordinator — consolidated invariant suite (Plan
// step D.22; `tom_brain_procedure_specification.md` § 10.3, PE-5,
// § 14; `tom_brain_definition.md` § 7.1, § 14.10).
//
// D.18–D.21 each shipped their own per-step tests for the mechanic they
// introduced (the coordinator core, the FIFO queue, cooperative-preemption
// driving, the hard step deadline). D.22 is the *full invariant suite* for the
// whole "D.5 — Foreground / background coordinator" subphase: it re-proves the
// five guarantees the plan names as system-level invariants of the assembled
// `RunCoordinator`, each in isolation and then all five together in one
// end-to-end scenario, so a future change that breaks any single invariant —
// or the way they compose — fails here loudly:
//
//   1. single-foreground invariant — at most one foreground body executes at a
//      time, no matter how many are submitted concurrently;
//   2. single-background invariant — at most one background body is ever live;
//      a second concurrent background submission is rejected loudly;
//   3. preemption boundary is the *next* yield — a foreground arrival parks a
//      live background at its next cooperative checkpoint, never mid-step, and
//      it resumes only when the whole foreground chain drains;
//   4. hard deadline triggers — a body that never completes is force-yielded
//      with `RunDeadlineExceeded` and its slot is freed;
//   5. queue depth respected — the FIFO foreground queue never holds more than
//      its configured depth of waiting runs; overflow is rejected with
//      `ForegroundQueueFull`.
//
// The deadline-driven cases use an injected `_FakeTimer` (the same seam the
// C.36 `StepDeadline` and D.21 tests use) so truncation is deterministic and
// instantaneous; the non-deadline cases run under a generously large real
// deadline whose timer never fires.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        ForegroundQueueFull,
        RunCoordinator,
        RunDeadlineExceeded,
        RunSlot,
        RunSlotBusy,
        YieldPrimitive;
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

/// A `Timer` test double driving each per-run `StepDeadline` deterministically:
/// records the scheduled callback, tracks cancellation, and fires only on
/// [fire]. Identical in spirit to the D.21 double.
final class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;

  bool _active = true;
  int _ticks = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  @override
  void cancel() => _active = false;

  /// Fires the scheduled callback as the real timer would on expiry.
  void fire() {
    _ticks++;
    _active = false;
    callback();
  }
}

void main() {
  // Every per-run deadline timer the coordinator schedules, in creation order,
  // so a deadline-driven test can fire a specific run's deadline.
  late List<_FakeTimer> timers;

  /// Builds a coordinator whose per-run deadlines are driven by [_FakeTimer]s
  /// captured into [timers], so a hung body can be force-yielded on demand
  /// without real time passing.
  RunCoordinator buildWithFakeTimers({
    PreemptionState? preemption,
    int foregroundQueueDepth = 4,
  }) {
    timers = <_FakeTimer>[];
    return RunCoordinator(
      preemption: preemption,
      foregroundQueueDepth: foregroundQueueDepth,
      deadlineTimerFactory: (duration, onExpire) {
        final timer = _FakeTimer(duration, onExpire);
        timers.add(timer);
        return timer;
      },
    );
  }

  group('D.22 invariant 1 — single foreground', () {
    test('at most one foreground body executes at a time, however many are '
        'submitted concurrently', () async {
      final coordinator = RunCoordinator();
      var live = 0;
      var maxLive = 0;
      final gates = List.generate(4, (_) => Completer<int>());
      final order = <int>[];

      // Each body marks itself live on entry, records the peak concurrency, and
      // waits on its own gate before clearing — so if the coordinator ever ran
      // two foreground bodies at once, maxLive would exceed 1.
      Future<int> body(int i) async {
        live++;
        maxLive = maxLive > live ? maxLive : live;
        order.add(i);
        final value = await gates[i].future;
        live--;
        return value;
      }

      final runs = List.generate(
          4, (i) => coordinator.submitForeground<int>(() => body(i)));

      // Only the first body has started; the other three wait in the queue.
      expect(live, 1);
      expect(coordinator.foregroundQueueLength, 3);

      // Drain in submission order; each completion starts exactly the next one.
      for (var i = 0; i < 4; i++) {
        gates[i].complete(i * 10);
        expect(await runs[i], i * 10);
      }

      expect(maxLive, 1, reason: 'foreground bodies never overlap');
      expect(order, <int>[0, 1, 2, 3], reason: 'FIFO submission order');
      expect(coordinator.hasForegroundRun, isFalse);
      expect(coordinator.foregroundQueueLength, 0);
    });
  });

  group('D.22 invariant 2 — single background', () {
    test('at most one background body is live; a second concurrent background '
        'submission is rejected loudly and leaves the running one untouched',
        () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();
      var secondRan = false;

      final first = coordinator.submitBackground<int>(() => gate.future);
      expect(coordinator.hasBackgroundRun, isTrue);

      expect(
        () => coordinator.submitBackground<int>(() async {
          secondRan = true;
          return 0;
        }),
        throwsA(isA<RunSlotBusy>()
            .having((e) => e.slot, 'slot', RunSlot.background)),
      );
      expect(secondRan, isFalse, reason: 'the rejected body never runs');
      expect(coordinator.hasBackgroundRun, isTrue,
          reason: 'the live background run is undisturbed by the rejection');

      gate.complete(1);
      expect(await first, 1);
      expect(coordinator.hasBackgroundRun, isFalse);

      // The slot is reusable once the previous background run finished.
      expect(await coordinator.submitBackground<int>(() async => 2), 2);
    });

    test('a foreground and a background run can be live simultaneously — the '
        'single-slot invariant is per slot, not global', () async {
      final coordinator = RunCoordinator();
      final fgGate = Completer<int>();
      final bgGate = Completer<int>();

      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      expect(coordinator.hasForegroundRun, isTrue);
      expect(coordinator.hasBackgroundRun, isTrue);

      fgGate.complete(1);
      bgGate.complete(2);
      expect(await fg, 1);
      expect(await bg, 2);
    });
  });

  group('D.22 invariant 3 — preemption boundary is the next yield', () {
    test('a live background parks at its NEXT checkpoint when a foreground '
        'arrives (never mid-step) and resumes only when the chain drains',
        () async {
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
        await allowStep1Finish.future; // still mid-step when fg arrives
        steps.add('step1-end');
        await checkpoint.yieldIfForegroundWaiting(); // parks if fg waiting
        steps.add('step2');
        return 'bg-done';
      }

      final bg = coordinator.submitBackground<String>(background);
      await step1Started.future;

      // Two foreground runs arrive while the background is mid-step1.
      final fg1Gate = Completer<int>();
      final fg2Gate = Completer<int>();
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      final fg2 = coordinator.submitForeground<int>(() => fg2Gate.future);
      expect(shared.isForegroundWaiting, isTrue);
      expect(coordinator.foregroundQueueLength, 1);

      // The in-flight step completes; the background then parks at the next
      // checkpoint rather than entering step2.
      allowStep1Finish.complete();
      await pumpEventQueue();
      expect(steps, contains('step1-end'),
          reason: 'the in-flight step finishes — preemption is at the next '
              'checkpoint, never mid-step');
      expect(steps, isNot(contains('step2')),
          reason: 'parked while a foreground is waiting');

      // The first foreground draining is NOT enough — the queued one keeps the
      // background parked.
      fg1Gate.complete(1);
      expect(await fg1, 1);
      await pumpEventQueue();
      expect(steps, isNot(contains('step2')),
          reason: 'a queued foreground keeps the background parked');
      expect(shared.isForegroundWaiting, isTrue);

      // Only when the whole foreground chain drains does the background resume.
      fg2Gate.complete(2);
      expect(await fg2, 2);
      expect(await bg, 'bg-done');
      expect(steps, contains('step2'));
      expect(shared.isForegroundWaiting, isFalse);
    });
  });

  group('D.22 invariant 4 — hard deadline triggers', () {
    test('a hung foreground body is force-yielded with RunDeadlineExceeded and '
        'the slot is freed', () async {
      final coordinator = buildWithFakeTimers();
      final gate = Completer<int>(); // never completes.
      final run = coordinator.submitForeground<int>(() => gate.future);

      expect(coordinator.hasForegroundRun, isTrue);
      timers.single.fire();

      await expectLater(
        run,
        throwsA(isA<RunDeadlineExceeded>()
            .having((e) => e.slot, 'slot', RunSlot.foreground)
            .having((e) => e.failureKind, 'failureKind',
                'procedure.deadline.exceeded')),
      );
      expect(coordinator.hasForegroundRun, isFalse,
          reason: 'the force-yield frees the foreground slot');
    });

    test('a hung background body is force-yielded and the slot is freed',
        () async {
      final coordinator = buildWithFakeTimers();
      final gate = Completer<int>();
      final run = coordinator.submitBackground<int>(() => gate.future);

      expect(coordinator.hasBackgroundRun, isTrue);
      timers.single.fire();

      await expectLater(
        run,
        throwsA(isA<RunDeadlineExceeded>()
            .having((e) => e.slot, 'slot', RunSlot.background)),
      );
      expect(coordinator.hasBackgroundRun, isFalse);
    });
  });

  group('D.22 invariant 5 — queue depth respected', () {
    test('the FIFO queue never exceeds the configured depth; overflow is '
        'rejected with ForegroundQueueFull and the queue is untouched',
        () async {
      const depth = 2;
      final coordinator = RunCoordinator(foregroundQueueDepth: depth);
      final gates = List.generate(3, (_) => Completer<int>());

      // One running + `depth` queued is the most the coordinator holds.
      final r0 = coordinator.submitForeground<int>(() => gates[0].future);
      final r1 = coordinator.submitForeground<int>(() => gates[1].future);
      final r2 = coordinator.submitForeground<int>(() => gates[2].future);
      expect(coordinator.foregroundQueueLength, depth);

      // The next submission overflows; nothing is dropped, the queue is intact.
      var overflowRan = false;
      expect(
        () => coordinator.submitForeground<int>(() async {
          overflowRan = true;
          return -1;
        }),
        throwsA(isA<ForegroundQueueFull>()
            .having((e) => e.depth, 'depth', depth)),
      );
      expect(overflowRan, isFalse);
      expect(coordinator.foregroundQueueLength, depth,
          reason: 'an overflowing submission leaves the queue untouched');

      // Drain everything; the depth bound never gets exceeded along the way.
      for (var i = 0; i < 3; i++) {
        expect(coordinator.foregroundQueueLength, lessThanOrEqualTo(depth));
        gates[i].complete(i);
      }
      expect(await r0, 0);
      expect(await r1, 1);
      expect(await r2, 2);
      expect(coordinator.foregroundQueueLength, 0);
    });
  });

  group('D.22 — all five invariants compose in one end-to-end scenario', () {
    test('a depth-bounded foreground queue preempts a yielding background, '
        'overflow is rejected, and a hung run is force-yielded — all at once',
        () async {
      final shared = PreemptionState();
      final coordinator =
          buildWithFakeTimers(preemption: shared, foregroundQueueDepth: 1);
      final checkpoint = YieldPrimitive(state: shared);

      // Background loop that yields between steps (invariant 3).
      final bgSteps = <int>[];
      final bgStep1Started = Completer<void>();
      final allowBgStep1 = Completer<void>();
      Future<String> background() async {
        for (var step = 1; step <= 2; step++) {
          bgSteps.add(step);
          if (step == 1) {
            bgStep1Started.complete();
            await allowBgStep1.future;
          }
          await checkpoint.yieldIfForegroundWaiting();
        }
        return 'bg-done';
      }

      final bg = coordinator.submitBackground<String>(background);
      await bgStep1Started.future;

      // Invariant 2: a second background is rejected even amid foreground churn.
      expect(() => coordinator.submitBackground<int>(() async => 0),
          throwsA(isA<RunSlotBusy>()));

      // Invariant 1 + 5: one running foreground + one queued (depth 1); a third
      // overflows.
      final fg1Gate = Completer<int>(); // this one will hang and be truncated.
      final fg2Gate = Completer<int>();
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      final fg2 = coordinator.submitForeground<int>(() => fg2Gate.future);
      expect(coordinator.foregroundQueueLength, 1);
      expect(
        () => coordinator.submitForeground<int>(() async => 99),
        throwsA(isA<ForegroundQueueFull>()),
      );

      // Invariant 3: the foreground arrival parked the background.
      expect(shared.isForegroundWaiting, isTrue);
      allowBgStep1.complete();
      await pumpEventQueue();
      expect(bgSteps, <int>[1], reason: 'background parked after step 1');

      // Invariant 4: force-yield the hung running foreground. The queued fg2
      // takes the freed slot (invariant 1 still: one at a time).
      // timers[0] is the background's deadline; timers[1] is fg1's.
      timers[1].fire();
      await expectLater(fg1, throwsA(isA<RunDeadlineExceeded>()));
      expect(coordinator.hasForegroundRun, isTrue,
          reason: 'the queued fg2 occupies the freed slot');
      expect(shared.isForegroundWaiting, isTrue,
          reason: 'fg2 still pending keeps the background parked');

      // Drain the last foreground → chain empty → background resumes (inv. 3).
      fg2Gate.complete(2);
      expect(await fg2, 2);
      expect(await bg, 'bg-done');
      expect(bgSteps, <int>[1, 2]);
      expect(shared.isForegroundWaiting, isFalse);
      expect(coordinator.hasForegroundRun, isFalse);
      expect(coordinator.hasBackgroundRun, isFalse);
    });
  });
}
