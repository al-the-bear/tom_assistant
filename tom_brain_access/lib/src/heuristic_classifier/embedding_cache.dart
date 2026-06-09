// In-process embedding cache — the cheap path gets cheaper on repeat prompts
// (E.34; `tom_brain_access_specification.md` § 9.2).
//
// What this file owns:
//
//   * `EmbeddingCache` — an in-process cache keyed by *exact* inbound text,
//     TTL 5 min. It wraps a `KindHintEmbedder` seam: on a cache hit it returns
//     the stored embedding and **saves the embed call**; on a miss (or expiry)
//     it calls the wrapped embedder, stores the result with its compute time,
//     and returns it. `EmbeddingCache.embed` is itself a `KindHintEmbedder`,
//     so the cache slots in *in front of* the substrate seam without touching
//     `HeuristicKindHintClassifier` (E.33): boot (E.41+) binds the real
//     substrate `EmbeddingService` as the wrapped embedder, then hands
//     `cache.embed` to the classifier.
//
// Why wrap the seam rather than bake caching into the classifier (single
// responsibility): E.33 deliberately left the embedder a one-argument
// function precisely so a cache could compose in front of it. The classifier
// owns the three-step decision (§ 9.1); the cache owns "have I embedded this
// exact text recently?" — one reason to change each. The classifier never
// learns a cache exists (the E.33 anti-leak: a consumer asks for a value;
// whether it came from a cache is the provider's concern).
//
// What this file does NOT do (scope discipline — E.34 only):
//
//   * No semantic / near-duplicate matching. The key is the *exact* text
//     (§ 9.2). A prompt that differs by a space is a different key — that is
//     the spec's contract, and it keeps the cache a pure memoisation of the
//     embed call rather than a second, fuzzy classifier.
//   * No substrate / memory dependency. The cache wraps a `KindHintEmbedder`
//     (a function), so it imports neither `tom_brain_substrate` nor
//     `tom_brain_memory` — the same anti-leak discipline as E.33 (Plan E.7).
//   * No failure caching. Only *resolved* embeddings are stored; a throwing
//     embed call propagates and leaves the cache untouched, so a transient
//     substrate outage is not memoised into a 5-min stale failure.

import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'heuristic_kind_hint_classifier.dart';

/// Default ceiling on the number of live cache entries (G.3.1).
///
/// The cache is keyed by *exact inbound text*, an attacker-influenced key
/// space, so a stream of distinct prompts would grow the map without bound
/// between TTL sweeps. This least-recently-used ceiling bounds the memory a
/// long-running process can hold to embeddings; a final-layer cache (Q-E.34.3)
/// makes it configurable. Sized generously so it never evicts a genuinely
/// recent prompt at the prototype's request scale.
const int defaultEmbeddingCacheMaxEntries = 10000;

/// In-process recent-embedding cache (E.34; § 9.2).
///
/// Memoises the substrate embed call keyed by the **exact** inbound text, with
/// a 5-min default TTL. A cache hit returns the stored embedding and saves the
/// embed call; the E.50 smoke and E.55 conformance assert that short-circuit.
///
/// **Absolute TTL, not sliding.** An entry expires [ttl] after it was
/// *computed*, regardless of how often it is read. The spec calls these
/// "recent embeddings": the cache is a short memoisation of a recent embed
/// call, not a popularity-weighted store, so a much-repeated prompt is still
/// re-embedded once its entry ages out (the substrate embedding model can
/// change underneath us; a 5-min ceiling bounds how stale a cached vector can
/// be). See Q-E.34.1.
///
/// **Resolved values only.** Concurrent identical misses each run the embedder
/// (no in-flight de-duplication) and a throwing embed call is not memoised —
/// the cache stores only embeddings that actually resolved. See Q-E.34.2.
///
/// [EmbeddingCache.embed] is a [KindHintEmbedder], so an instance composes in
/// front of the substrate seam: boot binds the real `EmbeddingService` as the
/// wrapped embedder and passes `cache.embed` to [HeuristicKindHintClassifier].
final class EmbeddingCache {
  /// Builds the cache over the [embedder] it wraps.
  ///
  /// [ttl] is the entry lifetime measured from compute time (default 5 min,
  /// § 9.2). [clock] is the time source — production uses `DateTime.now`,
  /// tests pass a controllable clock (the same seam the edge-security limiters
  /// use). [ttl] must be positive; a non-positive TTL would make every entry
  /// expire instantly, defeating the cache.
  EmbeddingCache({
    required KindHintEmbedder embedder,
    Duration ttl = const Duration(minutes: 5),
    int maxEntries = defaultEmbeddingCacheMaxEntries,
    DateTime Function() clock = systemClock,
  })  : assert(ttl > Duration.zero, 'ttl must be positive'),
        _embedder = embedder,
        _cache = TtlCache<String, List<double>>(
          ttl: ttl,
          maxEntries: maxEntries,
          clock: clock,
        );

  final KindHintEmbedder _embedder;

  /// Exact-text → cached embedding. Absolute-TTL expiry with a
  /// least-recently-used size ceiling ([defaultEmbeddingCacheMaxEntries]);
  /// expired entries are swept lazily on each access. The store mechanics
  /// (sweep, recency, eviction) live in the shared [TtlCache]; this class
  /// owns only the "have I embedded this exact text recently?" policy.
  final TtlCache<String, List<double>> _cache;

  /// The cached-or-computed embedding for [text] — a [KindHintEmbedder].
  ///
  /// On a live cache hit (an entry exists for the exact [text] and is younger
  /// than the TTL) returns the stored embedding *without calling the wrapped
  /// embedder* — the embed call is saved (§ 9.2). On a miss or an expired
  /// entry, calls the wrapped embedder, stores the result, and returns it.
  ///
  /// A throwing embed call propagates and leaves the cache untouched (resolved
  /// values only — concurrent identical misses each run the embedder).
  Future<List<double>> embed(String text) async {
    final List<double>? hit = _cache.get(text);
    if (hit != null) {
      return hit;
    }

    // Miss (or expiry): compute, then store. A failing embedder throws here
    // and the cache is left untouched — no failure is memoised.
    final List<double> embedding = await _embedder(text);
    _cache.set(text, embedding);
    return embedding;
  }

  /// The number of live (post-sweep) entries — for tests and observability.
  int get size => _cache.length;

  /// Drops all entries. For tests and for a deliberate boot-time flush.
  void clear() => _cache.clear();
}
