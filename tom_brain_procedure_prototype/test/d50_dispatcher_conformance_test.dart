// D.50 — dispatcher configuration + observability conformance (Plan step
// D.50; `tom_brain_procedure_prototype_specification.md` § 13).
//
// Plan step text (verbatim): "Tests: config roundtrip; event ordering across
// a foreground + background interleave."
//
// D.50 is a tests-only step. It closes the two conformance halves the D.47 /
// D.48 / D.49 surfaces left at unit granularity:
//
//   1. **Config roundtrip.** D.47 proved `DispatcherConfig` round-trips as a
//      value object (`toYamlString → fromYamlString` identity). D.50 closes
//      the loop at the *runtime* boundary: a config that has survived a YAML
//      round-trip drives a `RunCoordinator` whose operative knobs (foreground
//      queue depth, hard step deadline) match the config it was built from —
//      so the YAML an operator writes is the behaviour the coordinator runs.
//
//   2. **Event ordering across a foreground + background interleave.** D.49
//      proved the `DispatcherEventBus` delivers in emit order at unit
//      granularity. D.50 closes it *through the real coordinator*: it drives a
//      live `RunCoordinator` through a background-then-foreground preemption
//      interleave (and, separately, a queued-foreground chain) and asserts the
//      `DispatcherEvent` stream the dispatcher produces arrives in the exact
//      order the interleave dictates.
//
// ── The projector stands in for the not-yet-built composition root ──────
//
// D.49's notes record that the boot-wiring step is where `DispatcherEventBus`
// .emit gets threaded into the entry surface (`AccessAccepted` /
// `ProcedureSelected` / `ForegroundQueued`), the `RunCoordinator` (`Preempted`
// / `Resumed` / `RunCompleted`), and the `FallbackExecutor` (`FallbackTried`).
// That wiring does not exist yet. So D.50's interleave test supplies a
// test-local `_DispatcherEventProjector` that plays the composition root: it
// emits the access-scoped events at the entry-surface moments and projects the
// coordinator's own `PreemptionEvent` transitions onto the bus as the
// run-scoped `DispatcherEvent`s. The projector is the conformance fixture, not
// production code — see the D.50 notes-carried-forward for the extraction the
// boot-wiring step owns.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        AccessAccepted,
        BackgroundResumeSignalled,
        DispatcherConfig,
        DispatcherEvent,
        DispatcherEventBus,
        FallbackTried,
        FallbackTrigger,
        ForegroundPreemptionRequested,
        ForegroundQueued,
        Preempted,
        PreemptionEvent,
        ProcedureSelected,
        Resumed,
        RunCompleted,
        RunCoordinator,
        RunOutcome,
        RunSlot,
        RunSlotEntered,
        RunSlotExited,
        RunSlotOutcome,
        defaultCoordinatorDeadlineGrace,
        defaultDispatcherHardStepDeadline,
        defaultForegroundQueueDepth,
        defaultStepDeadline;

/// Test-local composition-root stand-in (file header): emits the access-scoped
/// dispatcher events at the entry-surface moments and projects the live
/// coordinator's `PreemptionEvent` transitions onto the [DispatcherEventBus] as
/// the run-scoped `DispatcherEvent`s, in the order the coordinator drives them.
final class _DispatcherEventProjector {
  _DispatcherEventProjector(
    this._coordinator,
    this._bus, {
    required DateTime Function() clock,
  }) : _clock = clock {
    _subscription = _coordinator.preemptionEvents().listen(_onPreemptionEvent);
  }

  final RunCoordinator _coordinator;
  final DispatcherEventBus _bus;
  final DateTime Function() _clock;
  late final StreamSubscription<PreemptionEvent> _subscription;

  /// The procedure id the test submitted into each slot, captured at submit
  /// time and bound to the coordinator-minted run id when the run enters.
  final Map<RunSlot, String> _pendingProcedureBySlot = <RunSlot, String>{};
  final Map<String, String> _procedureByRunId = <String, String>{};

  String? _foregroundRunId;
  String? _backgroundRunId;

