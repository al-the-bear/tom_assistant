// Tests for `DispatcherEvent` + `DispatcherEventBus` (Plan step D.49).
//
// Covers:
//
//   - The seven variants named in the plan + spec § 13 (`AccessAccepted`,
//     `ProcedureSelected`, `ForegroundQueued`, `Preempted`, `Resumed`,
//     `RunCompleted`, `FallbackTried`) construct, carry their payloads,
//     and inherit the `BrainEvent` base.
//   - Each variant's `kind` discriminator is the canonical kebab-case
//     `dispatcher.<event-name>` string and is unique.
//   - `payloadJson()` emits exactly the subclass fields (no base fields),
//     omitting optional nulls; `toJson()` composes kind + base fields +
//     payload with the null-omission rule.
//   - `runId` is nullable on the base (access-scoped variants carry none)
//     but required + non-null on `RunCompleted`.
//   - `DispatcherEvent` is a closed sealed sum — an exhaustive `switch`
//     over the seven variants compiles without a default.
//   - `DispatcherEventBus` fans events out (broadcast), preserves emission
//     order, supports multiple subscribers, and closes cleanly.
//
// Drives the public API only — never imports `lib/src/…` directly;
// everything flows through the package barrel.

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// A fixed UTC timestamp the variant constructors share.
final DateTime _at = DateTime.utc(2026, 6, 2, 10, 30, 0);

/// Builds one of each variant (the canonical fixtures the suite reuses).
List<DispatcherEvent> _oneOfEach() => <DispatcherEvent>[
      AccessAccepted(
        occurredAt: _at,
        sessionId: 'sess_1',
        kindHint: 'user_prompt',
      ),
      ProcedureSelected(
        occurredAt: _at,
        inboundKind: 'user_prompt',
        procedureId: 'answer_with_memory_v1',
      ),
      ForegroundQueued(
        occurredAt: _at,
        queueDepth: 2,
      ),
      Preempted(
        occurredAt: _at,
        runId: 'run_bg',
        foregroundRunId: 'run_fg',
      ),
      Resumed(
        occurredAt: _at,
        runId: 'run_bg',
      ),
      RunCompleted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        outcome: RunOutcome.completed,
        slot: RunSlot.foreground,
      ),
      FallbackTried(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'answer_with_memory_v1',
        fromVersion: 1,
        toVersion: null,
        trigger: FallbackTrigger.runtimeCrash,
      ),
    ];

/// Exhaustive switch over the closed sum — its existence is the
/// compile-time guard that the sum stays closed at seven.
String _describe(DispatcherEvent event) => switch (event) {
      AccessAccepted() => 'accepted',
      ProcedureSelected() => 'selected',
      ForegroundQueued() => 'queued',
      Preempted() => 'preempted',
      Resumed() => 'resumed',
      RunCompleted() => 'completed',
      FallbackTried() => 'fallback',
    };

