// The dream LLM-call throttle (dream-redesign part d).
//
// The user's intent: "There must be a mechanism to throttle the dreaming to
// avoid too many calls to llms." Dreaming runs continuously in the background,
// and every chat-completion an agent makes costs money (paid substrate) or
// contends for a scarce local GPU. Left unbounded, a busy night of dreaming can
// fire hundreds of completions. The throttle bounds that rate.
//
// ── What it counts ──────────────────────────────────────────────────────
//
// The accounting unit is *one LLM-using agent fire = one token*. The cadence
// driver fires agents one at a time (part c) and cannot see inside a procedure
// to count its individual LLM calls, so the throttle gates at the granularity
// the driver controls: an agent that uses the substrate consumes a token before
// it is allowed to run. Embedding-only agents (`dream_recentroid_v1`,
// `restructure_tree_v1`, `dream_decay_v1`, `dream_repetition_detect_v1`) make no
// chat completion — only `sub.embed` — so they are *exempt*: the throttle
// protects the chat-completion budget, not embeddings.
//
// ── How it bounds ───────────────────────────────────────────────────────
//
// A sliding-window counter: at most [maxCallsPerWindow] tokens may be acquired
// in any trailing [window]. A global window caps the whole cadence; an optional
// per-lane cap (from `DreamLaneSpec.maxLlmCallsPerWindow`) caps a single noisy
// lane on top of the global budget — an LLM-using agent in a capped lane must
// have room in *both* windows. When the budget is exhausted the driver defers
// the lane (re-enqueues it, part c) rather than dropping the work, so no dream
// pass is ever lost — only paced.

/// The immutable, parsed `dream.throttle` settings (part d).
///
/// Held on [DreamConfig]; the run assembly turns it into a live [DreamThrottle].
/// Absent (`null` on the config) ⇒ dreaming is unthrottled (the behaviour before
/// part d).
final class DreamThrottleSettings {
  /// Builds the settings, validating that both bounds are strictly positive.
  DreamThrottleSettings({
    required this.maxCallsPerWindow,
    required this.window,
  }) {
    if (maxCallsPerWindow <= 0) {
      throw ArgumentError.value(maxCallsPerWindow, 'maxCallsPerWindow',
          'must be a positive number of calls');
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', 'must be a positive duration');
    }
  }

  /// The global cap: at most this many LLM-using agent fires per [window].
  final int maxCallsPerWindow;

  /// The trailing window the [maxCallsPerWindow] cap is measured over.
  final Duration window;
}

/// A sliding-window rate limiter for dream LLM-using agent fires (part d).
///
/// Live and stateful: it records the instant of each acquired token and prunes
/// instants older than [window] on every check. It is clock-free — the caller
/// (the cadence driver) passes "now" in milliseconds, mirroring the driver's
/// own injected-[Clock] discipline so the throttle is deterministically
/// testable.
final class DreamThrottle {
  /// Builds a throttle with a global [maxCallsPerWindow] over [window], an
  /// optional [perLaneMaxCallsPerWindow] map of per-lane caps, and the set of
  /// [embeddingOnlyAgents] that bypass it entirely.
  DreamThrottle({
    required this.maxCallsPerWindow,
    required this.window,
    Map<String, int> perLaneMaxCallsPerWindow = const <String, int>{},
    Set<String> embeddingOnlyAgents = defaultEmbeddingOnlyAgents,
  })  : _perLaneMax = Map<String, int>.unmodifiable(perLaneMaxCallsPerWindow),
        _embeddingOnly = Set<String>.unmodifiable(embeddingOnlyAgents) {
    if (maxCallsPerWindow <= 0) {
      throw ArgumentError.value(maxCallsPerWindow, 'maxCallsPerWindow',
          'must be a positive number of calls');
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', 'must be a positive duration');
    }
  }

  /// The agents that make no chat completion (only embeddings) and so are exempt
  /// from the throttle (`memory_specification.md` § 9.7 embedding-only passes).
  static const Set<String> defaultEmbeddingOnlyAgents = <String>{
    'dream_recentroid_v1',
    'restructure_tree_v1',
    'dream_decay_v1',
    'dream_repetition_detect_v1',
  };

  /// The global cap on LLM-using agent fires per [window].
  final int maxCallsPerWindow;

  /// The trailing window the caps are measured over.
  final Duration window;

  final Map<String, int> _perLaneMax;
  final Set<String> _embeddingOnly;

  /// Acquired-token instants (ms since epoch) inside the global window.
  final List<int> _globalHits = <int>[];

  /// Acquired-token instants per lane, for lanes that carry a per-lane cap.
  final Map<String, List<int>> _laneHits = <String, List<int>>{};

  /// Whether [agentId] is exempt from the throttle (embedding-only).
  bool isExempt(String agentId) => _embeddingOnly.contains(agentId);

  /// Tries to acquire one token for an LLM-using agent in lane [laneId] as of
  /// [nowMs], returning whether the budget allowed it.
  ///
  /// Acquires only when *both* the global window and the lane's window (if the
  /// lane has a per-lane cap) have room. On success it records the instant in
  /// the relevant windows and returns `true`; on exhaustion it records nothing
  /// and returns `false`, so a denied call costs no budget and the lane can be
  /// retried cleanly on a later tick.
  bool tryAcquire(String laneId, int nowMs) {
    _prune(nowMs);
    if (_globalHits.length >= maxCallsPerWindow) {
      return false;
    }
    final int? laneCap = _perLaneMax[laneId];
    final List<int>? laneHits =
        laneCap == null ? null : _laneHits.putIfAbsent(laneId, () => <int>[]);
    if (laneCap != null && laneHits!.length >= laneCap) {
      return false;
    }
    _globalHits.add(nowMs);
    laneHits?.add(nowMs);
    return true;
  }

  /// Drops every recorded instant at or before the window cut-off, so a token's
  /// budget is released once it ages past [window].
  void _prune(int nowMs) {
    final int cutoff = nowMs - window.inMilliseconds;
    _globalHits.removeWhere((t) => t <= cutoff);
    for (final hits in _laneHits.values) {
      hits.removeWhere((t) => t <= cutoff);
    }
  }
}
