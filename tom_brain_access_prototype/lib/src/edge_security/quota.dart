// E.30 — Per-principal daily LLM-call quota for the edge.
//
// The plan line for E.30 reads "Implement a per-principal quota (daily
// LLM-call cap) — surfaces as `429` on OpenAI / a graceful Telegram
// message." This is the third of the four edge-security checks (proto spec
// § 8). Like every edge check it runs *before* an `Access` is constructed
// (AC-3, AC-4): a request that has spent its principal's daily allowance
// never becomes an `Access`. On the OpenAI channel a failure surfaces as a
// `429` JSON envelope ([rateLimitHttpStatus], the same status the burst
// throttle uses — proto spec § 8.0); on Telegram it surfaces as the graceful
// "daily limit reached" message ([telegramQuotaMessage]).
//
// Position in the edge chain (proto spec § 7.1 / § 8.0):
//
//     bearer auth / whitelist → rate-limit → quota → anchor
//
// Quota runs *after* the token bucket (E.29) and *before* the anchor
// pre-check (E.31). By the time it sees a request the credential is validated
// (E.28) and the principal has already cleared the short-horizon burst
// throttle, so the quota only sees requests that are otherwise admissible.
// Like the rate limiter it is keyed on the *non-secret* `principalId` (the
// stable id `IdentityResolver` E.24 produces), never on the bearer token —
// the token must not become a map key that survives in process memory or a
// log line. Keying on `principalId` also means the same person's OpenAI and
// Telegram traffic draw down one shared daily allowance (the identity is one
// principal across channels, § 7.1), which is the intended cap granularity.
//
// Quota vs. rate limit — two different horizons. The token bucket (E.29) is
// the *short-horizon burst* throttle: it smooths the instantaneous request
// rate (requests per second). The quota is the *long-horizon* cap: at most
// [DailyQuotaPolicy.dailyCap] admitted calls per calendar day, regardless of
// how slowly they arrive. A principal that paces itself perfectly under the
// burst limit can still exhaust its daily quota; the two checks are
// independent and both must pass.
//
// Algorithm — calendar-day counter. Each principal owns a counter of calls
// made within the current day plus the day that counter belongs to. On each
// [check] the limiter resolves the current day (the date portion of the
// injected clock, in the clock's own zone); if the stored day differs from
// the current day the counter resets to zero (a fresh day, a new allowance).
// If the counter has already reached [dailyCap] the limiter throws
// [DailyQuotaExceeded] carrying [DailyQuotaExceeded.retryAfter] — the wait
// until the next day boundary, the value the OpenAI adapter puts in the
// `Retry-After` header. Otherwise the counter is incremented and the call is
// admitted. A *rejected* request is **not** counted (it consumed no LLM
// call), so a client that keeps hammering an exhausted quota does not push
// its own reset further out and the count never overflows past [dailyCap].
//
// Persistence. A daily cap conceptually wants cross-restart durability — a
// restart at 23:00 should not hand every principal a fresh day's allowance
// (Q-E.29.1 / Q-E.30.1). For the prototype the counter map lives in this
// object's memory and a process restart resets every counter, consistent
// with the rate limiter and Q-E.2.5 (in-process volatility accepted for the
// prototype; persisting the counter into memory is a final-layer concern).
// "Per principal" is honoured *within* the process: a principal's counter
// survives across that principal's requests for the limiter's lifetime.
//
// Clock seam. The limiter reads time through an injectable `DateTime
// Function()` ([DailyQuotaLimiter.clock]); production passes `DateTime.now`,
// tests pass a controllable clock so the day boundary is deterministic
// without waiting for real midnight. The "day" is the calendar date of
// whatever the clock returns, in the clock's own zone (UTC if the clock
// yields UTC instants, local otherwise) — the day-boundary maths preserves
// that zone so a UTC-driven deployment resets at UTC midnight.
//
// Scope discipline (per the strict per-substep log; mirrors E.24 – E.29).
// E.30 is the per-principal daily quota only. It does NOT:
//
//   * map the failure onto a shelf `Response` or a Telegram send — the
//     OpenAI adapter / Telegram adapter own the wire shape (E.41+); this
//     file exposes only the typed [DailyQuotaExceeded], the documented
//     `429` status constant (reused from the rate limiter), and the graceful
//     quota-message constant the adapters read. Channel-blind, exactly like
//     E.28's `BearerAuthFailure` and E.29's `RateLimitExceeded`.
//   * implement the short-horizon burst throttle (E.29) — that is the token
//     bucket; the quota is the coarser daily cap.
//   * implement the anchor pre-check (E.31) or wire into boot (E.41+).
//   * authenticate (E.28) or resolve identity (E.24).

