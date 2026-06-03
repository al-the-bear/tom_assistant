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
// Persistence. A daily cap demands cross-restart durability — a restart at
// 23:00 must not hand every principal a fresh day's allowance, which would be a
// trivial bypass of the cap (Q-E.30.1 / P1.4). When an [EdgeStateStore] is
// supplied the limiter restores every counter from it on construction and
// writes the snapshot back after each admitted call, so a process restart
// resumes the counters at the point they stopped — and the lazy day-rollover in
// [check] still resets a restored counter that belongs to an earlier day, so a
// genuine new day refreshes the allowance while a restart within the same day
// does not. When no store is supplied the counter map lives only in this
// object's memory and a restart resets it (the original in-process behaviour).
// Either way "per principal" is honoured within the process: a principal's
// counter survives across that principal's requests for the limiter's lifetime.
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

import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'edge_state_store.dart';
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

/// Immutable snapshot of one principal's quota state — the persistable form.
///
/// Captures exactly what [DailyQuotaLimiter] needs to resume a counter after a
/// process restart: the number of [calls] admitted so far and the [dayStart]
/// those calls belong to. Because the day-rollover reset is computed lazily on
/// the next [DailyQuotaLimiter.check] (the date portion of the clock is
/// compared against [dayStart]), a snapshot restored after downtime that
/// crosses a day boundary naturally resets to a fresh allowance — there is no
/// separate "catch-up" step. A caller persists these (via
/// [DailyQuotaLimiter.snapshot] / [DailyQuotaLimiter.snapshotOf]) and seeds them
/// back with [DailyQuotaLimiter.restore], so a restart near the day boundary
/// cannot hand a principal a second full allowance.
final class QuotaSnapshot {
  /// The number of admitted calls within [dayStart]'s calendar day.
  final int calls;

  /// The start-of-day instant [calls] belongs to.
  final DateTime dayStart;

  /// Builds a snapshot of [calls] admitted within [dayStart]'s day.
  const QuotaSnapshot({required this.calls, required this.dayStart});

  @override
  bool operator ==(Object other) =>
      other is QuotaSnapshot &&
      other.calls == calls &&
      other.dayStart.isAtSameMomentAs(dayStart);

  @override
  int get hashCode => Object.hash(calls, dayStart.microsecondsSinceEpoch);

  @override
  String toString() => 'QuotaSnapshot(calls: $calls, dayStart: $dayStart)';
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

  /// Optional durable backing for the counter map (P1.4). When present the
  /// limiter restores every counter from it on construction and writes the
  /// snapshot back after each admitted call; when `null` the counter map is
  /// in-process only and a restart resets it.
  final EdgeStateStore? _store;

  /// Builds a limiter over [policy]. [clock] defaults to [systemClock]. When
  /// [store] is supplied the counter map is restored from it immediately, so a
  /// limiter rebuilt after a restart resumes the persisted counters.
  DailyQuotaLimiter({
    required this.policy,
    DateTime Function()? clock,
    EdgeStateStore? store,
  })  : clock = clock ?? systemClock,
        _store = store {
    final store = _store;
    if (store != null) {
      restore(_decodeRows(store.load()));
    }
  }

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
    requireNonEmpty(principalId, 'principalId');

