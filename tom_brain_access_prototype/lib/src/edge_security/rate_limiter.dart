// E.29 — Per-principal token-bucket rate limiting for the edge.
//
// The plan line for E.29 reads "Implement rate limiting per principal
// (token-bucket; persisted bucket state per principal, in-process for the
// prototype)." This is the second of the four edge-security checks (proto
// spec § 8). Like every edge check it runs *before* an `Access` is
// constructed (AC-3, AC-4): a request that exceeds its principal's bucket
// never becomes an `Access`. On the OpenAI channel a failure surfaces as a
// `429` JSON envelope ([rateLimitHttpStatus]); on Telegram it surfaces as
// the graceful "slow down" message ([telegramRateLimitMessage]).
//
// Position in the edge chain (proto spec § 7.1 / § 8.0):
//
//     bearer auth / whitelist → rate-limit → quota → anchor
//
// Auth (E.28) runs first, so by the time the rate limiter sees a request the
// credential is already validated and resolved to a *non-secret*
// `principalId` (the stable id `IdentityResolver` E.24 produces). The bucket
// is keyed on that `principalId`, never on the bearer token — the token is a
// secret and must not become a map key that survives in process memory or a
// log line. Keying on `principalId` also means the same person's OpenAI and
// Telegram traffic share one bucket (the identity is one principal across
// channels, § 7.1), which is the intended throttle granularity.
//
// Algorithm — continuous-refill token bucket. Each principal owns a bucket
// of [RateLimitPolicy.capacity] tokens (the burst allowance). Every inbound
// request consumes one token. Tokens refill continuously at
// [RateLimitPolicy.refillTokens] per [RateLimitPolicy.refillPeriod]; the
// bucket is capped at [capacity]. The continuous (fractional) refill is
// computed lazily from the wall-clock elapsed since the bucket was last
// touched — there is no background timer, so an idle principal costs nothing
// and a bucket that has not been seen for a long time is simply full again
// on its next request. When the bucket cannot afford a token the limiter
// throws [RateLimitExceeded] carrying the [RateLimitExceeded.retryAfter]
// wait until one token will have refilled — the value the OpenAI adapter
// puts in the `Retry-After` header.
//
// Persistence. The plan says "bucket state persisted per principal". When an
// [EdgeStateStore] is supplied the limiter restores every bucket from it on
// construction and writes the whole snapshot back after each admitted request,
// so a principal's bucket survives a process restart (P1.4). Because the
// continuous refill is computed lazily from the wall-clock elapsed since each
// bucket was last touched, a bucket restored after downtime auto-credits the
// idle time on its next take — there is no separate catch-up step. When no
// store is supplied the bucket map lives only in this object's memory and a
// restart resets every bucket (the original in-process behaviour; harmless for
// the short-horizon burst throttle, unlike the daily quota E.30). Either way
// "per principal" is honoured within the process: a principal's bucket survives
// across that principal's requests for the limiter's lifetime.
//
// Clock seam. The limiter reads time through an injectable `DateTime
// Function()` ([RateLimiter.clock]); production passes `DateTime.now`, tests
// pass a controllable clock so refill is deterministic without real waiting.
//
// Scope discipline (per the strict per-substep log; mirrors E.24 – E.28).
// E.29 is the per-principal token-bucket limiter only. It does NOT:
//
//   * map the failure onto a shelf `Response` or a Telegram send — the
//     OpenAI adapter / Telegram adapter own the wire shape (E.41+); this
//     file exposes only the typed [RateLimitExceeded], the documented
//     `429` status constant, and the graceful-message constant the adapters
//     read. Channel-blind, exactly like E.28's `BearerAuthFailure`.
//   * implement the daily quota (E.30) — that is a separate, coarser cap
//     (calls per day) with its own component; the token bucket is the
//     short-horizon burst throttle.
//   * implement the anchor pre-check (E.31) or wire into boot (E.41+).
//   * authenticate (E.28) or resolve identity (E.24).

