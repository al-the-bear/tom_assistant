// E.29 — Per-principal token-bucket rate-limiter conformance tests.
//
// What this file locks (proto spec § 8; AC-4):
//
//   1. `RateLimitPolicy` validates its parameters (capacity >= 1,
//      refillTokens > 0, refillPeriod > 0) — a misconfigured bucket is a
//      loud construction error, not a silently broken throttle.
//   2. A fresh bucket starts full: the first `capacity` requests pass, the
//      `capacity + 1`-th throws `RateLimitExceeded`.
//   3. Buckets are per-principal: one principal's exhaustion does not affect
//      another's bucket.
//   4. Refill is continuous and wall-clock-driven: advancing the injected
//      clock by one refill period restores one token; a long idle interval
//      refills to (but never beyond) `capacity`.
//   5. `RateLimitExceeded.retryAfter` is finite, strictly positive, and
//      consistent with the refill rate; a rejected request is not charged
//      (it does not push the retry window further out).
//   6. State is persisted per principal across calls (the bucket is reused,
//      not re-created) — proven by the burst-then-block sequence.
//   7. A non-empty `principalId` is required; an empty id is an argument
//      error (it would collapse all callers into one shared bucket).
//   8. The `429` status constant and the graceful Telegram message are the
//      single channel-mapping sources, and the whole surface reaches through
//      the package barrel — a consumer never imports the `src/` file.
//   9. The principal id (non-secret) may appear in `toString()`; there is no
//      token to leak (the limiter never sees the bearer token).

import 'package:test/test.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';

