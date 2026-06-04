// D.26 — slot-occupancy view (dispatcher half) tests.
//
// Plan step D.26, reconciled per Q-D.26.1: the dispatcher half of PE-4 is an
// **in-memory slot-occupancy view**, not a second `ProcedureRun` writer. The
// engine-side `RunRecorder` (C.31) is the canonical and sole writer of the
// durable `inflight` / `recent_runs` nodes. Two layers are covered:
//
//   1. `RunRegistry` in isolation — `recordStart` sets a slot's occupant and
//      `recordEnd` clears it, with the right per-slot bookkeeping and no
//      memory interaction at all.
//   2. `RunCoordinator` wiring — a coordinator handed a registry records a run
//      as occupying its slot the moment the run starts (foreground and
//      background), assigns and threads a run id into the `PreemptionController`
//      slot events, and records nothing for an opaque body (no procedure id) or
//      when no registry is wired. Concurrent foreground + background appear as
//      two distinct occupied slots (the D.28 invariant, proved on the start
//      side here).
//
// Clearing the slot at run end is D.27 and is asserted there. The wiring tests
// below hold their runs live (a gated body) so every assertion observes the
// start-side occupancy in isolation, before the D.27 run-end clear can fire.

import 'dart:async';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        PreemptionEvent,
        RunCoordinator,
        RunRegistration,
        RunRegistry,
        RunSlot,
        RunSlotEntered;
import 'package:test/test.dart';

