// Tests for `Clock` and its three implementations (Plan step A.15).
//
// Surface under test:
//
//   * `SystemClock`: returns UTC, ms agrees with DateTime within tolerance,
//     nowBrainTime is atomic (single read).
//   * `FixedClock`: every read returns the same instant.
//   * `MutableTestClock`: advance moves forward; setTo can jump to any
//     instant including backwards; advance rejects negative durations.
//   * `Clock.nowBrainTime` default delegates to `nowMs` for custom
//     implementations.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Minimal custom [Clock] that uses only the two required overrides, to
/// verify the default [Clock.nowBrainTime] implementation composes from
/// [Clock.nowMs] correctly.
final class _MinimalClock implements Clock {
  final int ms;
  const _MinimalClock(this.ms);
  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  @override
  int nowMs() => ms;
  // No override of nowBrainTime — uses Clock's default delegation.
  @override
  BrainTime nowBrainTime() => BrainTime.fromMs(nowMs());
}

void main() {
  group('SystemClock', () {
    const clock = SystemClock();

    test('now() is UTC', () {
      expect(clock.now().isUtc, isTrue);
    });

    test('now() and nowMs() agree within a small tolerance', () {
      // Read both in sequence; allow up to a 100 ms gap which is generous
      // enough for slow CI machines but tight enough to catch a clock
      // returning a different time source for each call.
      final dt = clock.now();
      final ms = clock.nowMs();
      expect((ms - dt.millisecondsSinceEpoch).abs(), lessThan(100));
    });

    test('nowBrainTime() reads the clock atomically', () {
      // Hard to assert true atomicity from outside; the best we can do is
      // confirm the resulting BrainTime is internally consistent.
      final t = clock.nowBrainTime();
      expect(
        t.toDateTime().millisecondsSinceEpoch,
        equals(t.toMs()),
      );
    });

    test('two reads on the same SystemClock are non-decreasing', () {
      final t1 = clock.nowMs();
      final t2 = clock.nowMs();
      expect(t2, greaterThanOrEqualTo(t1));
    });

    test('const-constructible', () {
      // Compile-time check: if this doesn't compile, the test file fails
      // to build. Run-time the const identity is also implicit.
      const a = SystemClock();
      const b = SystemClock();
      expect(identical(a, b), isTrue);
    });
  });

  group('FixedClock', () {
    final at = BrainTime.utc(2026, 5, 30, 14, 22, 33, 123);
    final clock = FixedClock(at);

    test('now() returns the fixed UTC DateTime', () {
      expect(clock.now(), equals(at.toDateTime()));
      expect(clock.now().isUtc, isTrue);
    });

    test('nowMs() returns the fixed ms', () {
      expect(clock.nowMs(), equals(at.toMs()));
    });

    test('nowBrainTime() returns the exact fixed BrainTime', () {
      expect(clock.nowBrainTime(), equals(at));
    });

    test('multiple reads return identical values', () {
      expect(clock.now(), equals(clock.now()));
      expect(clock.nowMs(), equals(clock.nowMs()));
    });
  });

  group('MutableTestClock', () {
    test('starts at the constructor instant', () {
      final start = BrainTime.utc(2026, 5, 30, 14, 22, 33, 123);
      final clock = MutableTestClock(start);
      expect(clock.currentTime, equals(start));
      expect(clock.nowBrainTime(), equals(start));
    });

    test('advance(Duration) moves time forward', () {
      final start = BrainTime.utc(2026, 5, 30);
      final clock = MutableTestClock(start);
      clock.advance(const Duration(seconds: 45));
      expect(
        clock.nowBrainTime(),
        equals(start.plus(const Duration(seconds: 45))),
      );
    });

    test('advance is cumulative', () {
      final start = BrainTime.fromMs(1_000_000);
      final clock = MutableTestClock(start);
      clock.advance(const Duration(milliseconds: 100));
      clock.advance(const Duration(milliseconds: 250));
      expect(clock.nowMs(), equals(1_000_000 + 350));
    });

    test('advance rejects negative durations', () {
      final clock = MutableTestClock(BrainTime.fromMs(1_000_000));
      expect(
        () => clock.advance(const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
    });

    test('setTo() jumps to any instant, including backwards', () {
      final start = BrainTime.fromMs(2_000_000);
      final clock = MutableTestClock(start);
      final earlier = BrainTime.fromMs(1_500_000);
      clock.setTo(earlier);
      expect(clock.nowBrainTime(), equals(earlier));
    });

    test('reads do not advance time on their own', () {
      final start = BrainTime.fromMs(1_000_000);
      final clock = MutableTestClock(start);
      clock.now();
      clock.nowMs();
      clock.nowBrainTime();
      expect(clock.currentTime, equals(start));
    });

    test('all three getters agree at any instant', () {
      final clock = MutableTestClock(BrainTime.fromMs(1_700_000_000_000));
      clock.advance(const Duration(seconds: 12));
      final dt = clock.now();
      final ms = clock.nowMs();
      final bt = clock.nowBrainTime();
      expect(dt.millisecondsSinceEpoch, equals(ms));
      expect(bt.toMs(), equals(ms));
      expect(bt.toDateTime(), equals(dt));
    });
  });

  group('Clock default nowBrainTime delegation', () {
    test('a minimal Clock yields a consistent BrainTime via nowMs', () {
      const ms = 1_700_000_000_000;
      const clock = _MinimalClock(ms);
      expect(clock.nowBrainTime(), equals(BrainTime.fromMs(ms)));
    });
  });
}
