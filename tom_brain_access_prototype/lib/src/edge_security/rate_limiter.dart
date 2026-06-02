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
// Persistence. The plan says "bucket state persisted per principal,
// in-process for the prototype": the bucket map lives in this object's
// memory and a process restart resets every bucket (Q-E.2.5 accepts that
// volatility for the prototype; persisting bucket state into memory is a
// final-layer concern). "Persisted per principal" is honoured *within* the
// process: a principal's bucket survives across that principal's requests
// for the lifetime of the limiter, rather than being re-created per request.
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
  /// `> 0`, and [refillPeriod] must be strictly positive.
  RateLimitPolicy({
    required this.capacity,
    required this.refillTokens,
    required this.refillPeriod,
  }) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be >= 1');
    }
    if (refillTokens <= 0) {
      throw ArgumentError.value(refillTokens, 'refillTokens', 'must be > 0');
    }
    if (refillPeriod <= Duration.zero) {
      throw ArgumentError.value(
        refillPeriod,
        'refillPeriod',
        'must be a strictly positive duration',
      );
    }
  }

  /// Tokens replenished per microsecond — the continuous refill rate used by
  /// the lazy refill computation. Derived once from [refillTokens] and
  /// [refillPeriod].
  double get _tokensPerMicrosecond =>
      refillTokens / refillPeriod.inMicroseconds;
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

/// Mutable per-principal bucket state: the current (fractional) token count
/// and the wall-clock instant it was last refilled. One instance per
/// principal id; created full on first sight and held for the limiter's
/// lifetime ("persisted per principal", in-process).
class _BucketState {
  double tokens;
  DateTime lastRefill;

  _BucketState(this.tokens, this.lastRefill);
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

  /// Time source. Production passes `DateTime.now`; tests pass a controllable
  /// clock for deterministic refill.
  final DateTime Function() clock;

  /// `principalId` → bucket state. Created lazily on first [check].
  final Map<String, _BucketState> _buckets = {};

  /// Builds a limiter over [policy]. [clock] defaults to `DateTime.now`.
  RateLimiter({
    required this.policy,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// Charges one token to [principalId]'s bucket.
  ///
  /// Refills the bucket from the elapsed wall-clock time, then either
  /// consumes one token (returns normally) or — when fewer than one token is
  /// available — throws [RateLimitExceeded] with the wait until one token
  /// will have refilled. The bucket is *not* charged on a throw, so a
  /// rejected request does not push the retry window further out.
  ///
  /// [principalId] must be non-empty — an empty id would collapse every
  /// caller into one shared bucket.
  void check(String principalId) {
    if (principalId.isEmpty) {
      throw ArgumentError.value(
        principalId,
        'principalId',
        'must be non-empty',
      );
    }

    final now = clock();
    final bucket = _buckets.putIfAbsent(
      principalId,
      () => _BucketState(policy.capacity.toDouble(), now),
    );

    _refill(bucket, now);

    if (bucket.tokens >= 1.0) {
      bucket.tokens -= 1.0;
      return;
    }

    // Not enough for a whole token: compute the wait until the deficit
    // (1 - tokens) has refilled. refillTokens > 0 guarantees this is finite.
    final deficit = 1.0 - bucket.tokens;
    final microseconds =
        (deficit / policy._tokensPerMicrosecond).ceil();
    throw RateLimitExceeded(
      principalId,
      Duration(microseconds: microseconds),
    );
  }

  /// Refills [bucket] for the time elapsed since its last refill, capped at
  /// [RateLimitPolicy.capacity]. A no-op when no time has passed.
  void _refill(_BucketState bucket, DateTime now) {
    final elapsedMicros = now.difference(bucket.lastRefill).inMicroseconds;
    if (elapsedMicros <= 0) {
      // Clock did not advance (or went backwards — never let it drain the
      // bucket); just pin lastRefill forward so a backwards clock cannot
      // create a future credit.
      bucket.lastRefill = now;
      return;
    }
    final refilled = elapsedMicros * policy._tokensPerMicrosecond;
    bucket.tokens = (bucket.tokens + refilled).clamp(0.0, policy.capacity.toDouble());
    bucket.lastRefill = now;
  }
}
