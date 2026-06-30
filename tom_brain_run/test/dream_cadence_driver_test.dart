// Todo 10 (G-M3) — the scheduled dream cadence driver.
//
// `memory_specification.md` § 9.7: memory does not drive its own dreaming; the
// agent scripts only ran on demand via `FreeTimeScheduler.triggerMaintenance`.
// The `DreamCadenceDriver` (in `tom_brain_run`) is the missing scheduled driver
// — it groups each cognitive agent into a config-defined named lane (`fast` /
// `slow` / `deep` / `monthly` by default, plus an event-driven shaking lane)
// and fires them when their interval elapses against an injected `Clock`.
//
// These tests pin the *timing* contract in isolation, using a recording fire
// callback and a `MutableTestClock` — no engine, no substrate, no store. That
// the driver needs none of those is itself the G-S2 guarantee for Todo 10: the
// cadence driver introduces no embedding call site (the agents own embedding
// access through the substrate `EmbeddingService` interface, unchanged).
//
// Test ids: DC-1 … DC-12 (timing) + DC-Q1 … DC-Q4 (the serial lane queue,
// dream-redesign part c) + DC-L1 … DC-L3 (config-defined lanes, parts b + e).

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
      DreamThrottle? throttle,
    }) =>
        DreamCadenceDriver(
            clock: clock, fire: fire, schedule: schedule, throttle: throttle);

    // Lane lookup helpers — the schedule is now a list of named lanes.
    Duration interval(CadenceSchedule s, String laneId) =>
        s.laneById(laneId)!.interval;
    List<String> agents(CadenceSchedule s, String laneId) =>
        s.laneById(laneId)!.agents;

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

      clock.advance(interval(schedule, 'fast'));
      final result = await driver.tick();

      expect(result, agents(schedule, 'fast'));
      // No slow / deep / monthly agent leaked into this fast-only tick.
      for (final laneId in const ['slow', 'deep', 'monthly']) {
        for (final id in agents(schedule, laneId)) {
          expect(result, isNot(contains(id)));
        }
      }
    });

    test('DC-3: the slow lane carries the procedure-metrics promotion/demotion '
        'pass (G-PR5) and fires it in lane order', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(interval(schedule, 'slow'));
      final result = await driver.tick();

      // The slow interval is a multiple of the fast interval, so the fast lane
      // is also due — both lanes fire, fast first (DC-6 pins the ordering).
      expect(result, contains('dream_procedure_metrics_v1'));
      expect(
        agents(schedule, 'slow'),
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

      clock.advance(interval(schedule, 'deep'));
      final result = await driver.tick();

      for (final id in agents(schedule, 'deep')) {
        expect(result, contains(id));
      }
    });

    test('DC-5: monthly restructuring is reachable on schedule', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(interval(schedule, 'monthly'));
      final result = await driver.tick();

      expect(result, contains('restructure_tree_v1'));
    });

    test('DC-6: when several lanes are due, the fired order is fast → slow → '
        'deep → monthly', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      // Past the monthly interval, every timed lane is due in the one tick.
      clock.advance(interval(schedule, 'monthly'));
      final result = await driver.tick();

      final expected = <String>[
        ...agents(schedule, 'fast'),
        ...agents(schedule, 'slow'),
        ...agents(schedule, 'deep'),
        ...agents(schedule, 'monthly'),
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
      for (final lane in schedule.lanes) {
        expect(lane.agents, isNot(contains('dream_reconsolidate_v1')));
      }
    });

    test('DC-8: a second tick on the same instant fires nothing — a fired lane '
        'does not re-fire until its interval elapses again', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(interval(schedule, 'fast'));
      await driver.tick();
      fired.clear();

      final second = await driver.tick();
      expect(second, isEmpty);
      expect(fired, isEmpty);

      // After another fast interval the lane is due again.
      clock.advance(interval(schedule, 'fast'));
      final third = await driver.tick();
      expect(third, agents(schedule, 'fast'));
    });

    test('DC-9: a deferred lane (busy background slot) does not advance — it '
        'retries on the next tick', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      // The first fast agent reports the slot busy: the lane defers whole and
      // records no fire, so nothing in the fast lane "ran" this tick.
      deferIds = {'dream_extract_v1'};
      clock.advance(interval(schedule, 'fast'));
      final deferred = await driver.tick();
      expect(deferred, isEmpty);
      expect(fired, isEmpty);

      // Slot free now: the deferred lane was re-enqueued, so the very next tick
      // fires it without waiting another full interval.
      deferIds = <String>{};
      final retried = await driver.tick();
      expect(retried, agents(schedule, 'fast'));
    });

    test('DC-10: the default schedule is the § 9.7 contract — disjoint lanes, '
        'increasing intervals, reconsolidate off-timer', () {
      final schedule = CadenceSchedule.defaults();

      expect(agents(schedule, 'fast'),
          ['dream_extract_v1', 'dream_connect_v1']);
      expect(agents(schedule, 'slow'), [
        'dream_synthesise_v1',
        'dream_procedure_metrics_v1',
        'dream_inquisitor_v1',
        'dream_recentroid_v1',
        'dream_repetition_detect_v1',
      ]);
      expect(agents(schedule, 'deep'),
          ['research_v1', 'dream_prune_v1', 'dream_decay_v1']);
      expect(agents(schedule, 'monthly'), ['restructure_tree_v1']);
      expect(schedule.shakingAgent, 'dream_reconsolidate_v1');

      // No agent appears in two lanes (a write would otherwise run twice).
      final all = <String>[
        for (final lane in schedule.lanes) ...lane.agents,
      ];
      expect(all.toSet().length, all.length, reason: 'lanes must be disjoint');

      // Intervals strictly increase fast < slow < deep < monthly.
      expect(interval(schedule, 'fast').compareTo(interval(schedule, 'slow')),
          lessThan(0));
      expect(interval(schedule, 'slow').compareTo(interval(schedule, 'deep')),
          lessThan(0));
      expect(interval(schedule, 'deep').compareTo(interval(schedule, 'monthly')),
          lessThan(0));
    });

    test('DC-11: HP6 — the driver owns no write path; a tick\'s entire effect is '
        'the scheduled fire() calls, nothing else', () async {
      // The no-overwrite invariant (hard principle 6) is the *agents\'* property:
      // each writes derived records under its registry scope (memory § 9.5) and
      // never overwrites an episodic original. The cadence driver must not be
      // able to weaken that — and structurally it can\'t, because it holds no
      // store and no write path: its only collaborators are a Clock, a fire
      // seam, and a schedule.
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(interval(schedule, 'monthly'));
      final ran = await driver.tick();

      final timedAgents = <String>[
        for (final lane in schedule.lanes) ...lane.agents,
      ];
      expect(ran, timedAgents);
      expect(fired, timedAgents);
      // The Reconsolidator is never on a timed lane — only the event path.
      expect(fired, isNot(contains(schedule.shakingAgent)));
    });

    test('DC-12: the deep lane carries the usage-recalibration decay pass '
        '(dream_decay_v1, § 14) and fires it on the deep interval, after '
        'research/prune, and in no faster lane', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      // The decay pass belongs to the deep lane only — never fast / slow /
      // monthly (a lane it appeared in twice would demote on two cadences).
      expect(agents(schedule, 'deep'), contains('dream_decay_v1'));
      for (final laneId in const ['fast', 'slow', 'monthly']) {
        expect(agents(schedule, laneId), isNot(contains('dream_decay_v1')));
      }

      clock.advance(interval(schedule, 'deep'));
      final result = await driver.tick();

      // It fired this deep tick, through the same fire seam as its lane-mates,
      // and after research/prune (deep-lane fire order).
      expect(result, contains('dream_decay_v1'));
      expect(fired, contains('dream_decay_v1'));
      expect(
        result.indexOf('dream_decay_v1'),
        greaterThan(result.indexOf('dream_prune_v1')),
        reason: 'decay fires after the prune pass in deep-lane order',
      );
    });

    // ── Serial lane queue (dream-redesign part c) ────────────────────────

    test('DC-Q1: lanes run serially, one agent at a time, never interleaved — '
        'across a full sweep no two lanes overlap', () async {
      // Record entry/exit around each fire to prove no two agents are ever
      // mid-flight at once. The driver awaits each fire before the next, so the
      // depth never exceeds 1.
      var depth = 0;
      var maxDepth = 0;
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = DreamCadenceDriver(
        clock: clock,
        schedule: schedule,
        fire: (id) async {
          depth++;
          maxDepth = depth > maxDepth ? depth : maxDepth;
          await Future<void>.delayed(Duration.zero);
          depth--;
          return FireOutcome.fired;
        },
      );

      clock.advance(interval(schedule, 'monthly'));
      await driver.tick();

      expect(maxDepth, 1, reason: 'serial — never two agents in flight at once');
    });

    test('DC-Q2: a due lane already queued (a prior deferred re-enqueue) is not '
        'enqueued twice — it fires once when the slot frees', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      // Tick 1: fast due, but its first agent defers → fast is re-enqueued.
      deferIds = {'dream_extract_v1'};
      clock.advance(interval(schedule, 'fast'));
      expect(await driver.tick(), isEmpty);

      // Tick 2: another fast interval elapses → fast is "due" again, but it is
      // already queued, so it must not be enqueued twice. Slot is free now.
      deferIds = <String>{};
      clock.advance(interval(schedule, 'fast'));
      final ran = await driver.tick();

      // Exactly one run of the fast lane's agents — no duplicate from a
      // double-enqueue.
      expect(ran, agents(schedule, 'fast'));
      expect(fired, agents(schedule, 'fast'));
    });

    test('DC-Q3: a deferred lane goes to the tail; an already-queued later lane '
        'runs first on the next tick', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      // Both fast and slow are due (slow interval is a multiple of fast). The
      // fast lane's first agent defers → fast re-enqueues at the tail and the
      // pump stops, so slow has not run yet this tick.
      deferIds = {'dream_extract_v1'};
      clock.advance(interval(schedule, 'slow'));
      final firstTick = await driver.tick();
      expect(firstTick, isEmpty,
          reason: 'fast deferred at the head; pump stopped before slow ran');

      // Next tick, slot free: tick 1 left the queue as [slow, fast] (fast was
      // re-enqueued at the tail behind the already-queued slow lane). Both run,
      // slow first, then fast.
      deferIds = <String>{};
      final secondTick = await driver.tick();
      expect(
        secondTick,
        <String>[...agents(schedule, 'slow'), ...agents(schedule, 'fast')],
      );
    });

    test('DC-Q4: a deferred lane is never lost — it is paced, not dropped, and '
        'eventually fires every agent exactly once', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule.defaults();
      final driver = driverAt(clock, schedule: schedule);

      deferIds = {'dream_extract_v1'};
      clock.advance(interval(schedule, 'fast'));
      await driver.tick(); // defers
      await driver.tick(); // still busy, still deferred
      expect(fired, isEmpty);

      deferIds = <String>{};
      await driver.tick(); // slot free — the lane finally runs
      expect(fired, agents(schedule, 'fast'));
    });

    // ── Config-defined named lanes (dream-redesign parts b + e) ──────────

    test('DC-L1: a config-defined lane set replaces the defaults wholesale; an '
        'arbitrary lane id fires its agents on its own interval', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule(
        lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
            id: 'nightly',
            interval: Duration(hours: 6),
            agents: <String>['custom_pass_v1'],
          ),
        ],
      );
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(const Duration(hours: 6));
      final ran = await driver.tick();

      expect(ran, ['custom_pass_v1']);
      // None of the default lanes exist in this schedule.
      expect(schedule.laneById('fast'), isNull);
    });

    test('DC-L2: the schedule rejects a malformed lane set at construction', () {
      // Empty lane set.
      expect(() => CadenceSchedule(lanes: const <DreamLaneSpec>[]),
          throwsArgumentError);
      // Duplicate ids.
      expect(
        () => CadenceSchedule(lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
              id: 'x', interval: Duration(minutes: 1), agents: <String>['a']),
          const DreamLaneSpec(
              id: 'x', interval: Duration(minutes: 1), agents: <String>['b']),
        ]),
        throwsArgumentError,
      );
      // Negative interval (a zero interval is legal — external-trigger-only).
      expect(
        () => CadenceSchedule(lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
              id: 'x',
              interval: Duration(seconds: -1),
              agents: <String>['a']),
        ]),
        throwsArgumentError,
      );
      // A zero interval is accepted (external-trigger-only lane).
      expect(
        () => CadenceSchedule(lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
              id: 'x', interval: Duration.zero, agents: <String>['a']),
        ]),
        returnsNormally,
      );
      // Empty agents.
      expect(
        () => CadenceSchedule(lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
              id: 'x', interval: Duration(minutes: 1), agents: <String>[]),
        ]),
        throwsArgumentError,
      );
    });

    test('DC-L3: a lane carries an optional per-lane LLM-call budget for the '
        'dream throttle (part d seam)', () {
      const lane = DreamLaneSpec(
        id: 'fast',
        interval: Duration(minutes: 5),
        agents: <String>['dream_extract_v1'],
        maxLlmCallsPerWindow: 3,
      );
      expect(lane.maxLlmCallsPerWindow, 3);
      // Default schedule lanes carry no per-lane override.
      expect(CadenceSchedule.defaults().laneById('fast')!.maxLlmCallsPerWindow,
          isNull);
    });

    // ── External-trigger-only lanes + maxRepeatCount + manual burst ─────

    test('DC-X1: a zero-interval lane never fires on the scheduled tick, however '
        'much time elapses', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule(lanes: <DreamLaneSpec>[
        const DreamLaneSpec(
            id: 'ondemand', interval: Duration.zero, agents: <String>['a']),
      ]);
      final driver = driverAt(clock, schedule: schedule);

      clock.advance(const Duration(days: 365));
      expect(await driver.tick(), isEmpty);
      expect(fired, isEmpty);
    });

    test('DC-X2: tickManual fires every lane once — including a zero-interval '
        'one — without advancing the schedule baseline or counting', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule(lanes: <DreamLaneSpec>[
        const DreamLaneSpec(
            id: 'fast', interval: Duration(minutes: 5), agents: <String>['f']),
        const DreamLaneSpec(
            id: 'ondemand', interval: Duration.zero, agents: <String>['o']),
      ]);
      final driver = driverAt(clock, schedule: schedule);

      final ran = await driver.tickManual();
      expect(ran, <String>['f', 'o']);
      // Manual bursts never count as scheduled runs.
      expect(driver.scheduledRunCount('fast'), 0);
      expect(driver.scheduledRunCount('ondemand'), 0);
    });

    test('DC-X3: maxRepeatCount caps how many times a lane fires on the '
        'schedule; manual bursts and resets are exempt', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule(lanes: <DreamLaneSpec>[
        const DreamLaneSpec(
            id: 'fast', interval: Duration(minutes: 5), agents: <String>['f']),
      ]);
      final driver = DreamCadenceDriver(
        clock: clock,
        fire: fire,
        schedule: schedule,
        maxRepeatCount: 2,
      );

      // Two scheduled fires are allowed.
      clock.advance(const Duration(minutes: 5));
      expect(await driver.tick(), <String>['f']);
      clock.advance(const Duration(minutes: 5));
      expect(await driver.tick(), <String>['f']);
      expect(driver.scheduledRunCount('fast'), 2);

      // The third is capped — the lane stops auto-firing.
      clock.advance(const Duration(minutes: 5));
      expect(await driver.tick(), isEmpty);

      // A manual burst still fires it (and does not count).
      expect(await driver.tickManual(), <String>['f']);
      expect(driver.scheduledRunCount('fast'), 2);

      // Resetting the counts lets the schedule fire again.
      driver.resetScheduledRunCounts();
      driver.rebaseline();
      clock.advance(const Duration(minutes: 5));
      expect(await driver.tick(), <String>['f']);
      expect(driver.scheduledRunCount('fast'), 1);
    });

    // ── Dream throttle (dream-redesign part d) ──────────────────────────
    //
    // The driver paces LLM-using agents through an injected [DreamThrottle]:
    // an agent fires only after acquiring a token; when the budget is spent
    // the lane defers (re-enqueued, like a busy slot) so the work is paced,
    // not dropped. Embedding-only agents bypass the throttle.

    // A single-lane schedule of three LLM-using agents, used to watch the
    // throttle gate fires within one lane.
    CadenceSchedule threeLlmLane() => CadenceSchedule(
          lanes: <DreamLaneSpec>[
            const DreamLaneSpec(
              id: 'fast',
              interval: Duration(minutes: 5),
              agents: <String>['llm_a_v1', 'llm_b_v1', 'llm_c_v1'],
            ),
          ],
        );

    test('DC-TH1: the throttle caps LLM-using fires per window; the lane '
        'defers once the budget is spent', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = threeLlmLane();
      final throttle = DreamThrottle(
        maxCallsPerWindow: 2,
        window: const Duration(minutes: 30),
      );
      final driver = driverAt(clock, schedule: schedule, throttle: throttle);

      clock.advance(interval(schedule, 'fast'));
      final ran = await driver.tick();

      // Only two of the three agents fit the budget; the third deferred.
      expect(ran, <String>['llm_a_v1', 'llm_b_v1']);
      expect(fired, <String>['llm_a_v1', 'llm_b_v1']);
    });

    test('DC-TH2: an exhausted budget refills as the window passes, and the '
        'deferred lane completes on a later tick', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = threeLlmLane();
      final throttle = DreamThrottle(
        maxCallsPerWindow: 2,
        window: const Duration(minutes: 30),
      );
      final driver = driverAt(clock, schedule: schedule, throttle: throttle);

      clock.advance(interval(schedule, 'fast'));
      final firstRan = await driver.tick(); // fires a + b, defers at c
      expect(firstRan, <String>['llm_a_v1', 'llm_b_v1']);

      // The window passes: the two tokens age out, budget is free again.
      clock.advance(const Duration(minutes: 30));
      final ran = await driver.tick();

      // The lane resumes from where it deferred — only the remaining agent runs
      // (no re-fire, no double-charge), so across both ticks each agent ran once.
      expect(ran, <String>['llm_c_v1']);
      expect(fired, <String>['llm_a_v1', 'llm_b_v1', 'llm_c_v1']);
    });

    test('DC-TH3: embedding-only agents bypass the throttle entirely', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      // A lane mixing an embedding-only agent with an LLM-using one.
      final schedule = CadenceSchedule(
        lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
            id: 'fast',
            interval: Duration(minutes: 5),
            agents: <String>['dream_recentroid_v1', 'llm_a_v1'],
          ),
        ],
      );
      // A zero-room-after-one budget: only one LLM-using fire is allowed.
      final throttle = DreamThrottle(
        maxCallsPerWindow: 1,
        window: const Duration(minutes: 30),
      );
      final driver = driverAt(clock, schedule: schedule, throttle: throttle);

      clock.advance(interval(schedule, 'fast'));
      final ran = await driver.tick();

      // The embedding-only agent ran without spending budget; the lone LLM
      // token then admitted the LLM-using agent.
      expect(ran, <String>['dream_recentroid_v1', 'llm_a_v1']);
    });

    test('DC-TH4: a per-lane cap bounds one lane below the global budget',
        () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = CadenceSchedule(
        lanes: <DreamLaneSpec>[
          const DreamLaneSpec(
            id: 'noisy',
            interval: Duration(minutes: 5),
            agents: <String>['llm_a_v1', 'llm_b_v1'],
            maxLlmCallsPerWindow: 1,
          ),
        ],
      );
      final throttle = DreamThrottle(
        maxCallsPerWindow: 100,
        window: const Duration(minutes: 30),
        perLaneMaxCallsPerWindow: <String, int>{'noisy': 1},
      );
      final driver = driverAt(clock, schedule: schedule, throttle: throttle);

      clock.advance(interval(schedule, 'noisy'));
      final ran = await driver.tick();

      // Despite a generous global budget, the lane's own cap admits just one.
      expect(ran, <String>['llm_a_v1']);
    });

    test('DC-TH5: a null throttle leaves the cadence unthrottled', () async {
      final clock = MutableTestClock(BrainTime.fromMs(0));
      final schedule = threeLlmLane();
      final driver = driverAt(clock, schedule: schedule); // no throttle

      clock.advance(interval(schedule, 'fast'));
      final ran = await driver.tick();

      expect(ran, <String>['llm_a_v1', 'llm_b_v1', 'llm_c_v1']);
    });
  });
}
