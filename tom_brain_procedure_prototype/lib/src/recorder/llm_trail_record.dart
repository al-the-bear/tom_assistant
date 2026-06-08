// LlmTrailRecord — a bridge [LlmCallObservation] enriched with the
// run-correlation the engine knows (`tom_brain_logging.md` §5.2 / §10 step #4).
//
// The bridge fires an [LlmCallObservation] carrying what it can see — wire,
// answer, report, turn-correlation. The §5.2 raw trail also wants the *run*
// facts: `runId`, `trailId`, and the session/profile/principal of the request.
// Those belong to the run, not the bridge, so the engine wraps each observation
// it receives into this record before handing it to the run's [LlmTrailSink].
//
// Session / profile / principal are not yet threaded into the engine, so they
// are nullable here and populated `null` by the live wiring (a documented
// follow-up, mirroring how `turnId` arrived incrementally — logging-spec §10
// step #2). The writer renders whatever is present.

import '../bridges/llm_call_observation.dart';

/// One completed LLM call, ready for the §5.2 raw-trail writer: the bridge's
/// [observation] plus the run-correlation the engine supplies.
final class LlmTrailRecord {
  /// What the substrate bridge observed (wire + answer + report + turn).
  final LlmCallObservation observation;

  /// The run that issued the call. `null` only if the engine could not
  /// resolve it (it always can for a real run).
  final String? runId;

  /// The run's trail id (`TrailId.value`), or `null` if the run's trail was
  /// not open when the call fired.
  final String? trailId;

  /// The session the request belonged to. `null` until session threading
  /// reaches the engine (follow-up).
  final String? sessionId;

  /// The substrate profile the call ran under. `null` until profile threading
  /// reaches the engine (follow-up).
  final String? profile;

  /// The principal the request was served for. `null` until principal
  /// threading reaches the engine (follow-up).
  final String? principalId;

  const LlmTrailRecord({
    required this.observation,
    this.runId,
    this.trailId,
    this.sessionId,
    this.profile,
    this.principalId,
  });
}

/// The engine-level sink one [LlmTrailRecord] is handed to per completed LLM
/// call (`tom_brain_logging.md` §10 step #4). Bound by the host to an
/// `LlmTrailWriter`; `null` leaves the engine emitting no raw LLM trail.
/// Best-effort and non-blocking (logging-spec §9).
typedef LlmTrailSink = void Function(LlmTrailRecord record);
