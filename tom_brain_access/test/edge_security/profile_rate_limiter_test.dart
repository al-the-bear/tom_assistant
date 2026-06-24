// Step 5 (session_configuration_plan.md) — `ProfileRateLimiter` is the
// per-(principal, profileId) burst gate that composes a profile's `rateLimits`
// with the global per-principal limiter by being a *second* gate (SC-8 /
// SCP-19). These tests pin the limiter in isolation:
//
//   * a profile with no per-minute limit (`rateLimits == null` or
//     `requestsPerMinute == null`) is a no-op — it never throws, however many
//     requests pass through (the default profile, SC-5);
//   * a profile with `requestsPerMinute: N` admits N then throws the *existing*
//     `RateLimitExceeded` (so the channel `429` mapping is unchanged);
//   * the bucket is keyed on `(principal, profileId)` — a second principal and a
//     second profile each get their own fresh allowance;
//   * tokens refill over the 60 s window;
//   * `clear()` drops all state.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// A profile whose only behavioural knob is its per-minute rate limit (the rest
/// is the cognitive default), so the test isolates the limiter.
ResolvedProfile _profile(String id, {int? requestsPerMinute}) => ResolvedProfile(
      id: id,
      mode: ProfileMode.cognitive,
      entryProcedure: 'prompt_analyzer_v1',
      rateLimits: requestsPerMinute == null
          ? null
          : ProfileRateLimits(requestsPerMinute: requestsPerMinute),
    );

void main() {
  group('ProfileRateLimiter — per-(principal, profileId) burst gate', () {
    test('a profile with no rate limit is a no-op (SC-5 default profile)', () {
      final limiter = ProfileRateLimiter(clock: () => DateTime.utc(2026, 6, 2));
      final profile = _profile('default'); // rateLimits == null

      // Far more requests than any bucket would admit — none throws.
      for (var i = 0; i < 1000; i++) {
        limiter.check('principal-1', profile);
      }
      // No bucket is ever created for a limitless profile.
      expect(limiter.profileCount, 0);
    });

    test('a null requestsPerMinute (limits set, rpm unset) is a no-op', () {
      final limiter = ProfileRateLimiter(clock: () => DateTime.utc(2026, 6, 2));
      final profile = ResolvedProfile(
        id: 'concurrent-only',
        mode: ProfileMode.cognitive,
        entryProcedure: 'prompt_analyzer_v1',
        // Only the concurrency knob is set; the per-minute gate stays open.
        rateLimits: const ProfileRateLimits(concurrentRuns: 2),
      );

      for (var i = 0; i < 100; i++) {
        limiter.check('principal-1', profile);
      }
      expect(limiter.profileCount, 0);
    });

    test('admits requestsPerMinute then throws RateLimitExceeded', () {
      final limiter = ProfileRateLimiter(clock: () => DateTime.utc(2026, 6, 2));
      final profile = _profile('research', requestsPerMinute: 2);

      limiter.check('principal-1', profile); // 1st — ok
      limiter.check('principal-1', profile); // 2nd — ok
      expect(
        () => limiter.check('principal-1', profile), // 3rd — over
        throwsA(isA<RateLimitExceeded>()
            .having((e) => e.principalId, 'principalId', 'principal-1')
            .having((e) => e.retryAfter, 'retryAfter', greaterThan(Duration.zero))),
      );
      expect(limiter.profileCount, 1);
    });

    test('the bucket is keyed on the principal — a second principal is fresh',
        () {
      final limiter = ProfileRateLimiter(clock: () => DateTime.utc(2026, 6, 2));
      final profile = _profile('research', requestsPerMinute: 1);

      limiter.check('principal-1', profile); // exhausts principal-1
      expect(() => limiter.check('principal-1', profile),
          throwsA(isA<RateLimitExceeded>()));

      // A different principal under the same profile has its own allowance.
      limiter.check('principal-2', profile);
      expect(() => limiter.check('principal-2', profile),
          throwsA(isA<RateLimitExceeded>()));
    });

    test('the bucket is keyed on the profile — a second profile is fresh', () {
      final limiter = ProfileRateLimiter(clock: () => DateTime.utc(2026, 6, 2));
      final research = _profile('research', requestsPerMinute: 1);
      final planning = _profile('planning', requestsPerMinute: 1);

      limiter.check('principal-1', research); // exhausts (principal-1, research)
      expect(() => limiter.check('principal-1', research),
          throwsA(isA<RateLimitExceeded>()));

      // The same principal under a different profile has its own allowance.
      limiter.check('principal-1', planning);
      expect(() => limiter.check('principal-1', planning),
          throwsA(isA<RateLimitExceeded>()));
      expect(limiter.profileCount, 2);
    });

    test('tokens refill over the 60 s window', () {
      var now = DateTime.utc(2026, 6, 2, 12);
      final limiter = ProfileRateLimiter(clock: () => now);
      final profile = _profile('research', requestsPerMinute: 1);

      limiter.check('principal-1', profile); // ok
      expect(() => limiter.check('principal-1', profile),
          throwsA(isA<RateLimitExceeded>()));

      // Advance past one full refill period — one token is back.
      now = now.add(const Duration(minutes: 1));
      limiter.check('principal-1', profile); // ok again
    });

    test('clear() drops all bucket state', () {
      final limiter = ProfileRateLimiter(clock: () => DateTime.utc(2026, 6, 2));
      final profile = _profile('research', requestsPerMinute: 1);

      limiter.check('principal-1', profile);
      expect(limiter.profileCount, 1);

      limiter.clear();
      expect(limiter.profileCount, 0);
      // After a clear the (principal, profile) is full again.
      limiter.check('principal-1', profile);
    });
  });
}
