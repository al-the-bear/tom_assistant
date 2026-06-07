// Extension F step 16 — `LlmLoopEvent` + `LlmLoopEventBus` *type surface*
// (`prototype_tools_mcp_extension_plan.md` step 16;
// `tom_brain_procedure_prototype_specification.md` § 13, § 21.1, § 21.7).
//
// ── Why this suite asserts the surface, not emission ────────────────
//
// Step 16 owns § 13's *type contract* for the scripted-LLM-loop observability
// stream: the five typed variants, their kinds, payloads, narrowed `runId`,
// and the bus. The plan's `Verify` sub-item — "the `call_llm_v1` loop test
// asserts the `LlmLoopEvent` sequence" — is structurally gated on the
// `call_llm_v1` loop, which does not exist yet (it is built in plan steps
// 11–12, currently paused on the § 21.7 assembly clarification). When the loop
// lands it takes an `LlmLoopEventSink` and emits this sequence per turn; the
// sequence-assertion test rides with it. This mirrors how steps 6/8 deferred
// *their* observability into step 16. See `lib/src/config/llm_event.dart`'s
// header for the same note.
//
// What this suite locks now:
//
//   - The five variants construct, carry their payloads, inherit
//     `BrainEvent`, and carry the canonical kebab-case `llm-loop.<name>` kind.
//   - `runId` is *narrowed to required non-null* (unlike tool / MCP events).
//   - `payloadJson()` / `toJson()` compose correctly.
//   - `LlmLoopEvent` is a closed sealed sum (exhaustive switch compiles).
//   - `LlmLoopEventBus` fans events out (broadcast, ordered, closes cleanly)
//     and delivers a representative full-turn sequence — the shape the
//     `call_llm_v1` loop will emit once it ships.
//
// Drives the public package barrel only.

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// A fixed UTC timestamp the variant constructors share.
final DateTime _at = DateTime.utc(2026, 6, 7, 12, 0, 0);

/// The run id every loop event carries (required, non-null).
const String _runId = 'run_llm_1';

/// Builds one of each variant (the canonical fixtures the suite reuses).
List<LlmLoopEvent> _oneOfEach() => <LlmLoopEvent>[
      LlmLoopStarted(
          occurredAt: _at, runId: _runId, promptType: 'assistant', maxTurns: 4),
      LlmLoopTurn(occurredAt: _at, runId: _runId, turn: 1),
      ToolTurnDispatched(
          occurredAt: _at, runId: _runId, turn: 1, tool: 'memory.recall'),
      LlmLoopCompleted(occurredAt: _at, runId: _runId, turns: 2),
      LlmLoopBudgetExceeded(
          occurredAt: _at, runId: _runId, dimension: 'llmTurns', turn: 4),
    ];

/// Exhaustive switch over the closed sum — the compile-time drift guard.
String _describe(LlmLoopEvent event) => switch (event) {
      LlmLoopStarted() => 'started',
      LlmLoopTurn() => 'turn',
      ToolTurnDispatched() => 'tool-turn',
      LlmLoopCompleted() => 'completed',
      LlmLoopBudgetExceeded() => 'budget-exceeded',
    };

