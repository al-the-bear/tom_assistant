// LlmCallObservation — the bridge-layer record of one completed LLM call
// (`tom_brain_logging.md` §5.2 / §10 step #4).
//
// The §5.2 raw LLM trail (`llm/<role>/…raw.json`) needs the **full wire
// body** plus the answer and the call's provenance/metrics. Those three
// facts only ever coexist in one place: [SubstrateBridge.llm], which
// drains the substrate stream — it holds the captured wire
// ([CapturedWirePrompt], on the terminal `LlmStreamCompleted`), the
// concatenated [answer], and the terminal [LlmCallReport]. This value
// type bundles exactly what the bridge knows at that moment; the engine
// (which knows the run) wraps it with run-correlation into the
// `LlmTrailRecord` a writer consumes.
//
// Deliberately **not** part of the d4rt-facing result map (PE-1): the
// wire body must never cross into procedure scope. The bridge fires this
// through a *separate* [LlmTrailObserver] sink, distinct from the
// `BridgeCallRecorder` that feeds the run trail's effect log — so a
// procedure script can never read the scaffold it ran under.

import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show CapturedWirePrompt, LlmCallReport;

/// One completed LLM call as the substrate bridge observed it.
///
/// Carries everything §5.2 needs that the *bridge* can see; the
/// run-scoped fields (`runId`, `trailId`, `sessionId`, …) are added by
/// the engine when it wraps this into an `LlmTrailRecord`.
final class LlmCallObservation {
  /// The role the call was assembled for (`assistant_to_user`, …) — the
  /// §5.2 `callType` and the `llm/<callType>/…` path segment.
  final String callType;

  /// The turn id this call belonged to (`TurnId.value`), or `null` for
  /// an internal / free-time / dream call issued outside a user turn.
  final String? turnId;

  /// The call's ordinal within its turn, or `null` when [turnId] is
  /// `null`. Together `turnId` + `callSeq` name the call across the
  /// system (logging-spec §3).
  final int? callSeq;

  /// The substrate-assigned call id (matches the terminal
  /// `LlmStreamCompleted.callId`). Used as the path-stem fallback for a
  /// turn-less call.
  final String callId;

  /// When the bridge began draining the call's stream (UTC).
  final DateTime startedAt;

  /// The wire body the provider saw, or `null` when the substrate did
  /// not surface one. This is the §5.2 `wire` payload.
  final CapturedWirePrompt? wire;

  /// The concatenated answer text the call produced.
  final String answer;

  /// The terminal report — provider, model, token counts, retries,
  /// wall-clock, anchorHash, promptHash, templateSha.
  final LlmCallReport report;

  const LlmCallObservation({
    required this.callType,
    required this.turnId,
    required this.callSeq,
    required this.callId,
    required this.startedAt,
    required this.wire,
    required this.answer,
    required this.report,
  });
}

/// Sink the bridge fires once per completed LLM call (`tom_brain_logging.md`
/// §10 step #4). `null` on the shared template bridge and on every run that
/// does not bind a raw-trail writer; the engine binds a per-run observer that
/// wraps the [LlmCallObservation] with run-correlation. Best-effort and
/// non-blocking (logging-spec §9) — a throwing observer must not break the
/// completion, so the bridge guards the call.
typedef LlmTrailObserver = void Function(LlmCallObservation observation);
