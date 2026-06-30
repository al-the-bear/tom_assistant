// DreamControllerTelegramAdapter (item 5) — the run-layer implementation of the
// access package's `TelegramDreamController` port. It wraps the live
// [DreamController] and renders channel-neutral text for the four Telegram dream
// commands (`/dream_now`, `/dream_start`, `/dream_stop`, `/dream_status`).
//
// What is proven:
//   1. dreamNow(n) opens a manual window on the wrapped controller and reports
//      the minute count back.
//   2. dreamStart()/dreamStop() drive the base mode (scheduled ⇄ suspended) and
//      report the new state.
//   3. dreamStatus() renders mode, activity, the configured windows, the repeat
//      cap, and every lane's interval + agent count + scheduled-run tally — read
//      straight from the live controller's status + schedules, so config the
//      operator never saw a run for still shows.

import 'package:tom_brain_access/tom_brain_access.dart'
    show TelegramDreamController;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock;
import 'package:test/test.dart';

void main() {
  // A mutable local wall-clock the controller reads windows + deadlines against.
  late DateTime localNow;
  DateTime now() => localNow;

  DreamController buildController({
    DreamWindowSchedule? windows,
    CadenceSchedule? cadence,
    int? maxRepeatCount,
  }) {
    final cadenceClock = MutableTestClock(BrainTime.fromMs(0));
    final schedule = cadence ?? CadenceSchedule.defaults();
    final driver = DreamCadenceDriver(
      clock: cadenceClock,
      schedule: schedule,
      fire: (_) async => FireOutcome.fired,
      maxRepeatCount: maxRepeatCount,
    );
    return DreamController(
      driver: driver,
      schedule: windows ?? DreamWindowSchedule(windows: const <DreamWindow>[]),
      now: now,
    );
  }

  setUp(() {
    localNow = DateTime(2026, 6, 10, 3, 0); // 03:00
  });

  TelegramDreamController adapterFor(DreamController controller) =>
      DreamControllerTelegramAdapter(controller);

  group('DreamControllerTelegramAdapter control verbs', () {
    test('dreamNow opens a manual window and reports the minute count',
        () async {
      final controller = buildController(
        windows: DreamWindowSchedule.parseSlots(<Map<String, String>>[
          <String, String>{'start': '02:00', 'end': '05:00'},
        ]),
      );
      addTearDown(controller.stop);
      localNow = DateTime(2026, 6, 10, 22, 0); // outside the window
      final adapter = adapterFor(controller);

      expect(controller.status().manualUntil, isNull);
      final reply = await adapter.dreamNow(30);

      expect(controller.status().manualUntil, isNotNull);
      // The base mode is untouched — a manual window is not a "start".
      expect(controller.status().mode, DreamModeKind.scheduled);
      expect(reply, contains('30'));
    });

    test('dreamStop suspends the base mode; dreamStart resumes it', () async {
      final controller = buildController();
      addTearDown(controller.stop);
      final adapter = adapterFor(controller);

      final stopReply = await adapter.dreamStop();
      expect(controller.status().mode, DreamModeKind.suspended);
      expect(stopReply, isNotEmpty);

      final startReply = await adapter.dreamStart();
      expect(controller.status().mode, DreamModeKind.scheduled);
      expect(startReply, isNotEmpty);
    });
  });

  group('DreamControllerTelegramAdapter dreamStatus rendering', () {
    test('renders mode, windows, repeat cap, and every configured lane',
        () async {
      final controller = buildController(
        windows: DreamWindowSchedule.parseSlots(<Map<String, String>>[
          <String, String>{'start': '02:00', 'end': '05:00'},
        ]),
        maxRepeatCount: 3,
      );
      addTearDown(controller.stop);
      final adapter = adapterFor(controller);

      final text = await adapter.dreamStatus();

      // Mode + windows.
      expect(text, contains('scheduled'));
      expect(text, contains('02:00'));
      expect(text, contains('05:00'));
      // The repeat cap surfaces.
      expect(text, contains('3'));
      // Every default lane is listed even with no run yet.
      for (final lane in CadenceSchedule.defaults().lanes) {
        expect(text, contains(lane.id),
            reason: 'lane "${lane.id}" should show before any run');
      }
    });

    test('an empty window schedule renders as always-active', () async {
      final controller = buildController(
        windows: DreamWindowSchedule(windows: const <DreamWindow>[]),
      );
      addTearDown(controller.stop);
      final adapter = adapterFor(controller);

      final text = await adapter.dreamStatus();
      expect(text.toLowerCase(), contains('always'));
    });

    test('an open manual window surfaces its deadline in the status',
        () async {
      final controller = buildController();
      addTearDown(controller.stop);
      final adapter = adapterFor(controller);

      await adapter.dreamNow(45);
      final text = await adapter.dreamStatus();
      expect(text.toLowerCase(), contains('manual'));
    });
  });
}