    final now = clock();
    final today = startOfDay(now);
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
      final retryAfter = nextDayStart(today).difference(now);
      throw DailyQuotaExceeded(principalId, retryAfter);
    }

    state.calls += 1;
    _store?.save(_encodeRows(snapshot()));
  }

  /// Decodes persisted store rows into the limiter's typed snapshot form.
  static Map<String, QuotaSnapshot> _decodeRows(
    Map<String, Map<String, Object?>> rows,
  ) =>
      <String, QuotaSnapshot>{
        for (final entry in rows.entries)
          entry.key: QuotaSnapshot(
            calls: (entry.value['calls'] as num).toInt(),
            dayStart: DateTime.parse(entry.value['dayStart'] as String),
          ),
      };

  /// Encodes the limiter's typed snapshot into JSON-able store rows. The
  /// `dayStart` instant is written as an ISO-8601 string that preserves its
  /// zone, so restore reconstructs the same day boundary.
  static Map<String, Map<String, Object?>> _encodeRows(
    Map<String, QuotaSnapshot> snapshot,
  ) =>
      <String, Map<String, Object?>>{
        for (final entry in snapshot.entries)
          entry.key: <String, Object?>{
            'calls': entry.value.calls,
            'dayStart': entry.value.dayStart.toIso8601String(),
          },
      };

  /// Number of principals with live quota state — for observability and as the
  /// seam an idle-eviction policy reads. The map grows by one entry per distinct
  /// principal and never shrinks on its own (Q-E.30.3); the bound is the
  /// configured credential set, made explicit here and via [clear] / [sweepStale]
  /// rather than left as an unwritten assumption (G.3.3).
  int get principalCount => _states.length;

  /// Drops all quota state; every principal starts a fresh day's allowance on
  /// its next [check]. The blunt eviction seam (a process restart already has
  /// this effect; this exposes it without one).
  void clear() => _states.clear();

  /// Snapshot of every live counter, keyed by the same `principalId` — the
  /// durable form. A caller persists these and restores them with [restore]
  /// after a process restart, so a restart near the day boundary cannot reset a
  /// principal's counter to a fresh allowance. An empty map when no principal
  /// has been seen.
  Map<String, QuotaSnapshot> snapshot() => <String, QuotaSnapshot>{
        for (final entry in _states.entries)
          entry.key: QuotaSnapshot(
            calls: entry.value.calls,
            dayStart: entry.value.dayStart,
          ),
      };

  /// Snapshot of a single [principalId]'s counter, or `null` when it has no
  /// live state. The single-key form a caller uses to persist incrementally —
  /// after one [check] for [principalId], write just that principal's row
  /// rather than the whole map.
  QuotaSnapshot? snapshotOf(String principalId) {
    final state = _states[principalId];
    if (state == null) return null;
    return QuotaSnapshot(calls: state.calls, dayStart: state.dayStart);
  }

  /// Seeds counter state from a previously taken [snapshot] (e.g. read from
  /// durable storage at boot).
  ///
  /// Each principal in [snapshot] overwrites any existing counter; principals
  /// absent from [snapshot] are left untouched. A restored count is clamped to
  /// `[0, dailyCap]` so a snapshot taken under a larger cap (a since-shrunk
  /// policy) cannot seed a counter that pretends to a larger allowance — at
  /// most it is exactly at the cap, which still blocks. Each `principalId` must
  /// be non-empty (the same invariant [check] enforces). The lazy day-rollover
  /// in [check] still applies: a restored counter from an earlier day resets to
  /// a fresh allowance on its owner's next [check].
  void restore(Map<String, QuotaSnapshot> snapshot) {
    snapshot.forEach((principalId, state) {
      requireNonEmpty(principalId, 'principalId');
      _states[principalId] = _QuotaState(
        state.calls.clamp(0, policy.dailyCap),
        state.dayStart,
      );
    });
  }

  /// Evicts the counters that no longer belong to the current day — every
  /// principal whose last [check] fell on an earlier day. Such a counter would
  /// be reset to zero on its owner's next [check] anyway, so dropping it changes
  /// no admission decision; it only reclaims the memory of principals that have
  /// gone idle across a day boundary. The targeted complement to [clear]: a
  /// periodic sweep (driven by the final-layer scheduler) keeps the map bounded
  /// by the *active* principal set rather than the all-time one.
  ///
  /// Returns the number of evicted counters.
  int sweepStale() {
    final today = startOfDay(clock());
    final stale = <String>[
      for (final entry in _states.entries)
        if (entry.value.dayStart != today) entry.key,
    ];
    for (final key in stale) {
      _states.remove(key);
    }
    return stale.length;
  }
}
