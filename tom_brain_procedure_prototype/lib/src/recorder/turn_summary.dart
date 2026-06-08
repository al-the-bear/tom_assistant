// TurnSummary — the turn-complete seam the §5.4 / §5.5 summary fan-out needs
// (`tom_brain_logging.md` §5.4 / §5.5 / §9; §10 build-order step #5).
//
// The per-call `LlmTrailRecord` (the raw §5.2 trail) carries everything the
// §5.8 by-role / by-llm projections need — but the §5.4 *session narrative* and
// the §5.5 *global narrative* are organised per **turn**, and a turn block's
// two headline facts — the **user prompt** and the **final answer** — live on
// neither the bridge observation nor the engine's run record. They are known
// only at the dispatch edge, where the route holds the inbound `Access` and the
// run's outcome.
//
// So the route emits one `TurnSummary` when a turn finishes (§9's "final-answer
// delivery sink"). The summary fan-out buffers the turn's `LlmTrailRecord`s as
// they arrive during the run, then on this signal flushes one session + one
// global turn block built from the buffered calls plus this summary's
// prompt/answer. Turn-less (dream) calls never produce a `TurnSummary`; they
// feed only the §5.8 projections.

/// One completed user turn, as the dispatch route saw it — the prompt that came
/// in, the answer that went out, and the correlation the §5.4 / §5.5 narratives
/// key and annotate their turn blocks by.
///
/// Immutable value object. Emitted once per turn through a [TurnSummarySink].
final class TurnSummary {
  /// The turn id (`TurnId.value`) — the §5.4 turn-block key and the join key
  /// the fan-out buffers the turn's LLM calls under.
  final String turnId;

  /// The session the turn belonged to — the §5.4 file key
  /// (`sessions/<sessionId>.summary.md`) and the §5.5 per-header annotation.
  final String sessionId;

  /// The principal the turn was served for — the §5.4 file-header `principal:`
  /// field. Never the bearer/bot token (§5.3 — credentials never enter logs).
  final String principalId;

  /// The memory profile the turn ran under, or `null` for the process default.
  /// The §5.4 turn-header `profile:` annotation (Q3 — one file, annotated).
  final String? profile;

  /// The persona (`Persona.personaId`) the turn answered as.
  final String persona;

  /// The originating channel, or `null` when the route cannot see one. The
  /// §5.4 file-header `channel:` annotation, rendered only when present.
  final String? channel;

  /// When the route began serving the turn (UTC) — the §5.4 turn-header
  /// timestamp.
  final DateTime startedAt;

  /// The inbound prompt text — the §5.4 `> **User:**` line.
  final String userPrompt;

  /// The final answer the turn produced, or `null` when it produced none
  /// (truncated by a deadline, or crashed). The §5.4 `**Answer:**` line.
  final String? finalAnswer;

  const TurnSummary({
    required this.turnId,
    required this.sessionId,
    required this.principalId,
    required this.profile,
    required this.persona,
    required this.channel,
    required this.startedAt,
    required this.userPrompt,
    required this.finalAnswer,
  });
}

/// The sink the dispatch route fires once per completed turn
/// (`tom_brain_logging.md` §5.4 / §5.5 / §10 step #5). Bound by the host to the
/// summary fan-out; `null` leaves the engine emitting no per-turn narrative.
/// Best-effort and non-blocking (logging-spec §9) — a throwing sink must never
/// fail the turn, so the route guards the call.
typedef TurnSummarySink = void Function(TurnSummary summary);
