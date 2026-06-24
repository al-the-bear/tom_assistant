// ProfileRateLimiter — the per-(principal, profileId) burst gate that composes
// a profile's `rateLimits` with the global per-principal limiter (SC-8, plan
// step 5; SCP-19).
//
// ── How "compose, taking the tighter bound" is realised ───────────────────
//
// The done-when asks the edge to "compose `profile.rateLimits` with the
// per-principal quota … taking the tighter bound, keyed on (principal,
// profileId)". This limiter is the *second* gate: `_admit` runs both the global
// `RateLimiter.check(principalId)` (E.29, keyed on principal alone) AND
// [check] (keyed on `(principal, profileId)`). A request must clear both, so
// the tighter bound governs with no explicit `min()` — exactly the SCP-19
// realisation.
//
// One [TokenBucket] per `profile.id` (a profile's resolved rpm is fixed at
// boot), inner-keyed on the non-secret `principalId`: capacity = refill = the
// profile's `requestsPerMinute` over a 60 s window (a per-profile burst of
// `rpm` with a sustained `rpm`/min refill). The bucket throws the *existing*
// [RateLimitExceeded] on exhaustion, so the channel edges' `429` mapping is
// unchanged.
//
// In-process only (no [EdgeStateStore]): a per-(principal, profileId) burst cap
// needs no durability — the durable long-horizon cap is the global daily quota
// (E.30). The resolved `rateLimits` is already clamped to the global ceiling by
// `ProfileRegistry.resolve` (SCP-12), so this enforces the already-effective
// per-profile value.
//
// `concurrentRuns` (the second `ProfileRateLimits` knob) is NOT enforced here —
// it needs a run-lifecycle acquire/release the edge has no seam for, and is
// deferred to step 8 (the per-run engine binding) per SCP-19.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show TokenBucket, TokenBucketPolicy, systemClock;
import 'package:tom_brain_shared/tom_brain_shared.dart' show ResolvedProfile;

import 'rate_limiter.dart' show RateLimitExceeded;

/// Per-(principal, profileId) request-per-minute burst gate (plan step 5).
///
/// Stateful — owns one [TokenBucket] per encountered `profile.id`, each
/// inner-keyed on `principalId`. Created lazily; never evicted in the prototype
/// (the profile set is small and bounded by configuration).
final class ProfileRateLimiter {
  /// One bucket per `profile.id`; the bucket's keys are `principalId`s.
  final Map<String, TokenBucket> _bucketsByProfile = <String, TokenBucket>{};

  /// Time source shared with the rest of the edge (deterministic in tests).
  final DateTime Function() _clock;

  /// Builds the limiter. [clock] defaults to [systemClock]; boot passes the
  /// access layer's shared clock so refill is consistent with the other edge
  /// limiters and deterministic under a fixed test clock.
  ProfileRateLimiter({DateTime Function()? clock}) : _clock = clock ?? systemClock;

  /// Charges one token to [principalId]'s bucket for [profile].
  ///
  /// No-op when the profile sets no per-minute rate limit
  /// (`profile.rateLimits == null` or `requestsPerMinute == null` — the default
  /// profile, SC-5: nothing changes). Otherwise takes one token from the
  /// `(principal, profileId)` bucket and returns normally when it can afford it,
  /// or throws [RateLimitExceeded] (the same type the global limiter throws, so
  /// the `429` mapping is shared) carrying the wait until one token refills.
  ///
  /// [principalId] must be non-empty (the bucket rejects an empty key — an empty
  /// id would collapse callers into one bucket).
  void check(String principalId, ResolvedProfile profile) {
    final int? rpm = profile.rateLimits?.requestsPerMinute;
    if (rpm == null) {
      return;
    }
    final TokenBucket bucket = _bucketsByProfile.putIfAbsent(
      profile.id,
      () => TokenBucket(
        policy: TokenBucketPolicy(
          capacity: rpm,
          refillTokens: rpm.toDouble(),
          refillPeriod: const Duration(minutes: 1),
        ),
        clock: _clock,
      ),
    );
    final Duration? retryAfter = bucket.tryTake(principalId);
    if (retryAfter != null) {
      throw RateLimitExceeded(principalId, retryAfter);
    }
  }

  /// Number of distinct profiles with live bucket state — observability.
  int get profileCount => _bucketsByProfile.length;

  /// Drops all bucket state; every (principal, profile) is full again on its
  /// next [check]. Test/eviction seam.
  void clear() => _bucketsByProfile.clear();
}
