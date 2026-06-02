// Coordinator-level hard step deadline cross-check tests (Plan step D.21;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5, § 14;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// D.18–D.20 built the coordinator core, the FIFO foreground queue, and the
// cooperative-preemption driving. D.21 adds an *independent* hard step
// deadline at the coordinator level that cross-checks the engine's own
// per-step `StepDeadline` (C.36): every admitted run body — foreground or
// background — is raced against a coordinator-owned deadline using the same
// mechanism. The two deadlines are defence-in-depth:
//
//   - Normal path: the engine's deadline fires *inside* the run body and
//     closes the run cleanly; from the coordinator's vantage the body simply
//     completes, so the coordinator's timer is cancelled and never fires.
//   - Backstop path: the coordinator's deadline fires only when the body does
//     *not* complete in time (the engine failed to bound the run). The
//     coordinator then force-yields — frees the slot, pumps the queue /
//     resumes the background — and surfaces `RunDeadlineExceeded`
//     (`procedure.deadline.exceeded`).
//
// These tests drive the coordinator deadline off real wall-clock time via an
// injected `_FakeTimer`, exactly as the C.36 `StepDeadline` tests do, so the
// truncation is deterministic and instantaneous.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        RunCoordinator,
        RunDeadlineExceeded,
        RunSlot,
        defaultCoordinatorDeadlineGrace,
        defaultStepDeadline;
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

/// A `Timer` test double: records the scheduled [callback] and [duration],
/// tracks cancellation, and fires only when the test calls [fire]. Lets the
/// coordinator's per-run `StepDeadline` be driven deterministically.
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
  void cancel() {
    _active = false;
  }

  /// Fires the scheduled callback as the real timer would on expiry.
  void fire() {
    _ticks++;
    _active = false;
    callback();
  }
}

