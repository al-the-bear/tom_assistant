// Preemption event-transition matrix (Plan step D.25;
// `tom_brain_procedure_prototype_specification.md` § 10.3, PE-5, § 14;
// `tom_brain_definition.md` § 7.1, § 14.10).
//
// D.23 shipped the `PreemptionController` standalone; D.24 wired the
// `RunCoordinator` to drive its `record*` surface at each transition point and
// shipped a focused wiring suite. D.25 is the *exhaustive* transition matrix:
// it proves that **every** observable coordinator transition emits the matching
// `PreemptionEvent`, driven end-to-end through the live coordinator's own
// submission surface (`submitForeground` / `submitBackground`) — never by
// poking the controller directly.
//
// The closed event taxonomy and the transitions that produce each event:
//
//   - RunSlotEntered                — a run begins occupying a slot. Entry
//     paths: foreground-immediate, foreground-pumped-from-queue, background.
//   - RunSlotExited(outcome)        — a run leaves its slot. The full
//     (slot × outcome) matrix: {foreground, background} × {completed, failed,
//     forceYielded} = six cells, each exercised here.
//   - ForegroundPreemptionRequested — the false→true edge of the preemption-
//     pending model (a foreground arrival while a background run is live).
//   - BackgroundResumeSignalled     — the true→false edge (the foreground
//     chain fully drained while a preemption was pending).
//
// On top of the matrix this suite pins the cross-cutting contracts each event
// must satisfy when emitted through the live coordinator: the kebab-case
// `kind` discriminator, the `payloadJson()` shape, the UTC `occurredAt` stamp
// (via an injected deterministic clock), the nullable `runId` (still null in
// the prototype — D.26 assigns ids), and the stream ordering invariants
// (enter-before-its-own-exit, exit-before-a-successor's-enter, and the
// background bracketing a preempting foreground chain).
//
// The two force-yield cells use an injected `_FakeTimer` (the C.36 / D.21 /
// D.22 / D.24 seam) so truncation is deterministic; every other case runs
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
/// [fire]. Identical in spirit to the D.21 / D.22 / D.24 doubles.
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
  // A frozen UTC clock so every emitted event carries a deterministic,
  // assertable `occurredAt`. Injected into the controller the coordinator
  // drives, so we test the timestamp the *live* path stamps.
  final frozenNow = DateTime.utc(2026, 6, 2, 9, 30, 15, 250);

  // Events the controller emits, captured in stream order so a test can assert
  // the exact transition sequence the coordinator drove.
  late List<PreemptionEvent> events;
  late PreemptionController controller;
  late StreamSubscription<PreemptionEvent> subscription;

  setUp(() {
    controller = PreemptionController(clock: () => frozenNow);
    events = <PreemptionEvent>[];
  });

  tearDown(() async {
    await subscription.cancel();
    await controller.close();
  });

  /// Builds a coordinator over the shared [controller] (and optional
  /// [preemption]), wiring a fake-timer factory so deadline-driven cells can
  /// fire deterministically, and subscribes to `preemptionEvents()` into
  /// [events]. Subscribing before any submission means no transition is missed.
  ///
  /// [timers] collects every per-run `StepDeadline` timer the coordinator
  /// builds, so a force-yield test can `fire()` the relevant one.
  RunCoordinator build({
    PreemptionState? preemption,
    int foregroundQueueDepth = 4,
    List<_FakeTimer>? timers,
  }) {
    final coordinator = RunCoordinator(
      preemption: preemption,
      preemptionController: controller,
      foregroundQueueDepth: foregroundQueueDepth,
      deadlineTimerFactory: timers == null
          ? null
          : (duration, onExpire) {
              final timer = _FakeTimer(duration, onExpire);
              timers.add(timer);
              return timer;
            },
    );
    subscription = coordinator.preemptionEvents().listen(events.add);
    return coordinator;
  }

  group('D.25 — RunSlotEntered for every entry path', () {
    test('a foreground submission into a free slot enters immediately',
        () async {
      final coordinator = build();
      final gate = Completer<int>();

      coordinator.submitForeground<int>(() => gate.future);
      await pumpEventQueue();

      final entered = events.single as RunSlotEntered;
      expect(entered.slot, RunSlot.foreground);

      gate.complete(0);
      await pumpEventQueue();
    });

    test('a background submission enters the background slot', () async {
      final coordinator = build();
      final gate = Completer<int>();

      coordinator.submitBackground<int>(() => gate.future);
      await pumpEventQueue();

      final entered = events.single as RunSlotEntered;
      expect(entered.slot, RunSlot.background);

      gate.complete(0);
      await pumpEventQueue();
    });

    test('a queued foreground run enters only when pumped into the freed slot',
        () async {
      final coordinator = build();
      final gate1 = Completer<int>();
      final gate2 = Completer<int>();

      coordinator.submitForeground<int>(() => gate1.future);
      coordinator.submitForeground<int>(() => gate2.future);
      await pumpEventQueue();

      // Only the first has entered; the second waits in the FIFO queue.
      expect(events.whereType<RunSlotEntered>(), hasLength(1));
      expect(coordinator.foregroundQueueLength, 1);

      gate1.complete(1);
      await pumpEventQueue();

      // The pumped second run entered, in the foreground slot.
      final enters = events.whereType<RunSlotEntered>().toList();
      expect(enters, hasLength(2));
      expect(enters.every((e) => e.slot == RunSlot.foreground), isTrue);

      gate2.complete(2);
      await pumpEventQueue();
    });

    test('RunSlotEntered carries the kebab-case kind and slot-only payload',
        () async {
      final coordinator = build();
      final gate = Completer<int>();

      coordinator.submitBackground<int>(() => gate.future);
      await pumpEventQueue();

      final entered = events.single as RunSlotEntered;
      expect(entered.kind, 'dispatcher.run-slot-entered');
      expect(entered.payloadJson(), <String, Object?>{'slot': 'background'});

      gate.complete(0);
      await pumpEventQueue();
    });
  });

  group('D.25 — RunSlotExited (slot × outcome) full matrix', () {
    // The six cells of {foreground, background} × {completed, failed,
    // forceYielded}. Each asserts the exiting slot and the mapped outcome.

    test('foreground × completed', () async {
      final coordinator = build();
      final run = coordinator.submitForeground<int>(() async => 7);
      expect(await run, 7);
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.foreground);
      expect(exited.outcome, RunSlotOutcome.completed);
    });

    test('foreground × failed', () async {
      final coordinator = build();
      await expectLater(
        coordinator.submitForeground<int>(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.foreground);
      expect(exited.outcome, RunSlotOutcome.failed);
    });

    test('foreground × forceYielded', () async {
      final timers = <_FakeTimer>[];
      final coordinator = build(timers: timers);

      final run =
          coordinator.submitForeground<int>(() => Completer<int>().future);
      await pumpEventQueue();
      expect(events.single, isA<RunSlotEntered>());

      timers.single.fire();
      await expectLater(run, throwsA(anything));
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.foreground);
      expect(exited.outcome, RunSlotOutcome.forceYielded);
    });

    test('background × completed', () async {
      final coordinator = build();
      final run = coordinator.submitBackground<int>(() async => 3);
      expect(await run, 3);
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.background);
      expect(exited.outcome, RunSlotOutcome.completed);
    });

    test('background × failed', () async {
      final coordinator = build();
      await expectLater(
        coordinator.submitBackground<int>(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.background);
      expect(exited.outcome, RunSlotOutcome.failed);
    });

    test('background × forceYielded', () async {
      final timers = <_FakeTimer>[];
      final coordinator = build(timers: timers);

      final run =
          coordinator.submitBackground<int>(() => Completer<int>().future);
      await pumpEventQueue();
      expect(events.single, isA<RunSlotEntered>());

      timers.single.fire();
      await expectLater(run, throwsA(anything));
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.slot, RunSlot.background);
      expect(exited.outcome, RunSlotOutcome.forceYielded);
    });

    test('RunSlotExited carries the kebab-case kind and slot+outcome payload',
        () async {
      final coordinator = build();
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      final exited = events.whereType<RunSlotExited>().single;
      expect(exited.kind, 'dispatcher.run-slot-exited');
      expect(exited.payloadJson(), <String, Object?>{
        'slot': 'foreground',
        'outcome': 'completed',
      });
    });
  });

  group('D.25 — ForegroundPreemptionRequested transition edge', () {
    test('emitted exactly once on the false→true edge (bg live + fg arrival)',
        () async {
      final coordinator = build();
      final bgGate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      final fg = coordinator.submitForeground<int>(() async => 1);
      await fg;
      await pumpEventQueue();

      expect(events.whereType<ForegroundPreemptionRequested>(), hasLength(1));

      bgGate.complete(0);
      await pumpEventQueue();
    });

    test('not emitted when no background run is live (no edge crossed)',
        () async {
      final coordinator = build();

      await coordinator.submitForeground<int>(() async => 9);
      await pumpEventQueue();

      expect(events.whereType<ForegroundPreemptionRequested>(), isEmpty);
    });

    test('idempotent: back-to-back foreground arrivals emit exactly one',
        () async {
      final coordinator = build();
      final bgGate = Completer<int>();
      final fg1Gate = Completer<int>();
      final fg2Gate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      coordinator.submitForeground<int>(() => fg1Gate.future);
      coordinator.submitForeground<int>(() => fg2Gate.future);
      await pumpEventQueue();

      expect(events.whereType<ForegroundPreemptionRequested>(), hasLength(1),
          reason: 'the second arrival is a no-op on the pending model');

      fg1Gate.complete(1);
      await pumpEventQueue();
      fg2Gate.complete(2);
      await pumpEventQueue();
      bgGate.complete(3);
      await pumpEventQueue();
    });

    test('carries the kebab-case kind and an empty payload', () async {
      final coordinator = build();
      final bgGate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      final requested =
          events.whereType<ForegroundPreemptionRequested>().single;
      expect(requested.kind, 'dispatcher.foreground-preemption-requested');
      expect(requested.payloadJson(), isEmpty);

      bgGate.complete(0);
      await pumpEventQueue();
    });
  });

  group('D.25 — BackgroundResumeSignalled transition edge', () {
    test('emitted exactly once on the true→false edge (foreground drains)',
        () async {
      final coordinator = build();
      final bgGate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      expect(events.whereType<BackgroundResumeSignalled>(), hasLength(1));

      bgGate.complete(0);
      await pumpEventQueue();
    });

    test('not emitted when nothing is pending (foreground with no background)',
        () async {
      final coordinator = build();

      await coordinator.submitForeground<int>(() async => 9);
      await pumpEventQueue();

      expect(events.whereType<BackgroundResumeSignalled>(), isEmpty);
    });

    test('idempotent: a draining foreground chain emits exactly one', () async {
      final coordinator = build();
      final bgGate = Completer<int>();
      final fg1Gate = Completer<int>();
      final fg2Gate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      final fg1 = coordinator.submitForeground<int>(() => fg1Gate.future);
      final fg2 = coordinator.submitForeground<int>(() => fg2Gate.future);
      await pumpEventQueue();

      // First run finishes, second pumps in: chain not yet drained.
      fg1Gate.complete(1);
      expect(await fg1, 1);
      await pumpEventQueue();
      expect(events.whereType<BackgroundResumeSignalled>(), isEmpty,
          reason: 'a successor is still in the slot; the chain is not drained');

      fg2Gate.complete(2);
      expect(await fg2, 2);
      await pumpEventQueue();
      expect(events.whereType<BackgroundResumeSignalled>(), hasLength(1),
          reason: 'resume fires once, when the whole chain drains');

      bgGate.complete(3);
      await pumpEventQueue();
    });

    test('carries the kebab-case kind and an empty payload', () async {
      final coordinator = build();
      final bgGate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      final resumed = events.whereType<BackgroundResumeSignalled>().single;
      expect(resumed.kind, 'dispatcher.background-resume-signalled');
      expect(resumed.payloadJson(), isEmpty);

      bgGate.complete(0);
      await pumpEventQueue();
    });
  });

  group('D.25 — event base fields through the live coordinator', () {
    test('every emitted event stamps the injected UTC clock onto occurredAt',
        () async {
      final coordinator = build();
      final bgGate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();
      bgGate.complete(0);
      await pumpEventQueue();

      expect(events, isNotEmpty);
      for (final event in events) {
        expect(event.occurredAt, frozenNow);
        expect(event.occurredAt.isUtc, isTrue);
      }
    });

    test('runId stays null in the prototype (D.26 assigns ids)', () async {
      final coordinator = build();
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      for (final event in events) {
        expect(event.runId, isNull);
      }
    });

    test('each variant serialises to its kind + payload via toJson', () async {
      final coordinator = build();
      final bgGate = Completer<int>();

      coordinator.submitBackground<int>(() => bgGate.future);
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();
      bgGate.complete(0);
      await pumpEventQueue();

      // One of each of the four variants is present across this scenario.
      final entered = events.whereType<RunSlotEntered>().first.toJson();
      expect(entered['kind'], 'dispatcher.run-slot-entered');
      expect(entered['occurredAt'], frozenNow.toIso8601String());
      expect(entered.containsKey('runId'), isFalse,
          reason: 'null runId is omitted from the wire shape');
      expect(entered['payload'], isA<Map<String, Object?>>());

      final exited = events.whereType<RunSlotExited>().first.toJson();
      expect(exited['kind'], 'dispatcher.run-slot-exited');

      final requested =
          events.whereType<ForegroundPreemptionRequested>().single.toJson();
      expect(requested['kind'], 'dispatcher.foreground-preemption-requested');
      expect(requested['payload'], isEmpty);

      final resumed =
          events.whereType<BackgroundResumeSignalled>().single.toJson();
      expect(resumed['kind'], 'dispatcher.background-resume-signalled');
      expect(resumed['payload'], isEmpty);
    });
  });

  group('D.25 — stream ordering invariants', () {
    test('a single run emits enter strictly before its own exit', () async {
      final coordinator = build();
      await coordinator.submitForeground<int>(() async => 1);
      await pumpEventQueue();

      expect(events.map((e) => e.runtimeType),
          <Type>[RunSlotEntered, RunSlotExited]);
    });

    test('a queued successor enters strictly after the running run exits',
        () async {
      final coordinator = build();
      final gate1 = Completer<int>();
      final gate2 = Completer<int>();

      coordinator.submitForeground<int>(() => gate1.future);
      coordinator.submitForeground<int>(() => gate2.future);
      await pumpEventQueue();

      gate1.complete(1);
      await pumpEventQueue();

      expect(events.map((e) => e.runtimeType), <Type>[
        RunSlotEntered, // run 1 start
        RunSlotExited, // run 1 finish
        RunSlotEntered, // run 2 pumped in only after run 1 exited
      ]);

      gate2.complete(2);
      await pumpEventQueue();
    });

    test('the background brackets a preempting foreground chain in stream order',
        () async {
      final coordinator = build();
      final bgGate = Completer<int>();
      final fgGate = Completer<int>();

      final bg = coordinator.submitBackground<int>(() => bgGate.future);
      final fg = coordinator.submitForeground<int>(() => fgGate.future);
      await pumpEventQueue();

      // bg enters, fg enters, then the preemption request, in that order.
      expect(events.map((e) => e.runtimeType), <Type>[
        RunSlotEntered,
        RunSlotEntered,
        ForegroundPreemptionRequested,
      ]);

      fgGate.complete(1);
      expect(await fg, 1);
      await pumpEventQueue();

      // fg exits, then resume is signalled — the chain has drained.
      expect(events[3], isA<RunSlotExited>());
      expect((events[3] as RunSlotExited).slot, RunSlot.foreground);
      expect(events[4], isA<BackgroundResumeSignalled>());

      bgGate.complete(2);
      expect(await bg, 2);
      await pumpEventQueue();

      // Finally the background exits — closing the bracket.
      expect((events.last as RunSlotExited).slot, RunSlot.background);
    });
  });

  group('D.25 — non-transitions emit nothing', () {
    test('a rejected concurrent background (RunSlotBusy) emits no entry',
        () async {
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

    test('an overflowing foreground (ForegroundQueueFull) emits no entry',
        () async {
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
  });
}
