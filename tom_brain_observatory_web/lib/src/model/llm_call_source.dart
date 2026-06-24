// MSPP-56 — the run a §4.5 LLM-call detail is fetched against. Mirrors the
// backend's "exactly one of ?turn= or ?run=" contract (MSPP-55, the `/api/llm`
// resolver): a foreground turn carries a `turnId`; a turn-less dream/free-time
// run (§ 3.6) carries a `runId`. Encoding the choice as a sealed type makes the
// "exactly one" invariant unrepresentable in the wrong shape — a caller
// constructs a turn source *or* a dream-run source, never both or neither.

/// Discriminates which run an LLM-call detail is fetched against, contributing
/// the single `?turn=`/`?run=` query parameter the `/api/llm` request carries.
sealed class LlmCallSource {
  const LlmCallSource();

  /// A foreground turn, resolved against the turn's procedure log (`?turn=`).
  const factory LlmCallSource.turn(String turnId) = _TurnSource;

  /// A turn-less dream/free-time run, resolved against the dream run's log
  /// (`?run=`).
  const factory LlmCallSource.dreamRun(String runId) = _DreamRunSource;

  /// The single `?turn=`/`?run=` query parameter this source adds to the
  /// `/api/llm` request (alongside the `path=` link).
  Map<String, String> get queryParameters;
}

class _TurnSource extends LlmCallSource {
  final String turnId;
  const _TurnSource(this.turnId);

  @override
  Map<String, String> get queryParameters => <String, String>{'turn': turnId};
}

class _DreamRunSource extends LlmCallSource {
  final String runId;
  const _DreamRunSource(this.runId);

  @override
  Map<String, String> get queryParameters => <String, String>{'run': runId};
}