import 'rate_limiter.dart' show rateLimitHttpStatus;

/// The graceful message the Telegram adapter (E.41+) sends when a sender has
/// spent the day's quota (proto spec § 8: Telegram failure → graceful
/// message). The request is still dropped — no `Access` is built; this is the
/// user-visible courtesy, not a retry channel. Unlike the burst-throttle
/// message ([telegramRateLimitMessage]) this one names the *daily* boundary
/// so the user understands the wait is until tomorrow, not a moment.
const String telegramQuotaMessage =
    'You have reached your daily message limit — please try again tomorrow.';

/// The HTTP status a [DailyQuotaExceeded] maps to on the OpenAI channel
/// (proto spec § 8: quota failure → `429`). The same `429` the burst throttle
/// surfaces; re-exported under a quota-specific name so an E.30 call site
/// reads as `quotaHttpStatus` without a second hard-coded literal — there is
/// still exactly one underlying source ([rateLimitHttpStatus]).
const int quotaHttpStatus = rateLimitHttpStatus;

/// Immutable configuration of the per-principal daily quota.
///
/// Each principal may make at most [dailyCap] admitted LLM calls per calendar
/// day; the counter resets at the start of the next day (in the clock's
/// zone). Boot (E.41+) builds one policy from the `AccessConfig` quota section
/// ("daily quota cap", proto spec § 11.4 / § 13.1). The prototype uses a
/// single cap for every principal; a per-principal-class cap is a final-layer
/// concern (Q-E.30.2).
final class DailyQuotaPolicy {
  /// Maximum number of admitted calls a principal may make per calendar day.
  /// Must be `>= 1` — a zero cap would reject every request unconditionally,
  /// which is a misconfiguration, not a throttle.
  final int dailyCap;

  /// Builds a policy. [dailyCap] must be `>= 1`.
  DailyQuotaPolicy({required this.dailyCap}) {
    if (dailyCap < 1) {
      throw ArgumentError.value(dailyCap, 'dailyCap', 'must be >= 1');
    }
  }
}

/// Raised when a principal has spent its daily quota.
///
/// Carries the non-secret [principalId] (safe to log — it is the stable id,
/// never the bearer token) and [retryAfter], the wait until the next day
/// boundary when the allowance refreshes. On the OpenAI channel the adapter
/// maps this to [quotaHttpStatus] (`429`) and puts `retryAfter` in the
/// `Retry-After` header; on Telegram it sends [telegramQuotaMessage]. Either
/// way the request never becomes an `Access` (AC-4).
final class DailyQuotaExceeded implements Exception {
  /// The non-secret stable principal id whose daily quota was exhausted.
  final String principalId;

  /// How long until the next day boundary — the earliest a retry can succeed.
  /// Always strictly positive (the current instant is strictly before the
  /// next day start).
  final Duration retryAfter;

  /// Builds the exception for [principalId] with the computed [retryAfter].
  const DailyQuotaExceeded(this.principalId, this.retryAfter);

  @override
  String toString() =>
      'DailyQuotaExceeded($principalId): retry after '
      '${retryAfter.inMinutes}m';
}

