// D.28 — slot-occupancy-reflects-the-runtime tests.
//
// Plan step D.28: "Tests: state reflects the runtime; concurrent foreground +
// background appears as two distinct entries." Reconciled per Q-D.26.1, the
// dispatcher-half state is the registry's in-memory slot-occupancy view (the
// engine `RunRecorder` owns the durable `inflight` / `recent_runs` nodes), so
// this suite asserts the *live occupancy* of that view through the run
// lifecycle: at any instant the registry holds exactly the runs the coordinator
// currently has live, each keyed by the slot it occupies.
//
// The headline invariant is the concurrent case: one foreground and one
// background run live at the same time appear as two *distinct* occupied slots
// (distinct registrations, distinct run ids, both slots present), and each slot
// clears as its run ends — independently, so ending one leaves the other live.

import 'dart:async';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show RunCoordinator, RunRegistry, RunSlot;
import 'package:test/test.dart';

void main() {
  group('D.28 — slot occupancy reflects the runtime', () {
    late RunRegistry registry;
    late RunCoordinator coordinator;

    setUp(() {
      registry = RunRegistry();
      coordinator = RunCoordinator(runRegistry: registry);
    });

    test('the view is empty before any run starts', () {
      expect(registry.isIdle, isTrue);
      expect(registry.liveRuns, isEmpty);
    });

    test('a live foreground run is exactly one occupied slot; on end the slot '
        'clears', () async {
      final gate = Completer<int>();

      final run = coordinator.submitForeground<int>(
        () => gate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // While the run is live: exactly one occupied slot, foreground.
      expect(registry.occupancy, hasLength(1));
      expect(registry.occupant(RunSlot.foreground)!.slot, RunSlot.foreground);
      expect(registry.occupant(RunSlot.background), isNull);

      gate.complete(7);
      expect(await run, 7);
      await pumpEventQueue();

      // After the run ends: the view is idle again.
      expect(registry.isIdle, isTrue);
    });

    test('concurrent foreground + background appear as two distinct occupied '
        'slots, then both clear', () async {
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

      // Two live runs ⇒ two occupied slots: distinct registrations, distinct
      // run ids, both slots present.
      expect(registry.occupancy.keys.toSet(),
          <RunSlot>{RunSlot.foreground, RunSlot.background});
      expect(registry.liveRuns.map((r) => r.runId).toSet(), hasLength(2));
      expect(registry.occupant(RunSlot.foreground)!.slot, RunSlot.foreground);
      expect(registry.occupant(RunSlot.background)!.slot, RunSlot.background);

      fgGate.complete(1);
      bgGate.complete(2);
      await fg;
      await bg;
      await pumpEventQueue();

      // Both slots cleared.
      expect(registry.isIdle, isTrue);
    });

    test('occupancy tracks the live set as one of two concurrent runs ends',
        () async {
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
      expect(registry.occupancy, hasLength(2));

      // End only the background run.
      bgGate.complete(0);
      await bg;
      await pumpEventQueue();

      // The view now reflects exactly the still-live foreground run.
      expect(registry.occupancy, hasLength(1));
      expect(registry.occupant(RunSlot.foreground)!.slot, RunSlot.foreground);
      expect(registry.occupant(RunSlot.background), isNull);

      // Finish the foreground run too, so no live state lingers.
      fgGate.complete(0);
      await fg;
      await pumpEventQueue();
      expect(registry.isIdle, isTrue);
    });

    test('sequential foreground runs each occupy then clear the slot', () async {
      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();
      expect(registry.isIdle, isTrue);

      await coordinator.submitForeground<int>(
        () async => 2,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // After both ran to completion the view returns to empty each time.
      expect(registry.isIdle, isTrue);
    });

    test('a failed run clears its slot', () async {
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
  });
}
