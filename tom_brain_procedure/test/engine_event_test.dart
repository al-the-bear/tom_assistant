// Tests for `EngineEvent` + `EngineEventBus` (Plan step C.44).
//
// Covers:
//
//   - The five variants named in the plan + spec § 13
//     (`InvocationStarted`, `PrimitiveCalled`, `StepYielded`,
//     `InvocationCompleted`, `InvocationFailed`) construct, carry their
//     payloads, and inherit the `BrainEvent` base.
//   - Each variant's `kind` discriminator is the canonical kebab-case
//     `engine.<event-name>` string and is stable.
//   - `payloadJson()` emits exactly the subclass fields (no base fields),
//     omitting optional nulls, and `toJson()` composes kind + base
//     fields + payload with the null-omission rule.
//   - The `runId`-required narrowing: every engine event has a non-null
//     `runId` by construction.
//   - `EngineEvent` is a closed sealed sum — an exhaustive `switch` over
//     the five variants compiles without a default.
//   - `EngineEventBus` fans events out (broadcast), preserves emission
//     order, supports multiple subscribers, and closes cleanly
//     (`emit`-after-close throws, late subscribers get a done-stream).
//
// Drives the public API only — never imports `lib/src/config/…`
// directly; everything flows through the package barrel.

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TrailOutcomeStatus;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// A fixed UTC timestamp the variant constructors share.
final DateTime _at = DateTime.utc(2026, 6, 2, 10, 30, 0);

/// Builds one of each variant (the canonical fixtures the suite reuses).
List<EngineEvent> _oneOfEach() => <EngineEvent>[
      InvocationStarted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        version: 1,
        parentRunId: 'run_0',
        depth: 2,
      ),
      PrimitiveCalled(
        occurredAt: _at,
        runId: 'run_1',
        primitive: 'note',
        depth: 1,
      ),
      StepYielded(
        occurredAt: _at,
        runId: 'run_1',
        reason: StepYielded.deadlineReason,
        truncated: true,
      ),
      InvocationCompleted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        status: TrailOutcomeStatus.accepted,
        summary: 'ran to completion',
      ),
      InvocationFailed(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        failureKind: 'procedure.runtime.crash',
        message: 'boom',
      ),
    ];

/// Exhaustive switch over the closed sum — its existence is the
/// compile-time guard that the sum stays closed at five.
String _describe(EngineEvent event) => switch (event) {
      InvocationStarted() => 'started',
      PrimitiveCalled() => 'primitive',
      StepYielded() => 'yielded',
      InvocationCompleted() => 'completed',
      InvocationFailed() => 'failed',
    };

