// `PreemptionController` tests (Plan step D.23;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5;
// `tom_brain_definition.md` § 7.1).
//
// D.23 delivers the supervising observer over the coordinator's two run
// slots: it maintains a model of slot occupancy + pending-preemption state
// and emits a typed `PreemptionEvent` on every transition, without writing
// `PreemptionState`. These tests pin exactly that scope:
//
//   - each transition emits the matching event with the right slot / outcome;
//   - the controller's derived state getters track the recorded transitions;
//   - preemption request / resume are idempotent — events fire only on a true
//     edge, mirroring `PreemptionState`;
//   - emitted events carry the optional `runId` / `causedBy` and a UTC
//     `occurredAt` from the injected clock, and serialise to the expected
//     `kind` + payload;
//   - the broadcast stream + close lifecycle matches `EngineEventBus`.
//
// The D.24 coordinator wiring and the D.25 full transition suite build on
// this; D.23 ships its own tests per the test-first discipline.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        BackgroundResumeSignalled,
        ForegroundPreemptionRequested,
        PreemptionController,
        PreemptionEvent,
        RunSlot,
        RunSlotEntered,
        RunSlotExited,
        RunSlotOutcome;

void main() {
  group('D.23 PreemptionController — transitions emit events', () {
    test('a foreground run start emits RunSlotEntered(foreground)', () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final first = controller.events().first;

      controller.recordRunStarted(RunSlot.foreground);

      final event = await first;
      expect(event, isA<RunSlotEntered>());
      expect((event as RunSlotEntered).slot, RunSlot.foreground);
      expect(controller.isForegroundOccupied, isTrue);
      expect(controller.isBackgroundOccupied, isFalse);
    });

    test('a background run start emits RunSlotEntered(background)', () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller.recordRunStarted(RunSlot.background);
      await controller.close();

      final events = await collected;
      expect(events, hasLength(1));
      expect(events.single, isA<RunSlotEntered>());
      expect((events.single as RunSlotEntered).slot, RunSlot.background);
      expect(controller.isBackgroundOccupied, isTrue);
    });

    test('a run finish emits RunSlotExited carrying the slot and outcome',
        () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller.recordRunStarted(RunSlot.foreground);
      controller.recordRunFinished(
        RunSlot.foreground,
        RunSlotOutcome.completed,
      );
      await controller.close();

      final events = await collected;
      expect(events, hasLength(2));
      expect(events[1], isA<RunSlotExited>());
      final exited = events[1] as RunSlotExited;
      expect(exited.slot, RunSlot.foreground);
      expect(exited.outcome, RunSlotOutcome.completed);
      expect(controller.isForegroundOccupied, isFalse);
    });

    test('every run-finish outcome is carried through verbatim', () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller
        ..recordRunFinished(RunSlot.foreground, RunSlotOutcome.completed)
        ..recordRunFinished(RunSlot.background, RunSlotOutcome.failed)
        ..recordRunFinished(RunSlot.foreground, RunSlotOutcome.forceYielded);
      await controller.close();

      final events = await collected;
      final outcomes = events
          .cast<RunSlotExited>()
          .map((e) => e.outcome)
          .toList(growable: false);
      expect(outcomes, <RunSlotOutcome>[
        RunSlotOutcome.completed,
        RunSlotOutcome.failed,
        RunSlotOutcome.forceYielded,
      ]);
    });

    test('a foreground preemption request emits ForegroundPreemptionRequested',
        () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller.recordForegroundPreemptionRequested();
      await controller.close();

      final events = await collected;
      expect(events.single, isA<ForegroundPreemptionRequested>());
      expect(controller.isPreemptionPending, isTrue);
    });

    test('a resume after a pending request emits BackgroundResumeSignalled',
        () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller.recordForegroundPreemptionRequested();
      controller.recordBackgroundResumeSignalled();
      await controller.close();

      final events = await collected;
      expect(events, hasLength(2));
      expect(events[0], isA<ForegroundPreemptionRequested>());
      expect(events[1], isA<BackgroundResumeSignalled>());
      expect(controller.isPreemptionPending, isFalse);
    });
  });

  group('D.23 PreemptionController — idempotency mirrors PreemptionState', () {
    test('back-to-back preemption requests emit exactly one event', () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller
        ..recordForegroundPreemptionRequested()
        ..recordForegroundPreemptionRequested()
        ..recordForegroundPreemptionRequested();
      await controller.close();

      final events = await collected;
      expect(events, hasLength(1));
      expect(events.single, isA<ForegroundPreemptionRequested>());
    });

    test('a resume with nothing pending is a no-op and emits nothing',
        () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller.recordBackgroundResumeSignalled();
      await controller.close();

      final events = await collected;
      expect(events, isEmpty);
      expect(controller.isPreemptionPending, isFalse);
    });

    test('a request → resume → request cycle emits one event per real edge',
        () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller
        ..recordForegroundPreemptionRequested()
        ..recordForegroundPreemptionRequested()
        ..recordBackgroundResumeSignalled()
        ..recordBackgroundResumeSignalled()
        ..recordForegroundPreemptionRequested();
      await controller.close();

      final events = await collected;
      expect(events, hasLength(3));
      expect(events[0], isA<ForegroundPreemptionRequested>());
      expect(events[1], isA<BackgroundResumeSignalled>());
      expect(events[2], isA<ForegroundPreemptionRequested>());
      expect(controller.isPreemptionPending, isTrue);
    });
  });

  group('D.23 PreemptionController — event base fields and serialisation', () {
    test('runId and causedBy flow into the emitted event', () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller.recordRunStarted(
        RunSlot.background,
        runId: 'run-7',
        causedBy: 'ev-3',
      );
      await controller.close();

      final event = (await collected).single;
      expect(event.runId, 'run-7');
      expect(event.causedBy, 'ev-3');
    });

    test('occurredAt is stamped from the injected clock and is UTC', () async {
      final fixed = DateTime.utc(2026, 6, 2, 9, 30);
      final controller = PreemptionController(clock: () => fixed);
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller.recordRunStarted(RunSlot.foreground);
      await controller.close();

      final event = (await collected).single;
      expect(event.occurredAt, fixed);
      expect(event.occurredAt.isUtc, isTrue);
    });

    test('each variant serialises to its kind and payload', () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final collected = _collect(controller.events());

      controller
        ..recordRunStarted(RunSlot.foreground)
        ..recordRunFinished(RunSlot.background, RunSlotOutcome.forceYielded)
        ..recordForegroundPreemptionRequested()
        ..recordBackgroundResumeSignalled();
      await controller.close();

      final events = await collected;
      final entered = events[0].toJson();
      expect(entered['kind'], 'dispatcher.run-slot-entered');
      expect(entered['payload'], <String, Object?>{'slot': 'foreground'});

      final exited = events[1].toJson();
      expect(exited['kind'], 'dispatcher.run-slot-exited');
      expect(exited['payload'],
          <String, Object?>{'slot': 'background', 'outcome': 'forceYielded'});

      expect(events[2].toJson()['kind'],
          'dispatcher.foreground-preemption-requested');
      expect(events[2].toJson()['payload'], isEmpty);

      expect(events[3].toJson()['kind'],
          'dispatcher.background-resume-signalled');
      expect(events[3].toJson()['payload'], isEmpty);
    });
  });

  group('D.23 PreemptionController — stream and lifecycle', () {
    test('broadcast: two subscribers both see every event', () async {
      final controller = PreemptionController();
      addTearDown(controller.close);
      final a = _collect(controller.events());
      final b = _collect(controller.events());

      controller
        ..recordRunStarted(RunSlot.foreground)
        ..recordRunFinished(RunSlot.foreground, RunSlotOutcome.completed);
      await controller.close();

      expect(await a, hasLength(2));
      expect(await b, hasLength(2));
    });

    test('a record after close throws StateError', () async {
      final controller = PreemptionController();
      await controller.close();

      expect(controller.isClosed, isTrue);
      expect(
        () => controller.recordRunStarted(RunSlot.foreground),
        throwsStateError,
      );
      expect(
        () => controller.recordForegroundPreemptionRequested(),
        throwsStateError,
      );
    });

    test('close is idempotent', () async {
      final controller = PreemptionController();
      await controller.close();
      await controller.close();
      expect(controller.isClosed, isTrue);
    });
  });
}

/// Drains [stream] into a list that resolves when the stream is done.
Future<List<PreemptionEvent>> _collect(Stream<PreemptionEvent> stream) {
  return stream.toList();
}
