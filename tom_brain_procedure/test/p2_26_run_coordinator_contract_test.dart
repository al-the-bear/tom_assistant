// P2.26 — the dispatcher's *runtime contract* as one consolidated attestation.
//
// prototype_implementation_plan_2.md #26:
//   "Procedure dispatcher: verify RunCoordinator. One foreground + one
//    background run, FIFO foreground queue (depth 4), preemption, 60 s step
//    deadline, and the `FallbackExecutor` stepping only on the four typed
//    failures. Test: preemption, queue-overflow rejection, deadline abort,
//    fallback-only-on-typed-failure. Verify: a long background agent yields to
//    a foreground prompt."
//
// ── Why this is not d18–d21 / d29–d32 again ─────────────────────────────────
//
// Each branch is already proven in isolation: d18 pins the single-foreground /
// single-background slot invariant, d19 the FIFO foreground queue, d20 the
// cooperative-preemption driving, d21 the coordinator hard step deadline, and
// d29 the `FallbackExecutor` chain-walk policy. #26 is the *confirmation* step
// — like d42 (consolidated body), d50/d51 (closed-set attestation), and P2.25
// (reduced selection contract): it asserts those branches compose into the one
// runtime contract the prototype actually ships, as a single table, driving the
// real production surfaces (`RunCoordinator`, `YieldPrimitive`,
// `FallbackExecutor`, `defaultFallbackClassifier`) directly.
//
// The contract has five facts the plan calls out by name:
//
//   1. Slots — exactly one foreground + one background run live at once; a
//      second concurrent background is rejected loudly (`RunSlotBusy`).
//   2. Queue — the foreground slot fronts a FIFO queue of default depth 4; a
//      submission past a full queue overflows (`ForegroundQueueFull(4)`).
//   3. Preemption — a foreground arrival over a live background drives the
//      shared `PreemptionState`; a real `YieldPrimitive` background loop parks
//      at its next checkpoint and resumes once the foreground drains (the
//      plan's Verify: a long background agent yields to a foreground prompt).
//   4. Deadline — the coordinator's hard step deadline is the engine's 60 s
//      per-step deadline plus a 5 s grace (= 65 s); a hung body is force-yielded
//      with `RunDeadlineExceeded` (`procedure.deadline.exceeded`).
//   5. Fallback — the version chain steps down on, and only on, the four typed
//      `FallbackTrigger` classes; environmental / parse / budget refusals
//      surface without stepping.
//
// No engine run, no substrate, no store: this is a *runtime-policy* attestation,
// so it drives the coordinator and fallback surfaces directly. The deadline is
// driven off an injected fake timer (the d21 seam) so truncation is
// deterministic and instantaneous.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        BudgetDimension,
        ClassifiedFailure,
        EnvironmentalFailure,
        FallbackExecutor,
        FallbackTrigger,
        ForegroundQueueFull,
        LoadedProcedure,
        ProcedureBudget,
        ProcedureBudgetExceeded,
        ProcedureHeader,
        ProcedureRef,
        ProcedureResolver,
        ProcedureSourceParseException,
        RunCoordinator,
        RunDeadlineExceeded,
        RunSlot,
        RunSlotBusy,
        YieldPrimitive,
        defaultCoordinatorDeadlineGrace,
        defaultCoordinatorHardStepDeadline,
        defaultFallbackClassifier,
        defaultStepDeadline;
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

// ── Test doubles ────────────────────────────────────────────────────────────

/// A `Timer` test double mirroring the d21 deadline seam: it records the
/// scheduled [callback]/[duration] and fires only when the test calls [fire],
/// so the coordinator's hard step deadline is driven deterministically.
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

  void fire() {
    _ticks++;
    _active = false;
    callback();
  }
}

/// A typed failure carrying an explicit [failureKind] — a run that surfaced one
/// of the four fallback-class wire codes.
final class _ClassifiedError implements Exception, ClassifiedFailure {
  const _ClassifiedError(this.failureKind);
  @override
  final String failureKind;
}

/// A failure caused by the environment (substrate-down, network, billing) —
/// never fixable by an older procedure version.
final class _EnvError implements Exception, EnvironmentalFailure {
  const _EnvError();
}

/// Builds a minimal valid [LoadedProcedure] for [id]/[version], mirroring the
/// d29 resolver helper so the chain walk runs over real `LoadedProcedure`s.
LoadedProcedure _loaded(String id, int version) => LoadedProcedure(
      ref: ProcedureRef.system('/$id.v$version.dart'),
      header: ProcedureHeader(
        id: id,
        version: version,
        summary: 'summary of $id v$version',
        successCriterion: 'it works',
        budget: ProcedureBudget(const {'wallClockMs': 1000}),
      ),
      source: '/// @procedure\n/// id: $id\n/// version: $version\n// body',
    );

