// `PreemptionController` ↔ `RunCoordinator` wiring (Plan step D.24;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5, § 14;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// D.23 shipped the `PreemptionController` standalone (driven by calling its
// `record*` surface directly). D.24 wires the `RunCoordinator` to call that
// surface at its existing transition points, so the controller's
// `PreemptionEvent` stream reflects the *live* coordinator without the
// controller ever becoming a second writer of `PreemptionState`.
//
// This suite proves the wiring end-to-end through the coordinator's own
// submission surface (`submitForeground` / `submitBackground`), not by poking
// the controller directly:
//
//   - run start in either slot → `RunSlotEntered` with the right slot;
//   - run finish → `RunSlotExited` carrying the mapped `RunSlotOutcome`
//     (`completed` on a clean return, `failed` on a thrown error,
//     `forceYielded` on a hard-step-deadline truncation);
//   - a foreground arrival while a background run is live → exactly one
//     `ForegroundPreemptionRequested` (idempotent across back-to-back
//     arrivals);
//   - the foreground chain draining → exactly one `BackgroundResumeSignalled`;
//   - rejected submissions (`RunSlotBusy`, `ForegroundQueueFull`) and still-
//     queued foreground runs emit nothing until they actually occupy a slot;
//   - `preemptionEvents()` surfaces the injected controller's stream so the
//     dispatcher API exposes preemption observability;
//   - the coordinator never writes `PreemptionState` through the controller —
//     the controller stays observe-only.
//
// The deadline-driven case uses an injected `_FakeTimer` (the C.36 /
// D.21 / D.22 seam) so truncation is deterministic; every other case runs
// under a generously large real deadline whose timer never fires.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        BackgroundResumeSignalled,
        ForegroundPreemptionRequested,
        ForegroundQueueFull,
        PreemptionController,
        PreemptionEvent,
        RunCoordinator,
        RunSlot,
        RunSlotBusy,
        RunSlotEntered,
        RunSlotExited,
        RunSlotOutcome;
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

/// A `Timer` test double driving each per-run `StepDeadline` deterministically:
/// records the scheduled callback, tracks cancellation, and fires only on
/// [fire]. Identical in spirit to the D.21 / D.22 doubles.
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