/// Mutable per-principal quota state: the number of admitted calls within
/// [dayStart]'s calendar day and the start-of-day instant that count belongs
/// to. One instance per principal id; created on first sight and held for the
/// limiter's lifetime ("per principal", in-process).
class _QuotaState {
  int calls;
  DateTime dayStart;

  _QuotaState(this.calls, this.dayStart);
}

/// Per-principal daily LLM-call quota (E.30).
///
/// One counter per `principalId`, keyed on the non-secret stable id. Call
/// [check] once per inbound request *after* the rate limiter (E.29) has
/// admitted it and *before* the request becomes an `Access`. [check] counts
/// one call and returns normally when the principal is under its daily cap,
/// or throws [DailyQuotaExceeded] when the cap is reached — mirroring E.28's /
/// E.29's validate-or-throw contract so the edge chain composes uniformly.
///
/// Stateful (it owns the counter map) but otherwise self-contained: no timer,
/// no I/O, no dependency on memory. Counters are created lazily and never
/// evicted in the prototype — the principal set is small and bounded by the
/// configured credential set (a final-layer quota would persist the counter
/// and add idle-counter eviction; Q-E.30.1 / Q-E.30.3).
final class DailyQuotaLimiter {
  /// The single policy applied to every principal in the prototype.
  final DailyQuotaPolicy policy;

  /// Time source. Production passes `DateTime.now`; tests pass a controllable
  /// clock for a deterministic day boundary.
  final DateTime Function() clock;

  /// `principalId` → quota state. Created lazily on first [check].
  final Map<String, _QuotaState> _states = {};

  /// Builds a limiter over [policy]. [clock] defaults to `DateTime.now`.
  DailyQuotaLimiter({
    required this.policy,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// Counts one daily LLM call against [principalId]'s quota.
  ///
  /// Resolves the current day from the clock, resetting the principal's
  /// counter if the day has rolled over, then either admits the call
  /// (increments the counter, returns normally) or — when the daily cap is
  /// already reached — throws [DailyQuotaExceeded] with the wait until the
  /// next day boundary. The counter is *not* incremented on a throw, so a
  /// rejected request does not push the reset further out and the count never
  /// climbs past [DailyQuotaPolicy.dailyCap].
  ///
  /// [principalId] must be non-empty — an empty id would collapse every
  /// caller into one shared quota.
  void check(String principalId) {
    if (principalId.isEmpty) {
      throw ArgumentError.value(
        principalId,
        'principalId',
        'must be non-empty',
      );
    }

    final now = clock();
    final today = _startOfDay(now);
    final state = _states.putIfAbsent(
      principalId,
      () => _QuotaState(0, today),
    );

    // Roll the counter over on any day change (forward to a new day, or a
    // backwards clock landing on a different day — either way the stored count
    // no longer belongs to the current day, so it is reset).
    if (state.dayStart != today) {
      state.calls = 0;
      state.dayStart = today;
    }

    if (state.calls >= policy.dailyCap) {
      final retryAfter = _nextDayStart(today).difference(now);
      throw DailyQuotaExceeded(principalId, retryAfter);
    }

    state.calls += 1;
  }

  /// The start-of-day instant for [t], preserving [t]'s zone (UTC instants
  /// truncate to UTC midnight, local instants to local midnight) so a
  /// UTC-driven deployment resets at UTC midnight.
  DateTime _startOfDay(DateTime t) => t.isUtc
      ? DateTime.utc(t.year, t.month, t.day)
      : DateTime(t.year, t.month, t.day);

  /// The start of the day *after* [dayStart]. `day + 1` lets Dart's `DateTime`
  /// constructor normalise month / year rollover.
  DateTime _nextDayStart(DateTime dayStart) => dayStart.isUtc
      ? DateTime.utc(dayStart.year, dayStart.month, dayStart.day + 1)
      : DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
}