void main() {
  // ── Fact 1 + 2: slots and the FIFO foreground queue ───────────────────────
  group('P2.26 slots + queue — one foreground + one background, FIFO depth 4',
      () {
    test('a foreground and a background run are live at once on independent '
        'slots', () async {
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
      expect(coordinator.isIdle, isTrue);
    });

    test('the default foreground queue depth is 4', () {
      expect(RunCoordinator().foregroundQueueDepth, 4);
    });

    test('a fifth foreground submission past the full depth-4 queue overflows '
        'with ForegroundQueueFull(4)', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<void>();

      // One run occupies the slot; four more exactly fill the default queue.
      coordinator.submitForeground<void>(() => gate.future);
      for (var i = 0; i < 4; i++) {
        coordinator.submitForeground<void>(() async {});
      }
      expect(coordinator.foregroundQueueLength, 4);

      var overflowBodyRan = false;
      expect(
        () => coordinator.submitForeground<void>(() async {
          overflowBodyRan = true;
        }),
        throwsA(isA<ForegroundQueueFull>().having((e) => e.depth, 'depth', 4)),
      );
      expect(overflowBodyRan, isFalse,
          reason: 'an overflowing submission is never admitted');
      expect(coordinator.foregroundQueueLength, 4,
          reason: 'overflow leaves the queue untouched');

      gate.complete();
    });

    test('a second concurrent background submission is rejected loudly with '
        'RunSlotBusy(background) — there is no background queue', () async {
      final coordinator = RunCoordinator();
      final gate = Completer<int>();
      final first = coordinator.submitBackground<int>(() => gate.future);

      var rejectedBodyRan = false;
      expect(
        () => coordinator.submitBackground<int>(() async {
          rejectedBodyRan = true;
          return 0;
        }),
        throwsA(isA<RunSlotBusy>()
            .having((e) => e.slot, 'slot', RunSlot.background)),
      );
      expect(rejectedBodyRan, isFalse);

      gate.complete(7);
      expect(await first, 7);
    });
  });

  // ── Fact 3: preemption + the plan's Verify ─────────────────────────────────
  group('P2.26 preemption — a long background agent yields to a foreground '
      'prompt', () {
    test('a foreground arrival over a live background requests preemption',
        () async {
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

    test('VERIFY: a long background loop parks at its next YieldPrimitive '
        'checkpoint when a foreground arrives, then resumes once the '
        'foreground drains', () async {
      final shared = PreemptionState();
      final coordinator = RunCoordinator(preemption: shared);
      final checkpoint = YieldPrimitive(state: shared);

      final steps = <String>[];
      final step1Started = Completer<void>();
      final allowStep1Finish = Completer<void>();

      Future<String> longBackgroundAgent() async {
        steps.add('step0');
        await checkpoint.yieldIfForegroundWaiting(); // no fg yet → immediate
        steps.add('step1-start');
        step1Started.complete();
        await allowStep1Finish.future; // still mid-step when the prompt arrives
        steps.add('step1-end');
        await checkpoint.yieldIfForegroundWaiting(); // parks if fg waiting
        steps.add('step2');
        return 'bg-done';
      }

      final bg = coordinator.submitBackground<String>(longBackgroundAgent);
      await step1Started.future; // the agent is mid step 1

      // A foreground prompt arrives while the background is mid-step.
      final fgGate = Completer<int>();
      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      expect(shared.isForegroundWaiting, isTrue);

      // The in-flight step completes (never truncated mid-step); the agent then
      // parks at its next checkpoint — it must NOT reach step2 while the prompt
      // is waiting.
      allowStep1Finish.complete();
      await pumpEventQueue();
      expect(steps, contains('step1-end'),
          reason: 'preemption is at the next checkpoint, never mid-step');
      expect(steps, isNot(contains('step2')),
          reason: 'parked while the foreground prompt is waiting');

      // The foreground prompt completes → the agent resumes and finishes.
      fgGate.complete(42);
      expect(await fg, 42);
      expect(await bg, 'bg-done');
      expect(steps, contains('step2'));
      expect(shared.isForegroundWaiting, isFalse,
          reason: 'resume cleared the flag once the foreground drained');
    });
  });

  // ── Fact 4: the 60 s step deadline (+ 5 s grace) backstop ──────────────────
  group('P2.26 deadline — coordinator hard step deadline = 60 s + 5 s grace',
      () {
    test('defaults to the engine per-step 60 s deadline plus the 5 s grace', () {
      expect(defaultStepDeadline, const Duration(seconds: 60));
      expect(defaultCoordinatorDeadlineGrace, const Duration(seconds: 5));
      expect(defaultCoordinatorHardStepDeadline, const Duration(seconds: 65));
      expect(RunCoordinator().hardStepDeadline,
          defaultStepDeadline + defaultCoordinatorDeadlineGrace);
    });

    test('a hung run body is force-yielded with RunDeadlineExceeded and its '
        'slot is freed', () async {
      final timers = <_FakeTimer>[];
      final coordinator = RunCoordinator(
        deadlineTimerFactory: (duration, onExpire) {
          final timer = _FakeTimer(duration, onExpire);
          timers.add(timer);
          return timer;
        },
      );
      final gate = Completer<int>(); // never completes — a hung body.
      final run = coordinator.submitForeground<int>(() => gate.future);

      expect(coordinator.hasForegroundRun, isTrue);
      expect(timers.single.duration, defaultCoordinatorHardStepDeadline,
          reason: 'the backstop is armed for the 65 s hard deadline');

      timers.single.fire(); // the wall-clock deadline expires.

      await expectLater(
        run,
        throwsA(isA<RunDeadlineExceeded>()
            .having((e) => e.slot, 'slot', RunSlot.foreground)
            .having((e) => e.limit, 'limit', defaultCoordinatorHardStepDeadline)
            .having((e) => e.failureKind, 'failureKind',
                'procedure.deadline.exceeded')),
      );
      expect(coordinator.hasForegroundRun, isFalse,
          reason: 'the force-yield frees the slot');
    });
  });

  // ── Fact 5: the fallback chain steps only on the four typed failures ───────
  group('P2.26 fallback — steps down on, and only on, the four typed failures',
      () {
    // The closed set of fallback-class triggers, paired with the wire code each
    // carries. The version chain steps down on exactly these and nothing else.
    const triggerCodes = <FallbackTrigger, String>{
      FallbackTrigger.contractViolation: 'procedure.contract.violation',
      FallbackTrigger.critiqueRejected: 'procedure.critique.rejected',
      FallbackTrigger.deadlineExceeded: 'procedure.deadline.exceeded',
      FallbackTrigger.runtimeCrash: 'procedure.runtime.crash',
    };

    test('FallbackTrigger is exactly the four fallback-class wire codes', () {
      expect(FallbackTrigger.values.toSet(), triggerCodes.keys.toSet(),
          reason: 'the closed set has exactly four members');
      triggerCodes.forEach((trigger, code) {
        expect(trigger.failureKind, code);
        expect(FallbackTrigger.forKind(code), trigger,
            reason: 'each wire code round-trips to its trigger');
      });
    });

    for (final entry in triggerCodes.entries) {
      test('defaultFallbackClassifier routes ${entry.value} → ${entry.key.name}',
          () {
        expect(defaultFallbackClassifier(_ClassifiedError(entry.value)),
            entry.key);
      });
    }

    test('the real RunDeadlineExceeded classifies as deadlineExceeded', () {
      const error =
          RunDeadlineExceeded(RunSlot.foreground, Duration(seconds: 65));
      expect(defaultFallbackClassifier(error), FallbackTrigger.deadlineExceeded);
    });

    test('environmental / parse / budget failures surface without stepping '
        '(classifier returns null)', () {
      expect(defaultFallbackClassifier(const _EnvError()), isNull,
          reason: 'an older version cannot repair the environment');
      expect(
        defaultFallbackClassifier(
            const ProcedureSourceParseException('broken')),
        isNull,
        reason: 'a syntactically broken source is not a runtime crash',
      );
      expect(
        defaultFallbackClassifier(ProcedureBudgetExceeded(
          dimension: BudgetDimension.tokenSpend,
          limit: 100,
          consumed: 100,
          primitive: 'llm',
        )),
        isNull,
        reason: 'a deliberate budget refusal would recur on an older version',
      );
    });

    test('the executor steps the chain on a typed failure (records its '
        'trigger)', () async {
      final executor = FallbackExecutor(ProcedureResolver([_loaded('p', 1)]));
      final outcome = await executor.run<String>(
        procedureId: 'p',
        attempt: (_) async =>
            throw const _ClassifiedError('procedure.contract.violation'),
      );

      expect(outcome.isSuccess, isFalse);
      expect(outcome.attempts.single.trigger,
          FallbackTrigger.contractViolation,
          reason: 'a typed failure is recorded as a fallback attempt');
      expect(outcome.fallbackFailures, hasLength(1));
    });

    test('the executor does NOT step the chain on an environmental failure',
        () async {
      final executor = FallbackExecutor(ProcedureResolver([_loaded('p', 1)]));
      final outcome = await executor.run<String>(
        procedureId: 'p',
        attempt: (_) async => throw const _EnvError(),
      );

      expect(outcome.isSuccess, isFalse);
      expect(outcome.attempts.single.trigger, isNull,
          reason: 'an environmental failure is not a fallback trigger');
      expect(outcome.fallbackFailures, isEmpty,
          reason: 'the chain was surfaced, not stepped');
    });
  });
}