void main() {
  // Events the injected controller emits, captured in stream order so a test
  // can assert the exact transition sequence the coordinator drove.
  late List<PreemptionEvent> events;
  late PreemptionController controller;
  late StreamSubscription<PreemptionEvent> subscription;

  setUp(() {
    controller = PreemptionController();
    events = <PreemptionEvent>[];
  });

  tearDown(() async {
    await subscription.cancel();
    await controller.close();
  });

  /// Builds a coordinator over the shared [controller] (and optional
  /// [preemption]) and subscribes to its `preemptionEvents()` stream into
  /// [events]. Subscribing before any submission means no transition is missed.
  RunCoordinator build({
    PreemptionState? preemption,
    int foregroundQueueDepth = 4,
  }) {
    final coordinator = RunCoordinator(
      preemption: preemption,
      preemptionController: controller,
      foregroundQueueDepth: foregroundQueueDepth,
    );
    subscription = coordinator.preemptionEvents().listen(events.add);
    return coordinator;
  }

  group('D.24 — run start / finish drive the controller', () {
    test('a foreground run start emits RunSlotEntered(foreground); a clean '
        'finish emits RunSlotExited(foreground, completed)', () async {
      final coordinator = build();
      final gate = Completer<int>();

      final run = coordinator.submitForeground<int>(() => gate.future);
      await pumpEventQueue();
      expect(events.single, isA<RunSlotEntered>());
      expect((events.single as RunSlotEntered).slot, RunSlot.foreground);

      gate.complete(7);
      expect(await run, 7);
      await pumpEventQueue();

      expect(events, hasLength(2));
      expect(events[1], isA<RunSlotExited>());
      final exited = events[1] as RunSlotExited;
      expect(exited.slot, RunSlot.foreground);
      expect(exited.outcome, RunSlotOutcome.completed);
    });

    test('a background run start emits RunSlotEntered(background); a clean '
        'finish emits RunSlotExited(background, completed)', () async {
      final coordinator = build();
      final gate = Completer<int>();

      final run = coordinator.submitBackground<int>(() => gate.future);
      await pumpEventQueue();
      expect((events.single as RunSlotEntered).slot, RunSlot.background);

      gate.complete(3);
      expect(await run, 3);
      await pumpEventQueue();

      final exited = events[1] as RunSlotExited;
      expect(exited.slot, RunSlot.background);
      expect(exited.outcome, RunSlotOutcome.completed);
    });

    test('a body that throws finishes with RunSlotExited(..., failed)',
        () async {
      final coordinator = build();

      await expectLater(
        coordinator.submitForeground<int>(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.foreground);
      expect(exited.outcome, RunSlotOutcome.failed,
          reason: 'a thrown body maps to the failed outcome, not completed');
    });

    test('a hard-step-deadline force-yield finishes with '
        'RunSlotExited(..., forceYielded)', () async {
      final timers = <_FakeTimer>[];
      final coordinator = RunCoordinator(
        preemptionController: controller,
        deadlineTimerFactory: (duration, onExpire) {
          final timer = _FakeTimer(duration, onExpire);
          timers.add(timer);
          return timer;
        },
      );
      subscription = coordinator.preemptionEvents().listen(events.add);

      // A body that never completes; the coordinator deadline force-yields it.
      final run = coordinator.submitForeground<int>(() => Completer<int>().future);
      await pumpEventQueue();
      expect(events.single, isA<RunSlotEntered>());

      timers.single.fire();
      await expectLater(run, throwsA(anything));
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.foreground);
      expect(exited.outcome, RunSlotOutcome.forceYielded);
    });
  });

  group('D.24 — preemption request / resume drive the controller', () {
    test('a foreground arrival while a background run is live emits exactly one '
        'ForegroundPreemptionRequested, then one BackgroundResumeSignalled '
        'when the foreground drains', () async {
      final coordinator = build();
      final bgGate = Completer<int>();
      final fgGate = Completer<int>();

      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      await pumpEventQueue();

      // Background entered, foreground entered, then the preemption request.
      expect(events.map((e) => e.runtimeType), <Type>[
        RunSlotEntered, // background
        RunSlotEntered, // foreground
        ForegroundPreemptionRequested,
      ]);

      fgGate.complete(1);
      expect(await fg, 1);
      await pumpEventQueue();

      // Foreground exits, then — the chain having drained — resume is signalled.
      expect(events[3], isA<RunSlotExited>());
      expect((events[3] as RunSlotExited).slot, RunSlot.foreground);
      expect(events[4], isA<BackgroundResumeSignalled>());

      bgGate.complete(2);
      expect(await bg, 2);
      await pumpEventQueue();
      expect((events.last as RunSlotExited).slot, RunSlot.background);
    });

    test('back-to-back foreground arrivals during one background run emit '
        'exactly one ForegroundPreemptionRequested and one '
        'BackgroundResumeSignalled', () async {
      final coordinator = build();
      final bgGate = Completer<int>();
      final fg1Gate = Completer<int>();
      final fg2Gate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      final fg2 = coordinator.submitForeground<int>(() => fg2Gate.future);
      await pumpEventQueue();

      // fg2 is queued (slot busy) so it has NOT entered a slot yet.
      expect(events.whereType<RunSlotEntered>(), hasLength(2),
          reason: 'background + fg1 entered; fg2 still queued');
      expect(events.whereType<ForegroundPreemptionRequested>(), hasLength(1),
          reason: 'the second arrival is idempotent — no extra request');

      fg1Gate.complete(1);
      expect(await fg1, 1);
      await pumpEventQueue();
      // fg1 exits, fg2 pumps in (enters); no resume yet (chain not drained).
      expect(events.whereType<RunSlotEntered>(), hasLength(3));
      expect(events.whereType<BackgroundResumeSignalled>(), isEmpty);

      fg2Gate.complete(2);
      expect(await fg2, 2);
      await pumpEventQueue();
      expect(events.whereType<BackgroundResumeSignalled>(), hasLength(1),
          reason: 'resume fires once, when the whole foreground chain drains');

      bgGate.complete(3);
      await pumpEventQueue();
    });

    test('a foreground run with no background live never requests preemption '
        'and never signals resume', () async {
      final coordinator = build();

      expect(await coordinator.submitForeground<int>(() async => 9), 9);
      await pumpEventQueue();

      expect(events.whereType<ForegroundPreemptionRequested>(), isEmpty);
      expect(events.whereType<BackgroundResumeSignalled>(), isEmpty);
      expect(events.map((e) => e.runtimeType),
          <Type>[RunSlotEntered, RunSlotExited]);
    });
  });

  group('D.24 — rejected and queued submissions emit nothing prematurely', () {
    test('a rejected concurrent background submission (RunSlotBusy) emits no '
        'event for the rejected run', () async {
      final coordinator = build();
      final gate = Completer<int>();

      coordinator.submitBackground<int>(() => gate.future);
      await pumpEventQueue();
      expect(events.whereType<RunSlotEntered>(), hasLength(1));

      expect(
        () => coordinator.submitBackground<int>(() async => 0),
        throwsA(isA<RunSlotBusy>()),
      );
      await pumpEventQueue();
      expect(events.whereType<RunSlotEntered>(), hasLength(1),
          reason: 'the rejected background run never entered a slot');

      gate.complete(1);
      await pumpEventQueue();
    });

    test('an overflowing foreground submission (ForegroundQueueFull) emits no '
        'RunSlotEntered for the rejected run', () async {
      // depth 0 → a busy foreground slot overflows immediately.
      final coordinator = build(foregroundQueueDepth: 0);
      final gate = Completer<int>();

      coordinator.submitForeground<int>(() => gate.future);
      await pumpEventQueue();
      expect(events.whereType<RunSlotEntered>(), hasLength(1));

      expect(
        () => coordinator.submitForeground<int>(() async => 0),
        throwsA(isA<ForegroundQueueFull>()),
      );
      await pumpEventQueue();
      expect(events.whereType<RunSlotEntered>(), hasLength(1),
          reason: 'the overflowed foreground run never entered a slot');

      gate.complete(1);
      await pumpEventQueue();
    });

    test('a queued foreground run emits RunSlotEntered only when it later '
        'occupies the freed slot, in FIFO order after the running run exits',
        () async {
      final coordinator = build();
      final gate1 = Completer<int>();
      final gate2 = Completer<int>();

      coordinator.submitForeground<int>(() => gate1.future);
      coordinator.submitForeground<int>(() => gate2.future);
      await pumpEventQueue();

      // Only the first foreground has entered; the second waits in the queue.
      expect(events.whereType<RunSlotEntered>(), hasLength(1));
      expect(coordinator.foregroundQueueLength, 1);

      gate1.complete(1);
      await pumpEventQueue();
      // First exits, then the queued second enters — in that order.
      expect(events.map((e) => e.runtimeType), <Type>[
        RunSlotEntered, // run 1 start
        RunSlotExited, // run 1 finish
        RunSlotEntered, // run 2 pumped in
      ]);

      gate2.complete(2);
      await pumpEventQueue();
    });
  });

  group('D.24 — observe-only and exposure invariants', () {
    test('preemptionEvents() surfaces the injected controller stream', () {
      final injected = PreemptionController();
      final coordinator =
          RunCoordinator(preemptionController: injected);
      // The coordinator exposes exactly the controller it was given.
      expect(coordinator.preemptionController, same(injected));
      injected.close();
    });

    test('a default-constructed coordinator still has a working controller and '
        'event stream', () async {
      final coordinator = RunCoordinator();
      final seen = <PreemptionEvent>[];
      final sub = coordinator.preemptionEvents().listen(seen.add);

      expect(await coordinator.submitForeground<int>(() async => 5), 5);
      await pumpEventQueue();
      expect(seen.map((e) => e.runtimeType),
          <Type>[RunSlotEntered, RunSlotExited]);

      await sub.cancel();
    });

    test('the coordinator never writes PreemptionState through the controller — '
        'the controller is observe-only', () async {
      final state = PreemptionState();
      final coordinator = build(preemption: state);
      final bgGate = Completer<int>();

      // A real preemption: the coordinator drives PreemptionState directly.
      coordinator.submitBackground<int>(() => bgGate.future);
      final fg = coordinator.submitForeground<int>(() async => 1);
      await fg;
      await pumpEventQueue();

      // The controller saw the transitions, but the canonical state object is
      // the coordinator's own writes — the controller never touched it.
      expect(events.whereType<ForegroundPreemptionRequested>(), hasLength(1));
      expect(events.whereType<BackgroundResumeSignalled>(), hasLength(1));
      // After the foreground drained, the coordinator signalled resume on the
      // real state, so no preemption is pending.
      expect(state.isForegroundWaiting, isFalse);

      bgGate.complete(2);
      await pumpEventQueue();
    });
  });
}
