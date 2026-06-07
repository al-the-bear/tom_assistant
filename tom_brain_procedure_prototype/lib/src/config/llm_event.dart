// `LlmLoopEvent` sealed sum — the scripted LLM loop's typed observability
// stream (Extension F step 16; `tom_brain_procedure_prototype_specification.md`
// § 13, § 21.1, § 21.7).
//
// Five variants tracing one `call_llm_v1` turn loop (§ 21.1):
//
//   - `LlmLoopStarted`        — the loop began for a prompt type / role.
//   - `LlmLoopTurn`           — one substrate turn was taken.
//   - `ToolTurnDispatched`    — a turn's response requested a tool call,
//                               which the loop dispatched through `tool.invoke`.
//   - `LlmLoopCompleted`      — the loop reached a terminal answer.
//   - `LlmLoopBudgetExceeded` — a per-loop budget dimension was exhausted
//                               before a terminal answer (PE-8).
//
// Same shape as the engine half (`EngineEvent`, C.44): a `sealed`
// `BrainEvent` subtree with a kebab-case `kind` discriminator, a null-omitting
// `payloadJson()`, and a `runId` *narrowed to required* — every loop turn
// happens inside a `call_llm_v1` procedure run, so (unlike the tool / MCP /
// dispatcher access-scoped events) there is always a run id. The
// `LlmLoopEventBus` (`llm_event_bus.dart`) is the broadcast fan-in.
//
// ── Emission is deferred to the `call_llm_v1` loop (steps 11–12) ─────
//
// Step 16 completes § 13's *type contract* for the loop's observability
// surface: the five typed variants, their kinds, payloads, and the bus.
// Their *emission* — and the plan's `Verify` sub-item "the `call_llm_v1` loop
// test asserts the `LlmLoopEvent` sequence" — is structurally gated on the
// `call_llm_v1` loop itself, which does not exist yet (it is built in plan
// steps 11–12, currently paused on the §21.7 assembly clarification
// `_ai/clarifications/20260607_150942_clarification.tom_brain.md`). When the
// loop lands it takes an [LlmLoopEventSink] (wired to an `LlmLoopEventBus`)
// and emits this sequence at each turn; the sequence-assertion test rides
// with it. This mirrors how steps 6/8 deferred *their* observability into
// step 16 — the surface is defined where the taxonomy is owned, the emission
// lands where the runtime that triggers it lives.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// Sink the `call_llm_v1` loop calls with each [LlmLoopEvent] it emits.
///
/// Wired by the composition root to an `LlmLoopEventBus` (`bus.emit`) when the
/// loop is built (steps 11–12). `null` disables emission.
typedef LlmLoopEventSink = void Function(LlmLoopEvent event);

/// Marker / base for every typed scripted-LLM-loop observability event.
///
/// A consumer subscribed to `LlmLoopEventBus.events()` sees only subtypes of
/// this class. Exhaustive `switch` over the closed five-variant taxonomy
/// (spec § 13) is the recommended branch surface.
///
/// Unlike the tool / MCP events, this base **narrows** `runId` to required:
/// every loop turn happens inside a `call_llm_v1` run, mirroring `EngineEvent`.
sealed class LlmLoopEvent extends BrainEvent {
  /// Builds the base of a loop event. [runId] is required and non-null — see
  /// the file header.
  LlmLoopEvent({
    required super.occurredAt,
    required String super.runId,
    super.causedBy,
  });

  /// The run id this loop event belongs to. Always present (the constructor
  /// requires it).
  @override
  String get runId => super.runId!;
}

/// The `call_llm_v1` loop began (§ 21.1) — emitted once, before the first
/// substrate turn.
final class LlmLoopStarted extends LlmLoopEvent {
  /// The prompt type the loop assembles and runs (e.g. `assistant_to_user`).
  final String promptType;

  /// The maximum number of turns the loop will take before stopping.
  final int maxTurns;

  LlmLoopStarted({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.promptType,
    required this.maxTurns,
  });

  @override
  String get kind => 'llm-loop.started';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'promptType': promptType,
        'maxTurns': maxTurns,
      };
}

/// One substrate turn was taken in the loop (§ 21.1) — emitted per turn,
/// carrying the 1-based [turn] index.
final class LlmLoopTurn extends LlmLoopEvent {
  /// The 1-based index of this turn within the loop.
  final int turn;

  LlmLoopTurn({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.turn,
  });

  @override
  String get kind => 'llm-loop.turn';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'turn': turn,
      };
}

/// A turn's response requested a tool call, which the loop dispatched
/// through `tool.invoke` (§ 21.1, § 21.2) — emitted per dispatched tool turn.
final class ToolTurnDispatched extends LlmLoopEvent {
  /// The 1-based index of the turn whose response requested the tool.
  final int turn;

  /// The name of the tool the loop dispatched.
  final String tool;

  ToolTurnDispatched({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.turn,
    required this.tool,
  });

  @override
  String get kind => 'llm-loop.tool-turn-dispatched';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'turn': turn,
        'tool': tool,
      };
}

/// The loop reached a terminal answer (§ 21.1) — emitted once, carrying the
/// total [turns] taken.
final class LlmLoopCompleted extends LlmLoopEvent {
  /// The total number of turns the loop took before terminating.
  final int turns;

  LlmLoopCompleted({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.turns,
  });

  @override
  String get kind => 'llm-loop.completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'turns': turns,
      };
}

/// A per-loop budget dimension was exhausted before a terminal answer
/// (§ 21.1, PE-8) — emitted when the loop stops on a budget refusal.
final class LlmLoopBudgetExceeded extends LlmLoopEvent {
  /// The budget dimension that was exhausted (e.g. `llmTurns`, `toolCalls`).
  final String dimension;

  /// The 1-based index of the turn at which the budget was exhausted.
  final int turn;

  LlmLoopBudgetExceeded({
    required super.occurredAt,
    required super.runId,
    super.causedBy,
    required this.dimension,
    required this.turn,
  });

  @override
  String get kind => 'llm-loop.budget-exceeded';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'dimension': dimension,
        'turn': turn,
      };
}
