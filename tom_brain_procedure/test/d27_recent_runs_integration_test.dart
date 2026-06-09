// D.27 — slot-occupancy clear (dispatcher half) tests.
//
// Plan step D.27, reconciled per Q-D.26.1: the run-end half of the dispatcher
// view. The registry is an in-memory slot-occupancy view, not a `ProcedureRun`
// writer — the engine `RunRecorder` (C.31) owns the durable `recent_runs` move.
// Two layers are covered:
//
//   1. `RunRegistry.recordEnd` in isolation — it clears the named slot from the
//      occupancy view and is idempotent (clearing an already-free slot is a
//      no-op), so a double run-end signal cannot corrupt the view.
//   2. `RunCoordinator` wiring — a coordinator handed a registry clears the
//      run's slot on every run end (success, failure, or a hard-step-deadline
//      force-yield). An opaque body (no procedure id) or a coordinator with no
//      registry runs cleanly with no occupancy. Concurrent foreground +
//      background both clear their slots as each run ends.
//
// The terminal outcome itself is carried on the `RunCompleted` `DispatcherEvent`
// (D.49) via the `RunOutcome` enum, whose wire-string mapping is pinned here.

import 'dart:async';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        RunCoordinator,
        RunOutcome,
        RunRegistration,
        RunRegistry,
        RunSlot;
import 'package:test/test.dart';

void main() {
  group('D.27 — RunRegistry.recordEnd', () {
    late RunRegistry registry;

    setUp(() {
      registry = RunRegistry();
    });

    void start(String runId, RunSlot slot) => registry.recordStart(
          RunRegistration(runId: runId, procedureId: 'p', slot: slot),
        );

    test('clears the run from its slot', () {
      start('r_1', RunSlot.foreground);
      expect(registry.occupant(RunSlot.foreground), isNotNull);

      registry.recordEnd(RunSlot.foreground);

      expect(registry.occupant(RunSlot.foreground), isNull);
      expect(registry.isIdle, isTrue);
    });

    test('clearing an already-free slot is a no-op (idempotent)', () {
      start('r_1', RunSlot.foreground);
      registry.recordEnd(RunSlot.foreground);

      // A second clear of the same slot must not throw or corrupt the view.
      registry.recordEnd(RunSlot.foreground);

      expect(registry.isIdle, isTrue);
    });

    test('clears only the named slot, leaving the other occupied', () {
      start('fg', RunSlot.foreground);
      start('bg', RunSlot.background);

      registry.recordEnd(RunSlot.foreground);

      expect(registry.occupant(RunSlot.foreground), isNull);
      expect(registry.occupant(RunSlot.background)!.runId, 'bg');
      expect(registry.isIdle, isFalse);
    });

    test('clearing both slots empties the view', () {
      start('fg', RunSlot.foreground);
      start('bg', RunSlot.background);

      registry.recordEnd(RunSlot.foreground);
      registry.recordEnd(RunSlot.background);

      expect(registry.isIdle, isTrue);
      expect(registry.liveRuns, isEmpty);
    });
  });

  group('D.27 — RunCoordinator wiring', () {
    test('a foreground run that completes clears the foreground slot', () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);

      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      expect(registry.occupant(RunSlot.foreground), isNull);
      expect(registry.isIdle, isTrue);
    });

    test('a background run that completes clears the background slot', () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);

      await coordinator.submitBackground<int>(
        () async => 1,
        procedureId: 'free_time_scheduler_v1',
      );
      await pumpEventQueue();

      expect(registry.occupant(RunSlot.background), isNull);
      expect(registry.isIdle, isTrue);
    });

    test('a foreground run that throws still clears its slot', () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);

      await expectLater(
        coordinator.submitForeground<int>(
          () async => throw StateError('boom'),
          procedureId: 'answer_with_memory_v1',
        ),
        throwsA(isA<StateError>()),
      );
      await pumpEventQueue();

      expect(registry.isIdle, isTrue);
    });

    test('no registry wired ⇒ the run completes cleanly', () async {
      final coordinator = RunCoordinator();

      final result = await coordinator.submitForeground<int>(
        () async => 7,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      expect(result, 7);
    });

    test('an opaque body (no procedure id) leaves the view idle', () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);

      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      expect(registry.isIdle, isTrue);
    });

    test('concurrent foreground + background both clear their slots at run end',
        () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);
      final fgGate = Completer<int>();
      final bgGate = Completer<int>();

      final bg = coordinator.submitBackground<int>(
        () => bgGate.future,
        procedureId: 'free_time_scheduler_v1',
      );
      final fg = coordinator.submitForeground<int>(
        () => fgGate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // Both slots are occupied, none cleared yet.
      expect(registry.occupancy, hasLength(2));

      fgGate.complete(0);
      bgGate.complete(0);
      await fg;
      await bg;
      await pumpEventQueue();

      // Both slots cleared as their runs ended.
      expect(registry.isIdle, isTrue);
    });
  });

  group('D.27 — RunOutcome wire mapping', () {
    test('RunOutcome.status maps each terminal outcome to its wire string', () {
      expect(RunOutcome.completed.status, 'completed');
      expect(RunOutcome.failed.status, 'failed');
      expect(RunOutcome.forceYielded.status, 'force_yielded');
    });
  });
}