/// A controllable clock for deterministic refill assertions.
class _FakeClock {
  DateTime _now;
  _FakeClock(this._now);

  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

RateLimitPolicy _policy({
  int capacity = 3,
  double refillTokens = 1,
  Duration refillPeriod = const Duration(seconds: 1),
}) =>
    RateLimitPolicy(
      capacity: capacity,
      refillTokens: refillTokens,
      refillPeriod: refillPeriod,
    );

void main() {
  group('E.29 RateLimitPolicy validation', () {
    test('accepts a well-formed policy', () {
      final p = _policy(capacity: 5, refillTokens: 2, refillPeriod: const Duration(seconds: 3));
      expect(p.capacity, equals(5));
      expect(p.refillTokens, equals(2));
      expect(p.refillPeriod, equals(const Duration(seconds: 3)));
    });

    test('rejects capacity < 1', () {
      expect(() => _policy(capacity: 0), throwsArgumentError);
    });

    test('rejects refillTokens <= 0', () {
      expect(() => _policy(refillTokens: 0), throwsArgumentError);
      expect(() => _policy(refillTokens: -1), throwsArgumentError);
    });

    test('rejects a non-positive refillPeriod', () {
      expect(() => _policy(refillPeriod: Duration.zero), throwsArgumentError);
      expect(
        () => _policy(refillPeriod: const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });

  group('E.29 burst allowance (fresh bucket starts full)', () {
    test('first `capacity` requests pass, the next throws', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(policy: _policy(capacity: 3), clock: clock.now);

      // capacity == 3 → three requests at the same instant pass.
      limiter.check('alice');
      limiter.check('alice');
      limiter.check('alice');

      // Fourth at the same instant exceeds.
      expect(
        () => limiter.check('alice'),
        throwsA(isA<RateLimitExceeded>()
            .having((e) => e.principalId, 'principalId', 'alice')),
      );
    });

    test('capacity == 1 allows exactly one request per refill period', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(
        policy: _policy(capacity: 1, refillTokens: 1, refillPeriod: const Duration(seconds: 1)),
        clock: clock.now,
      );

      limiter.check('bob');
      expect(() => limiter.check('bob'), throwsA(isA<RateLimitExceeded>()));

      clock.advance(const Duration(seconds: 1));
      limiter.check('bob'); // one token refilled
      expect(() => limiter.check('bob'), throwsA(isA<RateLimitExceeded>()));
    });
  });

  group('E.29 per-principal isolation', () {
    test("one principal's exhaustion does not affect another's", () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(policy: _policy(capacity: 2), clock: clock.now);

      limiter.check('alice');
      limiter.check('alice');
      expect(() => limiter.check('alice'), throwsA(isA<RateLimitExceeded>()));

      // Bob's bucket is untouched.
      limiter.check('bob');
      limiter.check('bob');
      expect(() => limiter.check('bob'), throwsA(isA<RateLimitExceeded>()));
    });
  });

  group('E.29 continuous refill', () {
    test('advancing one refill period restores one token', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(
        policy: _policy(capacity: 1, refillTokens: 1, refillPeriod: const Duration(seconds: 2)),
        clock: clock.now,
      );

      limiter.check('alice'); // drains the single token
      expect(() => limiter.check('alice'), throwsA(isA<RateLimitExceeded>()));

      clock.advance(const Duration(seconds: 2)); // exactly one token back
      limiter.check('alice');
    });

    test('partial refill is insufficient until a full token accrues', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(
        policy: _policy(capacity: 1, refillTokens: 1, refillPeriod: const Duration(seconds: 10)),
        clock: clock.now,
      );

      limiter.check('alice');
      clock.advance(const Duration(seconds: 5)); // only half a token
      expect(() => limiter.check('alice'), throwsA(isA<RateLimitExceeded>()));

      clock.advance(const Duration(seconds: 5)); // now a full token
      limiter.check('alice');
    });

    test('a long idle interval refills to capacity but never beyond', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(
        policy: _policy(capacity: 3, refillTokens: 1, refillPeriod: const Duration(seconds: 1)),
        clock: clock.now,
      );

      // Drain the bucket.
      limiter.check('alice');
      limiter.check('alice');
      limiter.check('alice');
      expect(() => limiter.check('alice'), throwsA(isA<RateLimitExceeded>()));

      // Idle for an hour — far more than capacity worth of refill.
      clock.advance(const Duration(hours: 1));

      // Exactly `capacity` (3) requests pass, no more — the bucket is capped.
      limiter.check('alice');
      limiter.check('alice');
      limiter.check('alice');
      expect(() => limiter.check('alice'), throwsA(isA<RateLimitExceeded>()));
    });

    test('a backwards clock does not drain or credit the bucket', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(policy: _policy(capacity: 2), clock: clock.now);

      limiter.check('alice'); // 1 token left
      clock.advance(const Duration(seconds: -30)); // clock goes backwards
      // Still one token available; should pass without a spurious refill.
      limiter.check('alice');
      expect(() => limiter.check('alice'), throwsA(isA<RateLimitExceeded>()));
    });
  });

  group('E.29 retryAfter', () {
    test('is finite, strictly positive, and matches the refill rate', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(
        policy: _policy(capacity: 1, refillTokens: 1, refillPeriod: const Duration(seconds: 4)),
        clock: clock.now,
      );

      limiter.check('alice'); // drains to 0 tokens
      try {
        limiter.check('alice');
        fail('expected RateLimitExceeded');
      } on RateLimitExceeded catch (e) {
        // Need one full token; at 1 token / 4s that is ~4s.
        expect(e.retryAfter, greaterThan(Duration.zero));
        expect(e.retryAfter, equals(const Duration(seconds: 4)));
      }
    });

    test('a rejected request is not charged (window does not slide out)', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 12));
      final limiter = RateLimiter(
        policy: _policy(capacity: 1, refillTokens: 1, refillPeriod: const Duration(seconds: 4)),
        clock: clock.now,
      );

      limiter.check('alice'); // 0 tokens
      // Two rejections at t0; the second's retryAfter must not be larger than
      // the first's (a charged rejection would push it out).
      late Duration first;
      late Duration second;
      try {
        limiter.check('alice');
      } on RateLimitExceeded catch (e) {
        first = e.retryAfter;
      }
      try {
        limiter.check('alice');
      } on RateLimitExceeded catch (e) {
        second = e.retryAfter;
      }
      expect(second, equals(first));
    });
  });

  group('E.29 argument validation', () {
    test('an empty principalId is rejected', () {
      final limiter = RateLimiter(policy: _policy());
      expect(() => limiter.check(''), throwsArgumentError);
    });
  });

  group('E.29 channel-mapping constants + barrel surface', () {
    test('rate-limit status is 429', () {
      expect(rateLimitHttpStatus, equals(429));
    });

    test('the graceful Telegram message is non-empty and user-facing', () {
      expect(telegramRateLimitMessage, isNotEmpty);
      expect(telegramRateLimitMessage.toLowerCase(), contains('slow down'));
    });

    test('the whole surface reaches through the package barrel', () {
      // All E.29 symbols resolve from the package import alone.
      final policy = RateLimitPolicy(
        capacity: 1,
        refillTokens: 1,
        refillPeriod: const Duration(seconds: 1),
      );
      final limiter = RateLimiter(policy: policy);
      expect(limiter.policy, same(policy));
      const RateLimitExceeded('p', Duration(seconds: 1));
    });

    test('toString carries the non-secret principal id and the wait', () {
      const e = RateLimitExceeded('alice', Duration(milliseconds: 250));
      expect(e.toString(), contains('alice'));
      expect(e.toString(), contains('250'));
    });
  });
}