  /// Entry-surface moment 1: an inbound access was admitted (§ 10.1).
  void admitAccess({required String sessionId, String? kindHint}) => _bus.emit(
        AccessAccepted(
          occurredAt: _clock(),
          sessionId: sessionId,
          kindHint: kindHint,
        ),
      );

  /// Entry-surface moment 2: classification routed the inbound to a procedure
  /// (§ 10.2).
  void selectProcedure({
    required String inboundKind,
    required String procedureId,
  }) =>
      _bus.emit(
        ProcedureSelected(
          occurredAt: _clock(),
          inboundKind: inboundKind,
          procedureId: procedureId,
        ),
      );

  /// Records the procedure id a forthcoming submission will run in [slot], so
  /// the run-end projection can name it on its [RunCompleted].
  void noteSubmission(RunSlot slot, String procedureId) =>
      _pendingProcedureBySlot[slot] = procedureId;

  /// Entry-surface moment 3: a foreground submission queued behind a busy slot
  /// (§ 10.3, D.19). The coordinator has no preemption event for this, so the
  /// composition root emits it directly at submit time.
  void noteForegroundQueued(int queueDepth) => _bus.emit(
        ForegroundQueued(occurredAt: _clock(), queueDepth: queueDepth),
      );

  void _onPreemptionEvent(PreemptionEvent event) {
    switch (event) {
      case RunSlotEntered(:final slot, :final runId):
        final id = runId!;
        final procedureId = _pendingProcedureBySlot[slot];
        if (procedureId != null) _procedureByRunId[id] = procedureId;
        if (slot == RunSlot.foreground) {
          _foregroundRunId = id;
        } else {
          _backgroundRunId = id;
        }
      case RunSlotExited(:final slot, :final runId, :final outcome):
        final id = runId!;
        _bus.emit(
          RunCompleted(
            occurredAt: _clock(),
            runId: id,
            procedureId: _procedureByRunId[id] ?? '<unknown>',
            outcome: _runOutcomeOf(outcome),
            slot: slot,
          ),
        );
        if (slot == RunSlot.foreground) {
          _foregroundRunId = null;
        } else {
          _backgroundRunId = null;
        }
      case ForegroundPreemptionRequested():
        _bus.emit(
          Preempted(
            occurredAt: _clock(),
            runId: _backgroundRunId,
            foregroundRunId: _foregroundRunId,
          ),
        );
      case BackgroundResumeSignalled():
        _bus.emit(Resumed(occurredAt: _clock(), runId: _backgroundRunId));
    }
  }

  /// Maps the controller's slot outcome to the registry's terminal outcome —
  /// the same mapping the coordinator's private `_runOutcomeOf` performs (D.27).
  RunOutcome _runOutcomeOf(RunSlotOutcome outcome) => switch (outcome) {
        RunSlotOutcome.completed => RunOutcome.completed,
        RunSlotOutcome.failed => RunOutcome.failed,
        RunSlotOutcome.forceYielded => RunOutcome.forceYielded,
      };

  Future<void> dispose() => _subscription.cancel();
}

