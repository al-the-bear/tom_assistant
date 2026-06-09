// E.30 — Per-principal daily LLM-call quota conformance tests.
//
// What this file locks (proto spec § 8; AC-4):
//
//   1. `DailyQuotaPolicy` validates its parameter (dailyCap >= 1) — a
//      misconfigured cap is a loud construction error, not a silently broken
//      gate.
//   2. A fresh quota admits exactly `dailyCap` calls within a day: the first
//      `dailyCap` requests pass, the `dailyCap + 1`-th throws
//      `DailyQuotaExceeded`.
//   3. Counters are per-principal: one principal's exhaustion does not affect
//      another's quota.
//   4. The counter resets on the calendar-day boundary: advancing the
//      injected clock past midnight refreshes the full allowance; advancing
//      *within* the same day does not.
//   5. `DailyQuotaExceeded.retryAfter` is finite, strictly positive, and is
//      the wait until the next day boundary; a rejected request is not
//      counted (it does not climb the count past `dailyCap`, so the reset
//      window does not slide out).
//   6. State is per principal across calls (the counter is reused, not
//      re-created) — proven by the spend-then-block sequence.
//   7. A non-empty `principalId` is required; an empty id is an argument
//      error (it would collapse all callers into one shared quota).
//   8. The `429` status constant (shared with the rate limiter) and the
//      graceful Telegram message are the single channel-mapping sources, and
//      the whole surface reaches through the package barrel — a consumer never
//      imports the `src/` file.
//   9. The principal id (non-secret) may appear in `toString()`; there is no
//      token to leak (the quota never sees the bearer token).
//  10. The day boundary honours the clock's zone — a UTC clock resets at UTC
//      midnight.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

/// A controllable clock for a deterministic day boundary.
class _FakeClock {
  DateTime _now;
  _FakeClock(this._now);

  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
  void set(DateTime t) => _now = t;
}

DailyQuotaPolicy _policy({int dailyCap = 3}) =>
    DailyQuotaPolicy(dailyCap: dailyCap);

