// DreamController (items b + c) — the mode machine that gates the dream loop.
//
// The controller owns a `DreamCadenceLoop` and decides, each heartbeat, whether
// dreaming may fire right now. That decision is the product of two things:
//
//   * the configured daily windows (`DreamWindowSchedule`) — item b; and
//   * a runtime mode the control tool can drive (item c): `scheduled` follows
//     the windows, `forced` dreams regardless until a deadline, `suspended`
//     never dreams.
//
// These tests drive a mutable local-time source so the window + deadline
// arithmetic is deterministic, and a recording fire seam so we can prove the
// gate actually suppresses / admits the underlying cadence.

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock;
import 'package:test/test.dart';

void main() {
  // A mutable local wall-clock the controller reads windows + deadlines against.
  late DateTime localNow;
  DateTime now() => localNow;

  /// Builds a controller over [schedule] with a perpetually-due fast lane, so
  /// only the controller's gate decides whether the lane fires. [fired] records
  /// each agent the cadence runs.
  DreamController buildController(
    DreamWindowSchedule schedule,
    List<String> fired,
  ) {
    final cadenceClock = MutableTestClock(BrainTime.fromMs(0));
    final cadence = CadenceSchedule.defaults();
    final driver = DreamCadenceDriver(
      clock: cadenceClock,
      schedule: cadence,
      fire: (id) async {
        fired.add(id);
        return FireOutcome.fired;
      },
    );
    // Keep the fast lane perpetually due.
    cadenceClock.advance(cadence.intervals[DreamLane.fast]!);
    return DreamController(
      driver: driver,
      schedule: schedule,
      now: now,
      heartbeat: const Duration(milliseconds: 5),
    );
  }

  setUp(() {
    localNow = DateTime(2026, 6, 10, 3, 0); // 03:00 — inside the night window
  });

  group('DreamController.isDreamingActive — scheduled mode (item b)', () {
    test('active inside a configured window, idle outside', () {
      final schedule = DreamWindowSchedule.parseSlots(<Map<String, String>>[
        <String, String>{'start': '02:00', 'end': '05:00'},
      ]);
      final controller = buildController(schedule, <String>[]);
      addTearDown(controller.stop);

      localNow = DateTime(2026, 6, 10, 3, 0);
      expect(controller.isDreamingActive(), isTrue);
      localNow = DateTime(2026, 6, 10, 8, 0);
      expect(controller.isDreamingActive(), isFalse);
    });

    test('an empty schedule is always active', () {
      final controller =
          buildController(DreamWindowSchedule(windows: <DreamWindow>[]), <String>[]);
      addTearDown(controller.stop);
      localNow = DateTime(2026, 6, 10, 15, 0);
      expect(controller.isDreamingActive(), isTrue);
    });
  });

  group('DreamController control actions (item c)', () {
    late DreamController controller;
    setUp(() {
      // A daytime-only window so "scheduled" is idle at the 22:00 test instant.
      final schedule = DreamWindowSchedule.parseSlots(<Map<String, String>>[
        <String, String>{'start': '02:00', 'end': '05:00'},
      ]);
      controller = buildController(schedule, <String>[]);
      localNow = DateTime(2026, 6, 10, 22, 0); // outside the window
      addTearDown(() => controller.stop());
    });

    test('forceFor dreams regardless of the window until the deadline expires',
        () {
      expect(controller.isDreamingActive(), isFalse); // scheduled, outside window

      controller.forceFor(const Duration(minutes: 30));
      expect(controller.status().mode, DreamModeKind.forced);
      expect(controller.isDreamingActive(), isTrue); // forced overrides window

      // 29 minutes later: still forced.
      localNow = localNow.add(const Duration(minutes: 29));
      expect(controller.isDreamingActive(), isTrue);

      // Past the deadline: auto-revert to scheduled (still outside the window).
      localNow = localNow.add(const Duration(minutes: 2));
      expect(controller.isDreamingActive(), isFalse);
      expect(controller.status().mode, DreamModeKind.scheduled);
    });

    test('suspend stops dreaming even inside a window', () {
      localNow = DateTime(2026, 6, 10, 3, 0); // inside the window
      expect(controller.isDreamingActive(), isTrue);
      controller.suspend();
      expect(controller.status().mode, DreamModeKind.suspended);
      expect(controller.isDreamingActive(), isFalse);
    });

    test('resume returns to following the configured schedule', () {
      controller.suspend();
      expect(controller.isDreamingActive(), isFalse);
      controller.resume();
      expect(controller.status().mode, DreamModeKind.scheduled);
      localNow = DateTime(2026, 6, 10, 3, 0); // inside the window
      expect(controller.isDreamingActive(), isTrue);
    });

    test('status reports mode, activity, and the forced deadline', () {
      controller.forceFor(const Duration(hours: 1));
      final status = controller.status();
      expect(status.mode, DreamModeKind.forced);
      expect(status.active, isTrue);
      expect(status.forcedUntil, isNotNull);
      expect(status.forcedUntil!.isAfter(localNow), isTrue);
    });
  });

  group('DreamController loop lifecycle', () {
    test('the gated loop fires only while active, and stop halts it', () async {
      final fired = <String>[];
      final schedule = DreamWindowSchedule.parseSlots(<Map<String, String>>[
        <String, String>{'start': '02:00', 'end': '05:00'},
      ]);
      final controller = buildController(schedule, fired);

      // Outside the window: the running loop fires nothing.
      localNow = DateTime(2026, 6, 10, 12, 0);
      controller.start();
      expect(controller.isRunning, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(fired, isEmpty);

      // Move into the window: the loop now fires the due fast lane.
      localNow = DateTime(2026, 6, 10, 3, 0);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(fired, isNotEmpty);

      await controller.stop();
      expect(controller.isRunning, isFalse);
    });
  });
}