void main() {
  group('D.26 — RunRegistry.recordStart', () {
    late RunRegistry registry;

    setUp(() {
      registry = RunRegistry();
    });

    test('records the run as occupying its slot', () {
      const registration = RunRegistration(
        runId: 'r_1',
        procedureId: 'answer_with_memory_v1',
        slot: RunSlot.foreground,
      );

      registry.recordStart(registration);

      final occupant = registry.occupant(RunSlot.foreground);
      expect(occupant, same(registration));
      expect(occupant!.runId, 'r_1');
      expect(occupant.procedureId, 'answer_with_memory_v1');
      expect(occupant.version, 1);
      expect(occupant.slot, RunSlot.foreground);
      expect(registry.isIdle, isFalse);
    });

    test('keys occupancy by slot, so two slots coexist', () {
      registry.recordStart(
        const RunRegistration(
          runId: 'fg',
          procedureId: 'answer_with_memory_v1',
          slot: RunSlot.foreground,
        ),
      );
      registry.recordStart(
        const RunRegistration(
          runId: 'bg',
          procedureId: 'free_time_scheduler_v1',
          version: 3,
          slot: RunSlot.background,
        ),
      );

      expect(registry.occupancy.keys.toSet(),
          <RunSlot>{RunSlot.foreground, RunSlot.background});
      expect(registry.occupant(RunSlot.background)!.version, 3);
      expect(registry.liveRuns.map((r) => r.runId).toSet(),
          <String>{'fg', 'bg'});
    });

    test('a later start on the same slot replaces the occupant', () {
      registry.recordStart(
        const RunRegistration(
          runId: 'first',
          procedureId: 'p',
          slot: RunSlot.foreground,
        ),
      );
      registry.recordStart(
        const RunRegistration(
          runId: 'second',
          procedureId: 'p',
          slot: RunSlot.foreground,
        ),
      );

      expect(registry.occupant(RunSlot.foreground)!.runId, 'second');
      expect(registry.occupancy, hasLength(1));
    });

    test('preserves the parent run id on the occupant when supplied', () {
      registry.recordStart(
        const RunRegistration(
          runId: 'child',
          procedureId: 'p',
          slot: RunSlot.foreground,
          parentRunId: 'parent',
        ),
      );

      expect(registry.occupant(RunSlot.foreground)!.parentRunId, 'parent');
    });

    test('a top-level run has no parent run id', () {
      registry.recordStart(
        const RunRegistration(
          runId: 'top',
          procedureId: 'p',
          slot: RunSlot.foreground,
        ),
      );

      expect(registry.occupant(RunSlot.foreground)!.parentRunId, isNull);
    });

    test('occupancy snapshot is unmodifiable', () {
      registry.recordStart(
        const RunRegistration(
          runId: 'r',
          procedureId: 'p',
          slot: RunSlot.foreground,
        ),
      );

      expect(
        () => registry.occupancy[RunSlot.background] = const RunRegistration(
          runId: 'x',
          procedureId: 'p',
          slot: RunSlot.background,
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('D.26 — RunCoordinator wiring', () {
    test('a foreground run with a procedure id occupies the foreground slot',
        () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);
      // Hold the run live so the assertion observes the start-side occupancy in
      // isolation, before the D.27 run-end clear can fire.
      final gate = Completer<int>();

      final run = coordinator.submitForeground<int>(
        () => gate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      final occupant = registry.occupant(RunSlot.foreground);
      expect(occupant, isNotNull);
      expect(occupant!.procedureId, 'answer_with_memory_v1');
      expect(occupant.slot, RunSlot.foreground);
      expect(registry.occupant(RunSlot.background), isNull);

      gate.complete(0);
      await run;
    });

    test('a background run with a procedure id occupies the background slot',
        () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);
      final gate = Completer<int>();

      final run = coordinator.submitBackground<int>(
        () => gate.future,
        procedureId: 'free_time_scheduler_v1',
      );
      await pumpEventQueue();

      expect(registry.occupant(RunSlot.background)!.slot, RunSlot.background);
      expect(registry.occupant(RunSlot.foreground), isNull);

      gate.complete(0);
      await run;
    });

    test('no registry wired ⇒ no occupancy (run id still minted)', () async {
      final events = <PreemptionEvent>[];
      final coordinator = RunCoordinator();
      coordinator.preemptionEvents().listen(events.add);

      await coordinator.submitForeground<int>(
        () async => 1,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // No registry involved, so nothing recorded — but the run id is
      // assigned and threaded into the slot events.
      final entered = events.whereType<RunSlotEntered>().single;
      expect(entered.runId, isNotNull);
      expect(entered.runId, startsWith('disp-foreground-run-'));
    });

    test('an opaque body (no procedure id) is not recorded as occupancy',
        () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);

      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      expect(registry.isIdle, isTrue);
    });

    test('the minted run id is threaded into the slot enter event and the '
        'occupant', () async {
      final events = <PreemptionEvent>[];
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);
      coordinator.preemptionEvents().listen(events.add);
      final gate = Completer<int>();

      final run = coordinator.submitForeground<int>(
        () => gate.future,
        procedureId: 'p',
      );
      await pumpEventQueue();

      final entered = events.whereType<RunSlotEntered>().single;
      expect(entered.runId, registry.occupant(RunSlot.foreground)!.runId);

      gate.complete(0);
      await run;
    });

    test('an injected RunIdMint overrides the default counter', () async {
      final events = <PreemptionEvent>[];
      final registry = RunRegistry();
      final coordinator = RunCoordinator(
        runRegistry: registry,
        runIdMint: (slot) => 'custom-${slot.name}',
      );
      coordinator.preemptionEvents().listen(events.add);
      final gate = Completer<int>();

      final run =
          coordinator.submitForeground<int>(() => gate.future, procedureId: 'p');
      await pumpEventQueue();

      expect(registry.occupant(RunSlot.foreground)!.runId, 'custom-foreground');
      expect(
        events.whereType<RunSlotEntered>().single.runId,
        'custom-foreground',
      );

      gate.complete(0);
      await run;
    });

    test('concurrent foreground + background ⇒ two distinct occupied slots',
        () async {
      final registry = RunRegistry();
      final coordinator = RunCoordinator(runRegistry: registry);
      final fgGate = Completer<int>();
      final bgGate = Completer<int>();

      // Hold both runs live concurrently.
      final bg = coordinator.submitBackground<int>(
        () => bgGate.future,
        procedureId: 'free_time_scheduler_v1',
      );
      final fg = coordinator.submitForeground<int>(
        () => fgGate.future,
        procedureId: 'answer_with_memory_v1',
      );
      await pumpEventQueue();

      // Both slots are occupied before either run finishes.
      expect(registry.occupancy.keys.toSet(),
          <RunSlot>{RunSlot.foreground, RunSlot.background});
      expect(registry.occupant(RunSlot.foreground)!.slot, RunSlot.foreground);
      expect(registry.occupant(RunSlot.background)!.slot, RunSlot.background);
      // Distinct run ids.
      expect(
        registry.liveRuns.map((r) => r.runId).toSet(),
        hasLength(2),
      );

      fgGate.complete(0);
      bgGate.complete(0);
      await fg;
      await bg;
    });
  });
}
