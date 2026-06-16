// Todo 10 (G-M3) — the wall-clock heartbeat that pumps the cadence driver.
//
// `DreamCadenceLoop` is the production heartbeat: a `Timer.periodic` that calls
// `driver.tick()`. These tests use a real (short) heartbeat and a recording
// fire seam to pin: the loop fires a due lane, the re-entrancy guard prevents
// overlap, `start`/`stop` are idempotent, and a tick failure does not kill the
// heartbeat.
//
// Test ids: DL-1 … DL-4.

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock;

void main() {
  group('DreamCadenceLoop', () {
    test('DL-1: a running loop fires a due lane on its next beat', () async {
      final fired = <String>[];
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = DreamCadenceDriver(
        clock: clock,
        schedule: schedule,
        fire: (id) async {
          fired.add(id);
          return FireOutcome.fired;
        },
      );
      // Past the fast interval, so the very next pump fires the fast lane.
      clock.advance(schedule.laneById('fast')!.interval);

      final loop = DreamCadenceLoop(
        driver: driver,
        heartbeat: const Duration(milliseconds: 5),
      );
      loop.start();
      addTearDown(loop.stop);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      await loop.stop();

      expect(fired, containsAll(schedule.laneById('fast')!.agents));
    });

    test('DL-2: start is idempotent and stop halts the heartbeat', () async {
      var ticks = 0;
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      // Each fast-lane fire bumps the counter; advance keeps the lane due.
      final driver = DreamCadenceDriver(
        clock: clock,
        schedule: schedule,
        fire: (id) async {
          if (id == schedule.laneById('fast')!.agents.first) {
            ticks++;
            clock.advance(schedule.laneById('fast')!.interval);
          }
          return FireOutcome.fired;
        },
      );
      clock.advance(schedule.laneById('fast')!.interval);

      final loop = DreamCadenceLoop(
        driver: driver,
        heartbeat: const Duration(milliseconds: 5),
      );
      loop.start();
      loop.start(); // second start is a no-op, not a second timer
      expect(loop.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      await loop.stop();
      expect(loop.isRunning, isFalse);

      final afterStop = ticks;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ticks, afterStop, reason: 'no beats fire after stop');
    });

    test('DL-3: a tick error is reported and does not kill the heartbeat',
        () async {
      final errors = <Object>[];
      var attempts = 0;
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = DreamCadenceDriver(
        clock: clock,
        schedule: schedule,
        fire: (id) async {
          // Keep the fast lane perpetually due so every beat attempts a fire.
          if (id == schedule.laneById('fast')!.agents.first) {
            attempts++;
            clock.advance(schedule.laneById('fast')!.interval);
            throw StateError('boom');
          }
          return FireOutcome.fired;
        },
      );
      clock.advance(schedule.laneById('fast')!.interval);

      final loop = DreamCadenceLoop(
        driver: driver,
        heartbeat: const Duration(milliseconds: 5),
        onTickError: (e, _) => errors.add(e),
      );
      loop.start();
      addTearDown(loop.stop);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      await loop.stop();

      expect(errors, isNotEmpty);
      expect(errors.first, isA<StateError>());
      // The heartbeat survived the first failure and tried again.
      expect(attempts, greaterThan(1));
    });

    test('DL-5: a closed shouldTick gate skips the pump (item b window gate)',
        () async {
      final fired = <String>[];
      var gateOpen = false;
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = DreamCadenceDriver(
        clock: clock,
        schedule: schedule,
        fire: (id) async {
          fired.add(id);
          return FireOutcome.fired;
        },
      );
      // The fast lane is perpetually due, so only the gate decides whether it
      // fires.
      clock.advance(schedule.laneById('fast')!.interval);

      final loop = DreamCadenceLoop(
        driver: driver,
        heartbeat: const Duration(milliseconds: 5),
        shouldTick: () => gateOpen,
      );
      loop.start();
      addTearDown(loop.stop);

      // Gate closed: no fire despite the due lane.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(fired, isEmpty, reason: 'a closed gate suppresses every beat');

      // Open the gate: the next beat fires the due lane.
      gateOpen = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await loop.stop();
      expect(fired, containsAll(schedule.laneById('fast')!.agents));
    });

    test('DL-4: stop before start is a harmless no-op', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final driver = DreamCadenceDriver(
        clock: clock,
        fire: (_) async => FireOutcome.fired,
      );
      final loop = DreamCadenceLoop(driver: driver);
      expect(loop.isRunning, isFalse);
      await loop.stop();
      expect(loop.isRunning, isFalse);
    });
  });
}