void main() {
  group('E.30 DailyQuotaPolicy validation', () {
    test('accepts a well-formed policy', () {
      final p = _policy(dailyCap: 5);
      expect(p.dailyCap, equals(5));
    });

    test('rejects dailyCap < 1', () {
      expect(() => _policy(dailyCap: 0), throwsArgumentError);
      expect(() => _policy(dailyCap: -1), throwsArgumentError);
    });
  });

  group('E.30 daily allowance', () {
    test('admits exactly dailyCap calls, then throws', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 3), clock: clock.now);

      // First three within the same day pass.
      limiter.check('p1');
      limiter.check('p1');
      limiter.check('p1');

      // The fourth, still within the same day, is over the cap.
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));
    });

    test('a cap of 1 admits exactly one call per day', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);

      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));
    });
  });

  group('E.30 per-principal isolation', () {
    test("one principal's exhaustion leaves another's quota intact", () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 2), clock: clock.now);

      limiter.check('p1');
      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));

      // p2 has its own untouched allowance.
      limiter.check('p2');
      limiter.check('p2');
      expect(() => limiter.check('p2'), throwsA(isA<DailyQuotaExceeded>()));
    });
  });

  group('E.30 day-boundary reset', () {
    test('crossing midnight refreshes the full allowance', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 23));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 2), clock: clock.now);

      limiter.check('p1');
      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));

      // Advance two hours — now it is the next calendar day.
      clock.advance(const Duration(hours: 2)); // 2026-06-03 01:00
      limiter.check('p1');
      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));
    });

    test('advancing within the same day does not reset', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 1));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 2), clock: clock.now);

      limiter.check('p1');
      clock.advance(const Duration(hours: 20)); // still 2026-06-02 21:00
      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));
    });

    test('a backwards clock landing on a different day resets', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);

      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));

      // Clock jumps back to the previous day — a different day, so reset.
      clock.set(DateTime(2026, 6, 1, 9));
      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));
    });
  });

  group('E.30 retryAfter', () {
    test('is finite, strictly positive, and the wait until next midnight', () {
      // Local clock at 22:00 — 2 hours until next local midnight.
      final clock = _FakeClock(DateTime(2026, 6, 2, 22));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);

      limiter.check('p1');
      DailyQuotaExceeded? caught;
      try {
        limiter.check('p1');
      } on DailyQuotaExceeded catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.principalId, equals('p1'));
      expect(caught.retryAfter, greaterThan(Duration.zero));
      expect(caught.retryAfter, equals(const Duration(hours: 2)));
    });

    test('a rejected request is not counted (window does not slide)', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 22));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);

      limiter.check('p1');

      Duration retryAfterFirst() {
        try {
          limiter.check('p1');
        } on DailyQuotaExceeded catch (e) {
          return e.retryAfter;
        }
        fail('expected DailyQuotaExceeded');
      }

      // Two rejections at the same instant give the same retryAfter — the
      // rejected calls did not advance the counter or the window.
      expect(retryAfterFirst(), equals(retryAfterFirst()));
    });
  });

  group('E.30 UTC day boundary', () {
    test('a UTC clock resets at UTC midnight', () {
      final clock = _FakeClock(DateTime.utc(2026, 6, 2, 23));
      final limiter = DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);

      limiter.check('p1');
      DailyQuotaExceeded? caught;
      try {
        limiter.check('p1');
      } on DailyQuotaExceeded catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      // 1 hour until UTC midnight.
      expect(caught!.retryAfter, equals(const Duration(hours: 1)));

      clock.advance(const Duration(hours: 2)); // 2026-06-03 01:00 UTC
      limiter.check('p1'); // fresh day
    });
  });

  group('E.30 argument validation', () {
    test('rejects an empty principalId', () {
      final limiter = DailyQuotaLimiter(policy: _policy());
      expect(() => limiter.check(''), throwsArgumentError);
    });
  });

  group('E.30 channel-mapping constants + barrel surface', () {
    test('quotaHttpStatus is 429 (shared with the rate limiter)', () {
      expect(quotaHttpStatus, equals(429));
      expect(quotaHttpStatus, equals(rateLimitHttpStatus));
    });

    test('the graceful Telegram quota message is exposed', () {
      expect(telegramQuotaMessage, isNotEmpty);
      expect(telegramQuotaMessage.toLowerCase(), contains('daily'));
    });

    test('every public symbol reaches through the package barrel', () {
      final policy = DailyQuotaPolicy(dailyCap: 1);
      final limiter = DailyQuotaLimiter(policy: policy);
      const exceeded = DailyQuotaExceeded('p1', Duration(hours: 1));
      expect(policy.dailyCap, equals(1));
      expect(limiter.policy, same(policy));
      expect(exceeded.principalId, equals('p1'));
    });

    test('toString carries the non-secret principal id and the wait', () {
      const exceeded = DailyQuotaExceeded('principal-42', Duration(hours: 3));
      final s = exceeded.toString();
      expect(s, contains('principal-42'));
      expect(s, contains('DailyQuotaExceeded'));
      expect(s, contains('180m'));
    });
  });

  group('E.30 map-bound seams (G.3.3)', () {
    test('principalCount tracks the number of distinct principals seen', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter =
          DailyQuotaLimiter(policy: _policy(dailyCap: 5), clock: clock.now);

      expect(limiter.principalCount, 0);
      limiter.check('p1');
      limiter.check('p1'); // same principal — no new entry
      expect(limiter.principalCount, 1);
      limiter.check('p2');
      expect(limiter.principalCount, 2);
    });

    test('clear() drops every counter; allowance is fresh afterwards', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter =
          DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);

      limiter.check('p1');
      expect(() => limiter.check('p1'), throwsA(isA<DailyQuotaExceeded>()));

      limiter.clear();
      expect(limiter.principalCount, 0);
      // A fresh day's allowance — the same instant now admits again.
      limiter.check('p1');
      expect(limiter.principalCount, 1);
    });

    test('sweepStale() evicts only counters from an earlier day', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter =
          DailyQuotaLimiter(policy: _policy(dailyCap: 5), clock: clock.now);

      limiter.check('yesterday'); // counter pinned to 2026-06-02
      clock.set(DateTime(2026, 6, 3, 9)); // a new day
      limiter.check('today'); // counter pinned to 2026-06-03
      expect(limiter.principalCount, 2);

      final evicted = limiter.sweepStale();
      expect(evicted, 1);
      expect(limiter.principalCount, 1);
      // The surviving counter is the current-day one — it still blocks at cap.
      // (cap is 5, so it would still admit; we only assert it survived.)
    });

    test('sweepStale() on an all-current map evicts nothing', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter =
          DailyQuotaLimiter(policy: _policy(dailyCap: 5), clock: clock.now);

      limiter.check('p1');
      limiter.check('p2');
      expect(limiter.sweepStale(), 0);
      expect(limiter.principalCount, 2);
    });
  });

  group('E.30 snapshot/restore', () {
    test('snapshot() is empty for an untouched limiter', () {
      final limiter = DailyQuotaLimiter(policy: _policy());
      expect(limiter.snapshot(), isEmpty);
    });

    test('snapshot() captures the call count and day per principal', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter =
          DailyQuotaLimiter(policy: _policy(dailyCap: 5), clock: clock.now);
      limiter.check('a');
      limiter.check('a');
      limiter.check('b');

      final snap = limiter.snapshot();
      expect(snap.keys.toSet(), {'a', 'b'});
      expect(snap['a']!.calls, 2);
      expect(snap['a']!.dayStart, DateTime(2026, 6, 2));
      expect(snap['b']!.calls, 1);
    });

    test('snapshotOf() returns one principal, or null when unseen', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final limiter =
          DailyQuotaLimiter(policy: _policy(dailyCap: 5), clock: clock.now);
      limiter.check('a');
      expect(limiter.snapshotOf('a')!.calls, 1);
      expect(limiter.snapshotOf('missing'), isNull);
    });

    test('restore() seeds state a fresh limiter resumes from', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final source =
          DailyQuotaLimiter(policy: _policy(dailyCap: 2), clock: clock.now);
      source.check('p'); // 1
      source.check('p'); // 2 — at cap
      final snap = source.snapshot();

      // A brand-new limiter (as after a restart) restored from the snapshot.
      final restored =
          DailyQuotaLimiter(policy: _policy(dailyCap: 2), clock: clock.now);
      restored.restore(snap);
      // At the same instant the restored principal is exhausted, not fresh.
      expect(() => restored.check('p'), throwsA(isA<DailyQuotaExceeded>()));
    });

    test('restore() lets a crossed day boundary reset the counter lazily', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 23));
      final source =
          DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);
      source.check('p'); // exhausted for 2026-06-02
      final snap = source.snapshot();

      final restored =
          DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);
      restored.restore(snap);
      // A day of "downtime" passes before the next check: the restored
      // counter belongs to yesterday, so the next day's allowance is fresh.
      clock.advance(const Duration(hours: 2)); // 2026-06-03 01:00
      restored.check('p');
      expect(() => restored.check('p'), throwsA(isA<DailyQuotaExceeded>()));
    });

    test('restore() clamps calls to the current cap', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final restored =
          DailyQuotaLimiter(policy: _policy(dailyCap: 3), clock: clock.now);
      restored.restore({
        'p': QuotaSnapshot(calls: 99, dayStart: DateTime(2026, 6, 2)),
      });
      // A bloated count from a since-shrunk cap cannot grant extra calls — the
      // principal is simply at (or above) the cap, so it is blocked.
      expect(() => restored.check('p'), throwsA(isA<DailyQuotaExceeded>()));
    });

    test('restore() rejects an empty principalId', () {
      final limiter = DailyQuotaLimiter(policy: _policy());
      expect(
        () => limiter.restore(
            {'': QuotaSnapshot(calls: 1, dayStart: DateTime(2026, 6, 2))}),
        throwsArgumentError,
      );
    });

    test('QuotaSnapshot value equality is by moment, not zone', () {
      final utc = DateTime.utc(2026, 6, 2);
      final a = QuotaSnapshot(calls: 2, dayStart: utc);
      final b = QuotaSnapshot(calls: 2, dayStart: utc.toLocal());
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('E.30 store-backed persistence (P1.4)', () {
    test('counter survives a restart through the store', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final store = MapEdgeStateStore();
      final before = DailyQuotaLimiter(
          policy: _policy(dailyCap: 2), clock: clock.now, store: store);
      before.check('p'); // 1
      before.check('p'); // 2 — at cap

      // A fresh limiter over the same store (a restart), same instant.
      final after = DailyQuotaLimiter(
          policy: _policy(dailyCap: 2), clock: clock.now, store: store);
      // The counter is resumed at the cap — the restart did not reset it.
      expect(() => after.check('p'), throwsA(isA<DailyQuotaExceeded>()));
    });

    test('a restart near the day boundary cannot reset the daily cap', () {
      // The exact bypass P1.4 closes: cap 1, exhausted at 23:00, then a restart
      // a minute later must NOT grant a fresh allowance within the same day.
      final clock = _FakeClock(DateTime(2026, 6, 2, 23));
      final store = MapEdgeStateStore();
      final before = DailyQuotaLimiter(
          policy: _policy(dailyCap: 1), clock: clock.now, store: store);
      before.check('p'); // day's single call spent

      clock.advance(const Duration(minutes: 1)); // 23:01, still 2026-06-02
      final after = DailyQuotaLimiter(
          policy: _policy(dailyCap: 1), clock: clock.now, store: store);
      // Still exhausted — the restart did not hand out a second allowance.
      expect(() => after.check('p'), throwsA(isA<DailyQuotaExceeded>()));

      // The genuine next day still refreshes the allowance.
      clock.advance(const Duration(hours: 2)); // 2026-06-03 01:01
      after.check('p');
    });

    test('with no store, counters do not persist across instances', () {
      final clock = _FakeClock(DateTime(2026, 6, 2, 9));
      final before =
          DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);
      before.check('p');
      expect(() => before.check('p'), throwsA(isA<DailyQuotaExceeded>()));

      // A fresh limiter with no shared store starts the day fresh again.
      final after =
          DailyQuotaLimiter(policy: _policy(dailyCap: 1), clock: clock.now);
      after.check('p'); // fresh allowance
    });
  });
}