void main() {
  group('F.16-llm-1: construction + narrowed runId', () {
    test('every variant is an LlmLoopEvent and a BrainEvent', () {
      for (final event in _oneOfEach()) {
        expect(event, isA<LlmLoopEvent>());
        expect(event, isA<BrainEvent>());
      }
    });

    test('runId is required non-null on every variant', () {
      for (final event in _oneOfEach()) {
        expect(event.runId, _runId);
      }
    });

    test('occurredAt + causedBy pass through the base', () {
      final event = LlmLoopTurn(
        occurredAt: _at,
        runId: _runId,
        causedBy: 'ev_0',
        turn: 3,
      );
      expect(event.occurredAt, _at);
      expect(event.causedBy, 'ev_0');
    });
  });

  group('F.16-llm-2: kind discriminators (kebab-case)', () {
    test('each variant carries its canonical llm-loop.<name> kind', () {
      final kinds = <Type, String>{
        LlmLoopStarted: 'llm-loop.started',
        LlmLoopTurn: 'llm-loop.turn',
        ToolTurnDispatched: 'llm-loop.tool-turn-dispatched',
        LlmLoopCompleted: 'llm-loop.completed',
        LlmLoopBudgetExceeded: 'llm-loop.budget-exceeded',
      };
      for (final event in _oneOfEach()) {
        expect(event.kind, kinds[event.runtimeType]);
      }
    });

    test('every kind is unique', () {
      expect(_oneOfEach().map((e) => e.kind).toSet(), hasLength(5));
    });
  });

  group('F.16-llm-3: payloadJson + toJson', () {
    test('LlmLoopStarted carries promptType + maxTurns', () {
      expect(
        LlmLoopStarted(
                occurredAt: _at,
                runId: _runId,
                promptType: 'assistant',
                maxTurns: 4)
            .payloadJson(),
        <String, Object?>{'promptType': 'assistant', 'maxTurns': 4},
      );
    });

    test('LlmLoopTurn carries the turn index', () {
      expect(
        LlmLoopTurn(occurredAt: _at, runId: _runId, turn: 2).payloadJson(),
        <String, Object?>{'turn': 2},
      );
    });

    test('ToolTurnDispatched carries turn + tool', () {
      expect(
        ToolTurnDispatched(
                occurredAt: _at, runId: _runId, turn: 1, tool: 'recall')
            .payloadJson(),
        <String, Object?>{'turn': 1, 'tool': 'recall'},
      );
    });

    test('LlmLoopCompleted carries the total turns', () {
      expect(
        LlmLoopCompleted(occurredAt: _at, runId: _runId, turns: 3)
            .payloadJson(),
        <String, Object?>{'turns': 3},
      );
    });

    test('LlmLoopBudgetExceeded carries dimension + turn', () {
      expect(
        LlmLoopBudgetExceeded(
                occurredAt: _at, runId: _runId, dimension: 'toolCalls', turn: 5)
            .payloadJson(),
        <String, Object?>{'dimension': 'toolCalls', 'turn': 5},
      );
    });

    test('toJson composes kind + base (runId always present) + payload', () {
      final json = LlmLoopStarted(
        occurredAt: _at,
        runId: _runId,
        promptType: 'assistant',
        maxTurns: 4,
      ).toJson();
      expect(json, <String, Object?>{
        'kind': 'llm-loop.started',
        'occurredAt': _at.toIso8601String(),
        'runId': _runId,
        'payload': <String, Object?>{'promptType': 'assistant', 'maxTurns': 4},
      });
    });
  });

  group('F.16-llm-4: closed sealed sum (drift guard)', () {
    test('exhaustive switch maps each variant', () {
      expect(
        _oneOfEach().map(_describe).toList(),
        <String>['started', 'turn', 'tool-turn', 'completed', 'budget-exceeded'],
      );
    });
  });

  group('F.16-llm-5: LlmLoopEventBus', () {
    test('events() delivers a representative full-turn sequence in order',
        () async {
      // The shape `call_llm_v1` will emit once it ships (steps 11–12): a
      // start, two turns, a dispatched tool turn, then completion.
      final bus = LlmLoopEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));

      bus.emit(LlmLoopStarted(
          occurredAt: _at, runId: _runId, promptType: 'assistant', maxTurns: 4));
      bus.emit(LlmLoopTurn(occurredAt: _at, runId: _runId, turn: 1));
      bus.emit(ToolTurnDispatched(
          occurredAt: _at, runId: _runId, turn: 1, tool: 'memory.recall'));
      bus.emit(LlmLoopTurn(occurredAt: _at, runId: _runId, turn: 2));
      bus.emit(LlmLoopCompleted(occurredAt: _at, runId: _runId, turns: 2));

      await bus.close();
      await sub.cancel();

      expect(received, <String>[
        'llm-loop.started',
        'llm-loop.turn',
        'llm-loop.tool-turn-dispatched',
        'llm-loop.turn',
        'llm-loop.completed',
      ]);
    });

    test('emit after close throws StateError', () async {
      final bus = LlmLoopEventBus();
      await bus.close();
      expect(
        () => bus.emit(LlmLoopTurn(occurredAt: _at, runId: _runId, turn: 1)),
        throwsStateError,
      );
    });
  });

  group('F.16-llm-6: the sink typedef', () {
    test('an LlmLoopEventSink receives the events it is handed', () {
      final collected = <LlmLoopEvent>[];
      final LlmLoopEventSink sink = collected.add;
      for (final event in _oneOfEach()) {
        sink(event);
      }
      expect(collected.map(_describe).toList(),
          <String>['started', 'turn', 'tool-turn', 'completed', 'budget-exceeded']);
    });
  });
}