import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'edge_state_store.dart';

/// The HTTP status a [RateLimitExceeded] maps to on the OpenAI channel
/// (proto spec § 8: rate-limit failure → `429` JSON). Exposed as a single
/// constant so the OpenAI adapter (E.41+) has one source of truth rather
/// than hard-coding `429` at the call site. Shared with the daily quota
/// (E.30), which surfaces the same status.
const int rateLimitHttpStatus = 429;

/// The graceful message the Telegram adapter (E.41+) sends when a sender
/// trips the rate limit (proto spec § 8: Telegram failure → graceful
/// "slow down" message). The request is still dropped — no `Access` is
/// built; this is the user-visible courtesy, not a retry channel.
const String telegramRateLimitMessage =
    'You are sending messages too quickly — please slow down and try again '
    'in a moment.';

/// Immutable configuration of a per-principal token bucket.
///
/// A bucket holds at most [capacity] tokens (the burst allowance) and
/// refills [refillTokens] tokens every [refillPeriod]. One inbound request
/// costs one token, so the sustained rate is `refillTokens / refillPeriod`
/// requests and the instantaneous burst is [capacity] requests.
///
/// Boot (E.41+) builds one policy from the `AccessConfig` rate-limit section
/// ("bucket size + refill", proto spec § 11.4). The prototype uses a single
/// policy for every principal; a per-principal-class policy is a final-layer
/// concern (Q-E.29.2).
final class RateLimitPolicy {
  /// Maximum number of tokens the bucket can hold — the burst allowance.
  /// A fresh bucket starts full at [capacity]. Must be `>= 1`.
  final int capacity;

  /// Number of tokens added to the bucket every [refillPeriod]. Must be
  /// `> 0` so the bucket always eventually refills (a non-refilling bucket
  /// would make [RateLimitExceeded.retryAfter] undefined).
  final double refillTokens;

  /// The wall-clock window over which [refillTokens] are added. Must be a
  /// strictly positive duration.
  final Duration refillPeriod;

  /// Builds a policy. [capacity] must be `>= 1`, [refillTokens] must be
  /// `> 0`, and [refillPeriod] must be strictly positive. Delegates the
  /// numeric validation to the shared [TokenBucketPolicy], which the limiter
  /// runs on internally.
  RateLimitPolicy({
    required this.capacity,
    required this.refillTokens,
    required this.refillPeriod,
  }) : _bucketPolicy = TokenBucketPolicy(
          capacity: capacity,
          refillTokens: refillTokens,
          refillPeriod: refillPeriod,
        );

  /// The shared throttle policy this rate-limit policy maps onto.
  final TokenBucketPolicy _bucketPolicy;
}

/// Raised when a principal's token bucket cannot afford the current request.
///
/// Carries the non-secret [principalId] (safe to log — it is the stable id,
/// never the bearer token) and [retryAfter], the wait until one token will
/// have refilled. On the OpenAI channel the adapter maps this to
/// [rateLimitHttpStatus] (`429`) and puts `retryAfter` in the `Retry-After`
/// header; on Telegram it sends [telegramRateLimitMessage]. Either way the
/// request never becomes an `Access` (AC-4).
final class RateLimitExceeded implements Exception {
  /// The non-secret stable principal id whose bucket was exhausted.
  final String principalId;

  /// How long until the bucket will hold at least one token again — i.e.
  /// the earliest a retry can succeed. Always strictly positive.
  final Duration retryAfter;

  /// Builds the exception for [principalId] with the computed [retryAfter].
  const RateLimitExceeded(this.principalId, this.retryAfter);

  @override
  String toString() =>
      'RateLimitExceeded($principalId): retry after '
      '${retryAfter.inMilliseconds}ms';
}

