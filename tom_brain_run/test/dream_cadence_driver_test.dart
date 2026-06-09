// Todo 10 (G-M3) — the scheduled dream cadence driver.
//
// `memory_specification.md` § 9.7: memory does not drive its own dreaming; the
// agent scripts only ran on demand via `FreeTimeScheduler.triggerMaintenance`.
// The `DreamCadenceDriver` (in `tom_brain_run`) is the missing scheduled driver
// — it maps each cognitive agent to a fast / slow / deep / monthly lane (plus an
// event-driven shaking lane) and fires them when their interval elapses against
// an injected `Clock`.
//
// These tests pin the *timing* contract in isolation, using a recording fire
// callback and a `MutableTestClock` — no engine, no substrate, no store. That
// the driver needs none of those is itself the G-S2 guarantee for Todo 10: the
// cadence driver introduces no embedding call site (the agents own embedding
// access through the substrate `EmbeddingService` interface, unchanged).
//
// Test ids: DC-1 … DC-9.

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainTime, MutableTestClock;

void main() {
  group('DreamCadenceDriver', () {
    // A recording fire seam: every fired procedure id is appended in order, and
    // each call reports `fired` unless the id is in `deferIds` (which models a
    // busy background slot — `RunSlotBusy` — that the production adapter maps to
    // `FireOutcome.deferred`).
    late List<String> fired;
    late Set<String> deferIds;
    Future<FireOutcome> fire(String procedureId) async {
      if (deferIds.contains(procedureId)) {
        return FireOutcome.deferred;
      }
      fired.add(procedureId);
      return FireOutcome.fired;
    }

    setUp(() {
      fired = <String>[];
      deferIds = <String>{};
    });

    DreamCadenceDriver driverAt(
      MutableTestClock clock, {
      CadenceSchedule? schedule,
    }) =>
        DreamCadenceDriver(clock: clock, fire: fire, schedule: schedule);

    test('DC-1: no lane is due on the construction instant — first tick fires '
        'nothing', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final driver = driverAt(clock);

      final result = await driver.tick();

      expect(result, isEmpty);
      expect(fired, isEmpty);
    });

    test('DC-2: the fast lane fires exactly its agents once its interval has '
        'elapsed; slower lanes stay silent', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(schedule.intervals[DreamLane.fast]!);
      final result = await driver.tick();

      expect(result, schedule.agents[DreamLane.fast]);
      // No slow / deep / monthly agent leaked into this fast-only tick.
      for (final lane in const [
        DreamLane.slow,
        DreamLane.deep,
        DreamLane.monthly,
      ]) {
        for (final id in schedule.agents[lane]!) {
          expect(result, isNot(contains(id)));
        }
      }
    });

    test('DC-3: the slow lane carries the procedure-metrics promotion/demotion '
        'pass (G-PR5) and fires it in lane order', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(schedule.intervals[DreamLane.slow]!);
      final result = await driver.tick();

      // The slow interval is a multiple of the fast interval, so the fast lane
      // is also due — both lanes fire, fast first (DC-6 pins the ordering).
      expect(result, contains('dream_procedure_metrics_v1'));
      expect(
        schedule.agents[DreamLane.slow],
        contains('dream_procedure_metrics_v1'),
        reason: 'procedure promotion/demotion folds into the slow (Synthesiser) '
            'lane, not its own lane',
      );
    });

    test('DC-4: the deep lane fires the expensive agents once its interval has '
        'elapsed', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(schedule.intervals[DreamLane.deep]!);
      final result = await driver.tick();

      for (final id in schedule.agents[DreamLane.deep]!) {
        expect(result, contains(id));
      }
    });

    test('DC-5: monthly restructuring is reachable on schedule', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(schedule.intervals[DreamLane.monthly]!);
      final result = await driver.tick();

      expect(result, contains('restructure_tree_v1'));
    });

    test('DC-6: when several lanes are due, the fired order is fast → slow → '
        'deep → monthly', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      // Past the monthly interval, every timed lane is due in the one tick.
      clock.advance(schedule.intervals[DreamLane.monthly]!);
      final result = await driver.tick();

      final expected = <String>[
        ...schedule.agents[DreamLane.fast]!,
        ...schedule.agents[DreamLane.slow]!,
        ...schedule.agents[DreamLane.deep]!,
        ...schedule.agents[DreamLane.monthly]!,
      ];
      expect(result, expected);
    });

    test('DC-7: shaking-event reconsolidation is reachable off the timer and is '
        'in no timed lane', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      await driver.handleShakingEvent();

      expect(fired, ['dream_reconsolidate_v1']);
      for (final lane in DreamLane.values) {
        expect(schedule.agents[lane], isNot(contains('dream_reconsolidate_v1')));
      }
    });

    test('DC-8: a second tick on the same instant fires nothing — a fired lane '
        'does not re-fire until its interval elapses again', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(schedule.intervals[DreamLane.fast]!);
      await driver.tick();
      fired.clear();

      final second = await driver.tick();
      expect(second, isEmpty);
      expect(fired, isEmpty);

      // After another fast interval the lane is due again.
      clock.advance(schedule.intervals[DreamLane.fast]!);
      final third = await driver.tick();
      expect(third, schedule.agents[DreamLane.fast]);
    });

    test('DC-9: a deferred lane (busy background slot) does not advance — it '
        'retries on the next tick', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      // The first fast agent reports the slot busy: the lane defers whole and
      // records no fire, so nothing in the fast lane "ran" this tick.
      deferIds = {'dream_extract_v1'};
      clock.advance(schedule.intervals[DreamLane.fast]!);
      final deferred = await driver.tick();
      expect(deferred, isEmpty);
      expect(fired, isEmpty);

      // Slot free now: the same elapsed interval still counts — the lane fires
      // on the very next tick without waiting another full interval.
      deferIds = <String>{};
      final retried = await driver.tick();
      expect(retried, schedule.agents[DreamLane.fast]);
    });

    test('DC-10: the default schedule is the § 9.7 contract — disjoint lanes, '
        'increasing intervals, reconsolidate off-timer', () {
      final schedule = CadenceSchedule.defaults();

      expect(schedule.agents[DreamLane.fast],
          ['dream_extract_v1', 'dream_connect_v1']);
      expect(schedule.agents[DreamLane.slow], [
        'dream_synthesise_v1',
        'dream_procedure_metrics_v1',
        'dream_inquisitor_v1',
        'dream_recentroid_v1',
        'dream_repetition_detect_v1',
      ]);
      expect(schedule.agents[DreamLane.deep], ['research_v1', 'dream_prune_v1']);
      expect(schedule.agents[DreamLane.monthly], ['restructure_tree_v1']);
      expect(schedule.shakingAgent, 'dream_reconsolidate_v1');

      // No agent appears in two lanes (a write would otherwise run twice).
      final all = <String>[
        for (final lane in DreamLane.values) ...schedule.agents[lane]!,
      ];
      expect(all.toSet().length, all.length, reason: 'lanes must be disjoint');

      // Intervals strictly increase fast < slow < deep < monthly.
      expect(
        schedule.intervals[DreamLane.fast]!.compareTo(
          schedule.intervals[DreamLane.slow]!,
        ),
        lessThan(0),
      );
      expect(
        schedule.intervals[DreamLane.slow]!.compareTo(
          schedule.intervals[DreamLane.deep]!,
        ),
        lessThan(0),
      );
      expect(
        schedule.intervals[DreamLane.deep]!.compareTo(
          schedule.intervals[DreamLane.monthly]!,
        ),
        lessThan(0),
      );
    });
  });
}