void main() {
  group('C.44-1: EngineEvent construction + base inheritance', () {
    test('every variant is an EngineEvent and a BrainEvent', () {
      for (final event in _oneOfEach()) {
        expect(event, isA<EngineEvent>());
      }
    });

    test('runId is required and non-null on every variant', () {
      for (final event in _oneOfEach()) {
        expect(event.runId, 'run_1');
      }
    });

    test('occurredAt + causedBy pass through the base', () {
      final event = InvocationStarted(
        occurredAt: _at,
        runId: 'run_1',
        causedBy: 'ev_0',
        procedureId: 'p',
        depth: 1,
      );
      expect(event.occurredAt, _at);
      expect(event.causedBy, 'ev_0');
    });
  });

  group('C.44-2: kind discriminators (spec § 13, kebab-case)', () {
    test('each variant carries its canonical engine.<name> kind', () {
      final kinds = <Type, String>{
        InvocationStarted: 'engine.invocation-started',
        PrimitiveCalled: 'engine.primitive-called',
        StepYielded: 'engine.step-yielded',
        InvocationCompleted: 'engine.invocation-completed',
        InvocationFailed: 'engine.invocation-failed',
      };
      for (final event in _oneOfEach()) {
        expect(event.kind, kinds[event.runtimeType]);
      }
    });

    test('every kind is unique', () {
      final kinds = _oneOfEach().map((e) => e.kind).toSet();
      expect(kinds, hasLength(5));
    });
  });

  group('C.44-3: payloadJson', () {
    test('InvocationStarted carries its full payload', () {
      final event = InvocationStarted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        version: 3,
        parentRunId: 'run_0',
        depth: 2,
      );
      expect(event.payloadJson(), <String, Object?>{
        'procedureId': 'answer_with_memory_v1',
        'version': 3,
        'parentRunId': 'run_0',
        'depth': 2,
      });
    });

    test('InvocationStarted omits null version + parentRunId', () {
      final event = InvocationStarted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'p',
        depth: 1,
      );
      expect(event.payloadJson(), <String, Object?>{
        'procedureId': 'p',
        'depth': 1,
      });
    });

    test('PrimitiveCalled carries primitive + depth', () {
      final event = PrimitiveCalled(
        occurredAt: _at,
        runId: 'run_1',
        primitive: 'runProcedure',
        depth: 4,
      );
      expect(event.payloadJson(), <String, Object?>{
        'primitive': 'runProcedure',
        'depth': 4,
      });
    });

    test('StepYielded carries reason + truncated', () {
      final cooperative = StepYielded(
        occurredAt: _at,
        runId: 'run_1',
        reason: StepYielded.foregroundWaitingReason,
        truncated: false,
      );
      expect(cooperative.payloadJson(), <String, Object?>{
        'reason': 'foreground_waiting',
        'truncated': false,
      });
    });

    test('InvocationCompleted emits status.name + omits null summary', () {
      final event = InvocationCompleted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'p',
        status: TrailOutcomeStatus.preempted,
      );
      expect(event.payloadJson(), <String, Object?>{
        'procedureId': 'p',
        'status': 'preempted',
      });
    });

    test('InvocationFailed carries failureKind + message', () {
      final event = InvocationFailed(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'p',
        failureKind: 'procedure.runtime.crash',
        message: 'boom',
      );
      expect(event.payloadJson(), <String, Object?>{
        'procedureId': 'p',
        'failureKind': 'procedure.runtime.crash',
        'message': 'boom',
      });
    });
  });

  group('C.44-4: toJson (base composes kind + fields + payload)', () {
    test('full event serialises with runId, causedBy, and payload', () {
      final event = InvocationCompleted(
        occurredAt: _at,
        runId: 'run_1',
        causedBy: 'ev_0',
        procedureId: 'answer_with_memory_v1',
        status: TrailOutcomeStatus.accepted,
        summary: 'done',
      );
      expect(event.toJson(), <String, Object?>{
        'kind': 'engine.invocation-completed',
        'occurredAt': _at.toIso8601String(),
        'runId': 'run_1',
        'causedBy': 'ev_0',
        'payload': <String, Object?>{
          'procedureId': 'answer_with_memory_v1',
          'status': 'accepted',
          'summary': 'done',
        },
      });
    });

    test('toJson omits null causedBy but always keeps runId', () {
      final event = PrimitiveCalled(
        occurredAt: _at,
        runId: 'run_1',
        primitive: 'note',
        depth: 1,
      );
      final json = event.toJson();
      expect(json.containsKey('causedBy'), isFalse);
      expect(json['runId'], 'run_1');
    });
  });

  group('C.44-5: closed sealed sum (drift guard)', () {
    test('exhaustive switch maps each variant', () {
      final described = _oneOfEach().map(_describe).toList();
      expect(described,
          <String>['started', 'primitive', 'yielded', 'completed', 'failed']);
    });
  });

  group('C.44-6: EngineEventBus', () {
    test('events() delivers emissions in order to a subscriber', () async {
      final bus = EngineEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));

      for (final event in _oneOfEach()) {
        bus.emit(event);
      }
      await bus.close();
      await sub.cancel();

      expect(received, <String>[
        'engine.invocation-started',
        'engine.primitive-called',
        'engine.step-yielded',
        'engine.invocation-completed',
        'engine.invocation-failed',
      ]);
    });

    test('is broadcast — multiple subscribers each see every event',
        () async {
      final bus = EngineEventBus();
      final a = <String>[];
      final b = <String>[];
      final subA = bus.events().listen((e) => a.add(e.kind));
      final subB = bus.events().listen((e) => b.add(e.kind));

      bus.emit(
        PrimitiveCalled(
          occurredAt: _at,
          runId: 'run_1',
          primitive: 'note',
          depth: 1,
        ),
      );
      await bus.close();
      await subA.cancel();
      await subB.cancel();

      expect(a, <String>['engine.primitive-called']);
      expect(b, <String>['engine.primitive-called']);
    });

    test('emit after close throws StateError', () async {
      final bus = EngineEventBus();
      await bus.close();
      expect(bus.isClosed, isTrue);
      expect(
        () => bus.emit(
          PrimitiveCalled(
            occurredAt: _at,
            runId: 'run_1',
            primitive: 'note',
            depth: 1,
          ),
        ),
        throwsStateError,
      );
    });

    test('close is idempotent', () async {
      final bus = EngineEventBus();
      await bus.close();
      await bus.close();
      expect(bus.isClosed, isTrue);
    });

    test('a late subscriber on a closed bus receives a done-stream',
        () async {
      final bus = EngineEventBus();
      await bus.close();
      expect(bus.events().isEmpty, completion(isTrue));
    });
  });
}