/// Per-principal token-bucket rate limiter (E.29).
///
/// One bucket per `principalId`, keyed on the non-secret stable id. Call
/// [check] once per inbound request *after* auth has resolved the principal
/// and *before* the request becomes an `Access`. [check] consumes one token
/// and returns normally when the bucket can afford it, or throws
/// [RateLimitExceeded] when it cannot — mirroring E.28's validate-or-throw
/// contract so the edge chain composes uniformly.
///
/// Stateful (it owns the bucket map) but otherwise self-contained: no timer,
/// no I/O, no dependency on memory. Buckets are created lazily and never
/// evicted in the prototype — the principal set is small and bounded by the
/// configured credential set (a final-layer limiter would add idle-bucket
/// eviction; Q-E.29.3).
final class RateLimiter {
  /// The single policy applied to every principal in the prototype.
  final RateLimitPolicy policy;

  /// The shared keyed token bucket the limiter delegates to. Keyed on the
  /// non-secret `principalId`; owns the continuous-refill maths, the
  /// backwards-clock guard, and the per-principal state.
  final TokenBucket _bucket;

  /// Optional durable backing for the bucket map (P1.4). When present the
  /// limiter restores every bucket from it on construction and writes the
  /// snapshot back after each admitted request; when `null` the bucket map is
  /// in-process only and a restart resets it.
  final EdgeStateStore? _store;

  /// Builds a limiter over [policy]. [clock] defaults to [systemClock]. When
  /// [store] is supplied the bucket map is restored from it immediately, so a
  /// limiter rebuilt after a restart resumes the persisted buckets.
  RateLimiter({
    required this.policy,
    DateTime Function()? clock,
    EdgeStateStore? store,
  })  : _bucket = TokenBucket(policy: policy._bucketPolicy, clock: clock),
        _store = store {
    final store = _store;
    if (store != null) {
      _bucket.restore(_decodeRows(store.load()));
    }
  }

  /// Charges one token to [principalId]'s bucket.
  ///
  /// Delegates to the shared [TokenBucket]: takes one token and returns
  /// normally when the bucket can afford it, or throws [RateLimitExceeded]
  /// with the wait until one token will have refilled. The bucket is *not*
  /// charged on a throw, so a rejected request does not push the retry window
  /// further out. On a successful take the snapshot is written back to the
  /// store (when one is configured), so the consumed token survives a restart.
  ///
  /// [principalId] must be non-empty — an empty id would collapse every
  /// caller into one shared bucket (the bucket rejects an empty key).
  void check(String principalId) {
    final retryAfter = _bucket.tryTake(principalId);
    if (retryAfter != null) {
      throw RateLimitExceeded(principalId, retryAfter);
    }
    _store?.save(_encodeRows(_bucket.snapshot()));
  }

  /// Decodes persisted store rows into the bucket's typed snapshot form.
  static Map<String, TokenBucketSnapshot> _decodeRows(
    Map<String, Map<String, Object?>> rows,
  ) =>
      <String, TokenBucketSnapshot>{
        for (final entry in rows.entries)
          entry.key: TokenBucketSnapshot(
            tokens: (entry.value['tokens'] as num).toDouble(),
            lastRefill: DateTime.parse(entry.value['lastRefill'] as String),
          ),
      };

  /// Encodes the bucket's typed snapshot into JSON-able store rows. The
  /// `lastRefill` instant is written as an ISO-8601 string that preserves its
  /// zone, so restore reconstructs the same moment.
  static Map<String, Map<String, Object?>> _encodeRows(
    Map<String, TokenBucketSnapshot> snapshot,
  ) =>
      <String, Map<String, Object?>>{
        for (final entry in snapshot.entries)
          entry.key: <String, Object?>{
            'tokens': entry.value.tokens,
            'lastRefill': entry.value.lastRefill.toIso8601String(),
          },
      };

  /// Number of principals with live bucket state — for observability and as
  /// the seam an idle-eviction policy reads (Q-E.29.3).
  int get principalCount => _bucket.keyCount;

  /// Drops all bucket state; every principal is full again on its next
  /// [check]. The eviction seam the per-principal-map bound (G.3.3) exposes.
  void clear() => _bucket.clear();
}