void main() {
  // Captures every per-run `StepDeadline` timer the coordinator schedules, in
  // creation order, so a test can fire (or inspect) the deadline of a specific
  // run.
  late List<_FakeTimer> timers;

  RunCoordinator build({
    PreemptionState? preemption,
    Duration? hardStepDeadline,
    int foregroundQueueDepth = 4,
  }) {
    timers = <_FakeTimer>[];
    return RunCoordinator(
      preemption: preemption,
      hardStepDeadline: hardStepDeadline,
      foregroundQueueDepth: foregroundQueueDepth,
      deadlineTimerFactory: (duration, onExpire) {
        final timer = _FakeTimer(duration, onExpire);
        timers.add(timer);
        return timer;
      },
    );
  }

  group('D.21 RunCoordinator — hard step deadline construction', () {
    test('defaults to the engine per-step deadline plus the grace margin', () {
      expect(defaultCoordinatorDeadlineGrace, const Duration(seconds: 5));
      expect(
        RunCoordinator().hardStepDeadline,
        defaultStepDeadline + defaultCoordinatorDeadlineGrace,
      );
    });

    test('honours an explicit hard step deadline', () {
      final coordinator =
          RunCoordinator(hardStepDeadline: const Duration(milliseconds: 250));
      expect(coordinator.hardStepDeadline, const Duration(milliseconds: 250));
    });

    test('rejects a zero or negative hard step deadline', () {
      expect(
        () => RunCoordinator(hardStepDeadline: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => RunCoordinator(hardStepDeadline: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    test('arms a deadline timer for the configured limit when a run starts',
        () {
      final coordinator = build(hardStepDeadline: const Duration(seconds: 30));
      final gate = Completer<int>();
      // ignore: unawaited_futures
      coordinator.submitForeground<int>(() => gate.future);

      expect(timers.single.duration, const Duration(seconds: 30));
      expect(timers.single.isActive, isTrue);

      gate.complete(0); // clean up the hanging body.
    });
  });

  group('D.21 RunCoordinator — passive cross-check (engine/body wins)', () {
    test('a foreground body that completes in time returns its value and the '
        'deadline timer is cancelled, never fired', () async {
      final coordinator = build();
      final value = await coordinator.submitForeground<int>(() async => 42);

      expect(value, 42);
      expect(coordinator.hasForegroundRun, isFalse);
      expect(timers.single.isActive, isFalse,
          reason: 'the cross-check timer is disarmed once the body completes');
      expect(timers.single.tick, 0, reason: 'the deadline never fired');
    });

    test('a background body that completes in time returns its value and the '
        'deadline timer is cancelled', () async {
      final coordinator = build();
      final value = await coordinator.submitBackground<int>(() async => 7);

      expect(value, 7);
      expect(coordinator.hasBackgroundRun, isFalse);
      expect(timers.single.isActive, isFalse);
      expect(timers.single.tick, 0);
    });

    test('a body that throws before the deadline propagates its own error, '
        'not RunDeadlineExceeded, and disarms the timer', () async {
      final coordinator = build();

      await expectLater(
        coordinator.submitForeground<int>(
            () async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(coordinator.hasForegroundRun, isFalse);
      expect(timers.single.isActive, isFalse);
      expect(timers.single.tick, 0);
    });
  });

  group('D.21 RunCoordinator — backstop (coordinator deadline force-yields)',
      () {
    test('a hung foreground body is force-yielded with RunDeadlineExceeded and '
        'the slot is freed', () async {
      final coordinator = build(hardStepDeadline: const Duration(seconds: 12));
      final gate = Completer<int>(); // never completes — a hung body.
      final run = coordinator.submitForeground<int>(() => gate.future);

      expect(coordinator.hasForegroundRun, isTrue);
      timers.single.fire();

      await expectLater(
        run,
        throwsA(
          isA<RunDeadlineExceeded>()
              .having((e) => e.slot, 'slot', RunSlot.foreground)
              .having((e) => e.limit, 'limit', const Duration(seconds: 12))
              .having((e) => e.failureKind, 'failureKind',
                  'procedure.deadline.exceeded'),
        ),
      );
      expect(coordinator.hasForegroundRun, isFalse,
          reason: 'the force-yield frees the foreground slot');
    });

    test('a hung background body is force-yielded with RunDeadlineExceeded and '
        'the slot is freed', () async {
      final coordinator = build();
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

    test('RunDeadlineExceeded.toString names the slot and the limit', () {
      const error = RunDeadlineExceeded(RunSlot.foreground, Duration(seconds: 9));
      expect(error.toString(), contains('RunDeadlineExceeded'));
      expect(error.toString(), contains('foreground'));
      expect(error.toString(), contains('9000 ms'));
    });
  });

  group('D.21 RunCoordinator — force-yield interacts with queue + preemption',
      () {
    test('a truncated foreground frees the slot so the next queued foreground '
        'runs', () async {
      final coordinator = build();
      final gate1 = Completer<int>(); // first run hangs.
      final f1 = coordinator.submitForeground<int>(() => gate1.future);

      var secondRan = false;
      final f2 = coordinator.submitForeground<int>(() async {
        secondRan = true;
        return 7;
      });
      expect(coordinator.foregroundQueueLength, 1);

      timers.first.fire(); // truncate the running foreground.

      await expectLater(f1, throwsA(isA<RunDeadlineExceeded>()));
      expect(await f2, 7,
          reason: 'the queued foreground starts once the slot frees');
      expect(secondRan, isTrue);
      expect(coordinator.hasForegroundRun, isFalse);
      expect(coordinator.foregroundQueueLength, 0);
    });

    test('a truncated foreground drains the chain and resumes a preempted '
        'background', () async {
      final shared = PreemptionState();
      final coordinator = build(preemption: shared);

      final bgGate = Completer<int>();
      final bg = coordinator.submitBackground<int>(() => bgGate.future);

      final fgGate = Completer<int>(); // foreground hangs.
      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      expect(shared.isForegroundWaiting, isTrue,
          reason: 'a foreground admitted over a live background requests '
              'preemption');

      // The foreground deadline fires (timers[1] — background is timers[0]).
      timers[1].fire();
      await expectLater(fg, throwsA(isA<RunDeadlineExceeded>()));
      expect(shared.isForegroundWaiting, isFalse,
          reason: 'draining the foreground resumes the parked background');

      // Clean up the still-live background body.
      bgGate.complete(1);
      expect(await bg, 1);
    });
  });
}