void main() {
  group('D.50-1 config roundtrip', () {
    test('the all-defaults config round-trips to an equal config', () {
      final config = DispatcherConfig();
      final roundTripped =
          DispatcherConfig.fromYamlString(config.toYamlString());
      expect(roundTripped, config);
    });

    test('a fully-custom config round-trips to an equal config', () {
      final config = DispatcherConfig(
        systemScriptsPath: 'scripts/system',
        userScriptsPath: 'scripts/user',
        foregroundQueueDepth: 7,
        hardStepDeadline: const Duration(seconds: 90),
        schedulerEnabled: true,
      );
      final roundTripped =
          DispatcherConfig.fromYamlString(config.toYamlString());
      expect(roundTripped, config);
    });

    test('a round-tripped config drives a coordinator with identical knobs',
        () {
      // The conformance closure: the YAML an operator writes is the behaviour
      // the coordinator runs. A config that survived a YAML round-trip builds a
      // coordinator whose operative knobs match the config it came from.
      final config = DispatcherConfig(
        foregroundQueueDepth: 6,
        hardStepDeadline: const Duration(seconds: 42),
      );
      final roundTripped =
          DispatcherConfig.fromYamlString(config.toYamlString());

      final coordinator = RunCoordinator(
        foregroundQueueDepth: roundTripped.foregroundQueueDepth,
        hardStepDeadline: roundTripped.hardStepDeadline,
      );

      expect(coordinator.foregroundQueueDepth, 6);
      expect(coordinator.hardStepDeadline, const Duration(seconds: 42));
      // And those are exactly the config's own values, unchanged by the trip.
      expect(coordinator.foregroundQueueDepth, config.foregroundQueueDepth);
      expect(coordinator.hardStepDeadline, config.hardStepDeadline);
    });

    test(
        'the default config knobs match the coordinator defaults '
        '(config↔runtime drift guard)', () {
      final config = DispatcherConfig();
      expect(config.foregroundQueueDepth, defaultForegroundQueueDepth);
      // The default hard step deadline is the engine per-step deadline plus the
      // coordinator grace — the same backstop relationship the coordinator
      // applies. Locks the config default to the runtime default.
      expect(
        config.hardStepDeadline,
        defaultDispatcherHardStepDeadline,
      );
      expect(
        defaultDispatcherHardStepDeadline,
        defaultStepDeadline + defaultCoordinatorDeadlineGrace,
      );

      final coordinator = RunCoordinator();
      expect(coordinator.foregroundQueueDepth, config.foregroundQueueDepth);
      expect(coordinator.hardStepDeadline, config.hardStepDeadline);
    });
  });

  group('D.50-2 event ordering — foreground preempts background', () {
    // A frozen UTC clock so every emitted event stamps a deterministic time.
    final frozenNow = DateTime.utc(2026, 6, 2, 9, 30, 15, 250);

    late DispatcherEventBus bus;
    late List<DispatcherEvent> collected;
    late StreamSubscription<DispatcherEvent> busSubscription;
    late RunCoordinator coordinator;
    late _DispatcherEventProjector projector;

    setUp(() {
      bus = DispatcherEventBus();
      collected = <DispatcherEvent>[];
      busSubscription = bus.events().listen(collected.add);
      // A generous hard step deadline so the coordinator's per-run timer never
      // fires — every run here ends through its gate, not by force-yield.
      coordinator =
          RunCoordinator(hardStepDeadline: const Duration(minutes: 5));
      projector =
          _DispatcherEventProjector(coordinator, bus, clock: () => frozenNow);
    });

    tearDown(() async {
      await projector.dispose();
      await busSubscription.cancel();
      await bus.close();
    });

    test(
        'the interleave produces AccessAccepted → ProcedureSelected → '
        'Preempted → RunCompleted(fg) → Resumed → RunCompleted(bg)', () async {
      final bgGate = Completer<int>();
      final fgGate = Completer<int>();

      // Background is live first (scheduler-driven free-time work; no entry
      // surface, so no AccessAccepted for it).
      projector.noteSubmission(RunSlot.background, 'dream_v1');
      final bg = coordinator.submitBackground<int>(
        () => bgGate.future,
        procedureId: 'dream_v1',
      );
      await pumpEventQueue();

      // An inbound user prompt arrives: entry surface admits + routes it, then
      // the coordinator admits it and preempts the live background.
      projector.admitAccess(sessionId: 'session-1', kindHint: 'user_prompt');
      projector.selectProcedure(
        inboundKind: 'user_prompt',
        procedureId: 'answer_with_memory_v1',
      );
      projector.noteSubmission(RunSlot.foreground, 'answer_with_memory_v1');
      final fg = coordinator.submitForeground<int>(
        () => fgGate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // The foreground completes: it exits, then the drained chain resumes the
      // parked background.
      fgGate.complete(1);
      expect(await fg, 1);
      await pumpEventQueue();

      // The background completes, closing the bracket.
      bgGate.complete(2);
      expect(await bg, 2);
      await pumpEventQueue();

      expect(collected.map((e) => e.kind).toList(), <String>[
        'dispatcher.access-accepted',
        'dispatcher.procedure-selected',
        'dispatcher.preempted',
        'dispatcher.run-completed', // foreground
        'dispatcher.resumed',
        'dispatcher.run-completed', // background
      ]);
    });

    test('the run-scoped events carry the right run ids, slots, and outcomes',
        () async {
      final bgGate = Completer<int>();
      final fgGate = Completer<int>();

      projector.noteSubmission(RunSlot.background, 'dream_v1');
      final bg = coordinator.submitBackground<int>(
        () => bgGate.future,
        procedureId: 'dream_v1',
      );
      await pumpEventQueue();

      projector.admitAccess(sessionId: 'session-1', kindHint: 'user_prompt');
      projector.selectProcedure(
        inboundKind: 'user_prompt',
        procedureId: 'answer_with_memory_v1',
      );
      projector.noteSubmission(RunSlot.foreground, 'answer_with_memory_v1');
      final fg = coordinator.submitForeground<int>(
        () => fgGate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();
      fgGate.complete(1);
      await fg;
      await pumpEventQueue();
      bgGate.complete(2);
      await bg;
      await pumpEventQueue();

      final accepted = collected.whereType<AccessAccepted>().single;
      expect(accepted.sessionId, 'session-1');
      expect(accepted.kindHint, 'user_prompt');

      final selected = collected.whereType<ProcedureSelected>().single;
      expect(selected.inboundKind, 'user_prompt');
      expect(selected.procedureId, 'answer_with_memory_v1');

      // The preempted run is the live background; the trigger is the foreground.
      final preempted = collected.whereType<Preempted>().single;
      expect(preempted.runId, startsWith('disp-background'));
      expect(preempted.foregroundRunId, startsWith('disp-foreground'));

      final completions = collected.whereType<RunCompleted>().toList();
      expect(completions, hasLength(2));
      // The foreground run completes first (it drains before the background).
      expect(completions[0].slot, RunSlot.foreground);
      expect(completions[0].procedureId, 'answer_with_memory_v1');
      expect(completions[0].outcome, RunOutcome.completed);
      expect(completions[0].runId, startsWith('disp-foreground'));
      // The background run completes last.
      expect(completions[1].slot, RunSlot.background);
      expect(completions[1].procedureId, 'dream_v1');
      expect(completions[1].outcome, RunOutcome.completed);
      expect(completions[1].runId, startsWith('disp-background'));

      // The resumed run is the same background that was preempted.
      final resumed = collected.whereType<Resumed>().single;
      expect(resumed.runId, preempted.runId);
    });

    test('every emitted event stamps the injected UTC clock', () async {
      final bgGate = Completer<int>();
      projector.noteSubmission(RunSlot.background, 'dream_v1');
      final bg = coordinator.submitBackground<int>(
        () => bgGate.future,
        procedureId: 'dream_v1',
      );
      await pumpEventQueue();
      projector.admitAccess(sessionId: 'session-1');
      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();
      bgGate.complete(2);
      await bg;
      await pumpEventQueue();

      expect(collected, isNotEmpty);
      for (final event in collected) {
        expect(event.occurredAt, frozenNow);
        expect(event.occurredAt.isUtc, isTrue);
      }
    });
  });

  group('D.50-3 event ordering — queued foreground chain', () {
    final frozenNow = DateTime.utc(2026, 6, 2, 9, 30, 15, 250);

    late DispatcherEventBus bus;
    late List<DispatcherEvent> collected;
    late StreamSubscription<DispatcherEvent> busSubscription;
    late RunCoordinator coordinator;
    late _DispatcherEventProjector projector;

    setUp(() {
      bus = DispatcherEventBus();
      collected = <DispatcherEvent>[];
      busSubscription = bus.events().listen(collected.add);
      coordinator =
          RunCoordinator(hardStepDeadline: const Duration(minutes: 5));
      projector =
          _DispatcherEventProjector(coordinator, bus, clock: () => frozenNow);
    });

    tearDown(() async {
      await projector.dispose();
      await busSubscription.cancel();
      await bus.close();
    });

    test(
        'a second foreground submission queues, then both complete in '
        'submission order', () async {
      final gate1 = Completer<int>();
      final gate2 = Completer<int>();

      // First foreground starts immediately.
      projector.admitAccess(sessionId: 'session-1');
      projector.selectProcedure(
        inboundKind: 'user_prompt',
        procedureId: 'answer_with_memory_v1',
      );
      projector.noteSubmission(RunSlot.foreground, 'answer_with_memory_v1');
      final fg1 = coordinator.submitForeground<int>(
        () => gate1.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // Second foreground arrives while the slot is busy: it queues.
      projector.admitAccess(sessionId: 'session-2');
      projector.selectProcedure(
        inboundKind: 'user_prompt',
        procedureId: 'answer_with_memory_v1',
      );
      projector.noteSubmission(RunSlot.foreground, 'answer_with_memory_v1');
      final fg2 = coordinator.submitForeground<int>(
        () => gate2.future,
        procedureId: 'answer_with_memory_v1',
      );
      // The submission was admitted into the FIFO queue, not started.
      expect(coordinator.foregroundQueueLength, 1);
      projector.noteForegroundQueued(coordinator.foregroundQueueLength);
      await pumpEventQueue();

      // First completes; the queued second pumps into the freed slot.
      gate1.complete(1);
      expect(await fg1, 1);
      await pumpEventQueue();

      // Second completes.
      gate2.complete(2);
      expect(await fg2, 2);
      await pumpEventQueue();

      expect(collected.map((e) => e.kind).toList(), <String>[
        'dispatcher.access-accepted', // session-1
        'dispatcher.procedure-selected',
        'dispatcher.access-accepted', // session-2
        'dispatcher.procedure-selected',
        'dispatcher.foreground-queued', // session-2 queued
        'dispatcher.run-completed', // fg1
        'dispatcher.run-completed', // fg2 (after fg1 drained)
      ]);

      final queued = collected.whereType<ForegroundQueued>().single;
      expect(queued.queueDepth, 1);

      final completions = collected.whereType<RunCompleted>().toList();
      expect(completions, hasLength(2));
      expect(completions.every((c) => c.slot == RunSlot.foreground), isTrue);
    });
  });

  group('D.50-4 full dispatcher-vocabulary ordering through the bus', () {
    test('all seven variant kinds arrive in emit order', () async {
      final bus = DispatcherEventBus();
      final collected = <DispatcherEvent>[];
      final subscription = bus.events().listen(collected.add);
      final now = DateTime.utc(2026, 6, 2);

      // Emit one of every variant in a fixed order; the broadcast bus must
      // preserve it. Complements D.49's bus test by exercising the whole
      // § 13 vocabulary, including the fallback variant the coordinator
      // interleave does not naturally produce.
      bus
        ..emit(AccessAccepted(occurredAt: now, sessionId: 's'))
        ..emit(ProcedureSelected(
          occurredAt: now,
          inboundKind: 'user_prompt',
          procedureId: 'p',
        ))
        ..emit(ForegroundQueued(occurredAt: now, queueDepth: 1))
        ..emit(Preempted(occurredAt: now, runId: 'bg'))
        ..emit(Resumed(occurredAt: now, runId: 'bg'))
        ..emit(RunCompleted(
          occurredAt: now,
          runId: 'fg',
          procedureId: 'p',
          outcome: RunOutcome.completed,
          slot: RunSlot.foreground,
        ))
        ..emit(FallbackTried(
          occurredAt: now,
          procedureId: 'p',
          fromVersion: 1,
          toVersion: null,
          trigger: FallbackTrigger.runtimeCrash,
        ));

      await pumpEventQueue();

      expect(collected.map((e) => e.kind).toList(), <String>[
        'dispatcher.access-accepted',
        'dispatcher.procedure-selected',
        'dispatcher.foreground-queued',
        'dispatcher.preempted',
        'dispatcher.resumed',
        'dispatcher.run-completed',
        'dispatcher.fallback-tried',
      ]);

      await subscription.cancel();
      await bus.close();
    });
  });
}