void main() {
  group('D.49-1: DispatcherEvent construction + base inheritance', () {
    test('every variant is a DispatcherEvent and a BrainEvent', () {
      for (final event in _oneOfEach()) {
        expect(event, isA<DispatcherEvent>());
        expect(event, isA<BrainEvent>());
      }
    });

    test('access-scoped variants carry no runId', () {
      expect(
        AccessAccepted(occurredAt: _at, sessionId: 's').runId,
        isNull,
      );
      expect(
        ProcedureSelected(
          occurredAt: _at,
          inboundKind: 'user_prompt',
          procedureId: 'p',
        ).runId,
        isNull,
      );
      expect(
        ForegroundQueued(occurredAt: _at, queueDepth: 1).runId,
        isNull,
      );
    });

    test('RunCompleted requires + exposes a non-null runId', () {
      final event = RunCompleted(
        occurredAt: _at,
        runId: 'run_1',
        procedureId: 'p',
        outcome: RunOutcome.failed,
        slot: RunSlot.background,
      );
      expect(event.runId, 'run_1');
    });

    test('occurredAt + causedBy pass through the base', () {
      final event = AccessAccepted(
        occurredAt: _at,
        causedBy: 'ev_0',
        sessionId: 's',
      );
      expect(event.occurredAt, _at);
      expect(event.causedBy, 'ev_0');
    });
  });

  group('D.49-2: kind discriminators (spec § 13, kebab-case)', () {
    test('each variant carries its canonical dispatcher.<name> kind', () {
      final kinds = <Type, String>{
        AccessAccepted: 'dispatcher.access-accepted',
        ProcedureSelected: 'dispatcher.procedure-selected',
        ForegroundQueued: 'dispatcher.foreground-queued',
        Preempted: 'dispatcher.preempted',
        Resumed: 'dispatcher.resumed',
        RunCompleted: 'dispatcher.run-completed',
        FallbackTried: 'dispatcher.fallback-tried',
      };
      for (final event in _oneOfEach()) {
        expect(event.kind, kinds[event.runtimeType]);
      }
    });

    test('every kind is unique', () {
      final kinds = _oneOfEach().map((e) => e.kind).toSet();
      expect(kinds, hasLength(7));
    });
  });

  group('D.49-3: payloadJson', () {
    test('AccessAccepted carries sessionId + omits null kindHint', () {
      expect(
        AccessAccepted(occurredAt: _at, sessionId: 'sess_1').payloadJson(),
        <String, Object?>{'sessionId': 'sess_1'},
      );
      expect(
        AccessAccepted(
          occurredAt: _at,
          sessionId: 'sess_1',
          kindHint: 'user_prompt',
        ).payloadJson(),
        <String, Object?>{'sessionId': 'sess_1', 'kindHint': 'user_prompt'},
      );
    });

    test('ProcedureSelected carries inboundKind + procedureId', () {
      expect(
        ProcedureSelected(
          occurredAt: _at,
          inboundKind: 'user_prompt',
          procedureId: 'answer_with_memory_v1',
        ).payloadJson(),
        <String, Object?>{
          'inboundKind': 'user_prompt',
          'procedureId': 'answer_with_memory_v1',
        },
      );
    });

    test('ForegroundQueued carries queueDepth', () {
      expect(
        ForegroundQueued(occurredAt: _at, queueDepth: 3).payloadJson(),
        <String, Object?>{'queueDepth': 3},
      );
    });

    test('Preempted omits null foregroundRunId', () {
      expect(
        Preempted(occurredAt: _at, runId: 'run_bg').payloadJson(),
        const <String, Object?>{},
      );
      expect(
        Preempted(
          occurredAt: _at,
          runId: 'run_bg',
          foregroundRunId: 'run_fg',
        ).payloadJson(),
        <String, Object?>{'foregroundRunId': 'run_fg'},
      );
    });

    test('Resumed has an empty payload', () {
      expect(
        Resumed(occurredAt: _at, runId: 'run_bg').payloadJson(),
        const <String, Object?>{},
      );
    });

    test('RunCompleted serialises outcome.status + slot.name', () {
      expect(
        RunCompleted(
          occurredAt: _at,
          runId: 'run_1',
          procedureId: 'p',
          outcome: RunOutcome.forceYielded,
          slot: RunSlot.background,
        ).payloadJson(),
        <String, Object?>{
          'procedureId': 'p',
          'outcome': 'force_yielded',
          'slot': 'background',
        },
      );
    });

    test('FallbackTried emits trigger.failureKind + surfaced; omits null '
        'toVersion', () {
      final surfaced = FallbackTried(
        occurredAt: _at,
        procedureId: 'p',
        fromVersion: 1,
        toVersion: null,
        trigger: FallbackTrigger.runtimeCrash,
      );
      expect(surfaced.surfaced, isTrue);
      expect(surfaced.payloadJson(), <String, Object?>{
        'procedureId': 'p',
        'fromVersion': 1,
        'trigger': 'procedure.runtime.crash',
        'surfaced': true,
      });

      final stepped = FallbackTried(
        occurredAt: _at,
        procedureId: 'p',
        fromVersion: 3,
        toVersion: 2,
        trigger: FallbackTrigger.contractViolation,
      );
      expect(stepped.surfaced, isFalse);
      expect(stepped.payloadJson()['toVersion'], 2);
      expect(stepped.payloadJson()['surfaced'], false);
    });
  });

  group('D.49-5: toJson (base composes kind + fields + payload)', () {
    test('full event serialises with runId, causedBy, and payload', () {
      final event = RunCompleted(
        occurredAt: _at,
        runId: 'run_1',
        causedBy: 'ev_0',
        procedureId: 'answer_with_memory_v1',
        outcome: RunOutcome.completed,
        slot: RunSlot.foreground,
      );
      expect(event.toJson(), <String, Object?>{
        'kind': 'dispatcher.run-completed',
        'occurredAt': _at.toIso8601String(),
        'runId': 'run_1',
        'causedBy': 'ev_0',
        'payload': <String, Object?>{
          'procedureId': 'answer_with_memory_v1',
          'outcome': 'completed',
          'slot': 'foreground',
        },
      });
    });

    test('access-scoped toJson omits both runId and causedBy', () {
      final json = AccessAccepted(occurredAt: _at, sessionId: 's').toJson();
      expect(json.containsKey('runId'), isFalse);
      expect(json.containsKey('causedBy'), isFalse);
      expect(json['kind'], 'dispatcher.access-accepted');
    });
  });

  group('D.49-6: closed sealed sum (drift guard)', () {
    test('exhaustive switch maps each variant', () {
      final described = _oneOfEach().map(_describe).toList();
      expect(described, <String>[
        'accepted',
        'selected',
        'queued',
        'preempted',
        'resumed',
        'completed',
        'fallback',
      ]);
    });
  });

  group('D.49-7: DispatcherEventBus', () {
    test('events() delivers emissions in order to a subscriber', () async {
      final bus = DispatcherEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));

      for (final event in _oneOfEach()) {
        bus.emit(event);
      }
      await bus.close();
      await sub.cancel();

      expect(received, <String>[
        'dispatcher.access-accepted',
        'dispatcher.procedure-selected',
        'dispatcher.foreground-queued',
        'dispatcher.preempted',
        'dispatcher.resumed',
        'dispatcher.run-completed',
        'dispatcher.fallback-tried',
      ]);
    });

    test('is broadcast — multiple subscribers each see every event',
        () async {
      final bus = DispatcherEventBus();
      final a = <String>[];
      final b = <String>[];
      final subA = bus.events().listen((e) => a.add(e.kind));
      final subB = bus.events().listen((e) => b.add(e.kind));

      bus.emit(Resumed(occurredAt: _at, runId: 'run_bg'));
      await bus.close();
      await subA.cancel();
      await subB.cancel();

      expect(a, <String>['dispatcher.resumed']);
      expect(b, <String>['dispatcher.resumed']);
    });

    test('emit after close throws StateError', () async {
      final bus = DispatcherEventBus();
      await bus.close();
      expect(bus.isClosed, isTrue);
      expect(
        () => bus.emit(Resumed(occurredAt: _at, runId: 'run_bg')),
        throwsStateError,
      );
    });

    test('close is idempotent', () async {
      final bus = DispatcherEventBus();
      await bus.close();
      await bus.close();
      expect(bus.isClosed, isTrue);
    });

    test('a late subscriber on a closed bus receives a done-stream',
        () async {
      final bus = DispatcherEventBus();
      await bus.close();
      expect(bus.events().isEmpty, completion(isTrue));
    });
  });
}
