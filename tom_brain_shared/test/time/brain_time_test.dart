// Tests for `BrainTime` (Plan step A.15).
//
// Surface under test:
//
//   * Construction: fromMs, fromDateTime, utc, parse, now(clock), epoch.
//   * Round-trip between ms and DateTime is lossless.
//   * UTC enforcement: fromDateTime rejects local-time inputs;
//     fromMs rejects negatives and out-of-range values.
//   * ISO-8601 round-trip via parse / toIso8601String.
//   * Arithmetic: plus / minus / difference.
//   * Ordering: compareTo + operators + isBefore/isAfter/isAtSameMomentAs.
//   * Equality and hash by ms value.
//   * Sort semantics on a List<BrainTime>.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('BrainTime construction', () {
    test('fromMs round-trips through toMs', () {
      final t = BrainTime.fromMs(1_700_000_000_000);
      expect(t.toMs(), equals(1_700_000_000_000));
    });

    test('fromMs rejects negative values', () {
      expect(() => BrainTime.fromMs(-1), throwsArgumentError);
    });

    test('fromMs rejects values beyond the 48-bit ULID bound', () {
      // 2^48 == 281_474_976_710_656; max accepted is 2^48 - 1.
      expect(() => BrainTime.fromMs(0x1000000000000), throwsArgumentError);
    });

    test('fromMs accepts the 48-bit upper bound exactly', () {
      final t = BrainTime.fromMs(0xFFFFFFFFFFFF);
      expect(t.toMs(), equals(0xFFFFFFFFFFFF));
    });

    test('fromDateTime accepts UTC', () {
      final dt = DateTime.utc(2026, 5, 30, 14, 22, 33, 123);
      final t = BrainTime.fromDateTime(dt);
      expect(t.toDateTime(), equals(dt));
    });

    test('fromDateTime rejects local time', () {
      final dt = DateTime(2026, 5, 30, 14, 22, 33);
      expect(() => BrainTime.fromDateTime(dt), throwsArgumentError);
    });

    test('utc helper builds from explicit components', () {
      final t = BrainTime.utc(2026, 5, 30, 14, 22, 33, 123);
      expect(
        t.toDateTime(),
        equals(DateTime.utc(2026, 5, 30, 14, 22, 33, 123)),
      );
    });

    test('epoch is 1970-01-01T00:00:00Z', () {
      expect(BrainTime.epoch.toMs(), equals(0));
      expect(
        BrainTime.epoch.toDateTime(),
        equals(DateTime.utc(1970, 1, 1)),
      );
    });
  });

  group('BrainTime round-trip', () {
    test('ms → DateTime → ms is lossless', () {
      const ms = 1_758_239_553_123;
      final t1 = BrainTime.fromMs(ms);
      final t2 = BrainTime.fromDateTime(t1.toDateTime());
      expect(t2.toMs(), equals(ms));
    });

    test('toDateTime always returns UTC', () {
      final t = BrainTime.fromMs(1_700_000_000_000);
      expect(t.toDateTime().isUtc, isTrue);
    });

    test('parse + toIso8601String round-trip', () {
      final original = BrainTime.utc(2026, 5, 30, 14, 22, 33, 123);
      final iso = original.toIso8601String();
      final parsed = BrainTime.parse(iso);
      expect(parsed, equals(original));
    });

    test('parse accepts an ISO string with trailing Z', () {
      final t = BrainTime.parse('2026-05-30T14:22:33.123Z');
      expect(t.toMs(), equals(DateTime.utc(2026, 5, 30, 14, 22, 33, 123)
          .millisecondsSinceEpoch));
    });

    test('parse normalises a local-suffix ISO string to UTC', () {
      // An ISO string with an explicit offset must round-trip into the
      // same absolute instant.
      final t = BrainTime.parse('2026-05-30T16:22:33.123+02:00');
      expect(
        t.toDateTime(),
        equals(DateTime.utc(2026, 5, 30, 14, 22, 33, 123)),
      );
    });
  });

  group('BrainTime arithmetic', () {
    test('plus advances by the duration', () {
      final t = BrainTime.fromMs(1_700_000_000_000);
      final t2 = t.plus(const Duration(seconds: 30));
      expect(t2.toMs(), equals(t.toMs() + 30_000));
    });

    test('minus moves backward by the duration', () {
      final t = BrainTime.fromMs(1_700_000_000_000);
      final t2 = t.minus(const Duration(minutes: 5));
      expect(t2.toMs(), equals(t.toMs() - 300_000));
    });

    test('difference is later − earlier as a positive Duration', () {
      final earlier = BrainTime.fromMs(1_700_000_000_000);
      final later = earlier.plus(const Duration(seconds: 90));
      expect(later.difference(earlier), equals(const Duration(seconds: 90)));
    });

    test('difference goes negative for the reversed argument order', () {
      final earlier = BrainTime.fromMs(1_700_000_000_000);
      final later = earlier.plus(const Duration(seconds: 90));
      expect(earlier.difference(later), equals(const Duration(seconds: -90)));
    });
  });

  group('BrainTime ordering', () {
    final a = BrainTime.fromMs(1_700_000_000_000);
    final b = BrainTime.fromMs(1_700_000_001_000);

    test('< / <= / > / >= match millisecond ordering', () {
      expect(a < b, isTrue);
      expect(a <= b, isTrue);
      expect(b > a, isTrue);
      expect(b >= a, isTrue);
      expect(a < a, isFalse);
      expect(a <= a, isTrue);
    });

    test('isBefore / isAfter / isAtSameMomentAs', () {
      expect(a.isBefore(b), isTrue);
      expect(b.isAfter(a), isTrue);
      expect(a.isAtSameMomentAs(BrainTime.fromMs(a.toMs())), isTrue);
    });

    test('compareTo and sort produce chronological order', () {
      final list = <BrainTime>[
        BrainTime.fromMs(3),
        BrainTime.fromMs(1),
        BrainTime.fromMs(2),
      ]..sort();
      expect(list.map((t) => t.toMs()).toList(), equals(<int>[1, 2, 3]));
    });
  });

  group('BrainTime equality', () {
    test('two instances with the same ms are equal', () {
      final t1 = BrainTime.fromMs(1_700_000_000_000);
      final t2 = BrainTime.fromMs(1_700_000_000_000);
      expect(t1, equals(t2));
      expect(t1.hashCode, equals(t2.hashCode));
    });

    test('different ms means unequal', () {
      final t1 = BrainTime.fromMs(1_700_000_000_000);
      final t2 = BrainTime.fromMs(1_700_000_000_001);
      expect(t1, isNot(equals(t2)));
    });

    test('identical short-circuit holds', () {
      final t = BrainTime.fromMs(1);
      expect(t == t, isTrue);
    });

    test('not equal to other types', () {
      // Cast to Object so the analyzer does not flag the deliberate
      // cross-type comparison (`unrelated_type_equality_checks`). The
      // intent of the test is precisely that `operator ==` rejects
      // non-BrainTime arguments.
      final t = BrainTime.fromMs(0);
      expect((t as Object) == 0, isFalse);
      expect((t as Object) == DateTime.utc(1970), isFalse);
    });
  });

  group('BrainTime toString', () {
    test('contains both forms', () {
      final t = BrainTime.utc(2026, 5, 30, 14, 22, 33, 123);
      final s = t.toString();
      expect(s, contains(t.toMs().toString()));
      expect(s, contains(t.toIso8601String()));
    });
  });

  group('BrainTime.now via Clock', () {
    test('reads through SystemClock', () {
      const clock = SystemClock();
      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      final t = BrainTime.now(clock);
      final after = DateTime.now().toUtc().millisecondsSinceEpoch;
      expect(t.toMs(), greaterThanOrEqualTo(before));
      expect(t.toMs(), lessThanOrEqualTo(after));
    });

    test('FixedClock returns a frozen instant', () {
      final fixed = BrainTime.utc(2026, 5, 30, 14, 22, 33, 123);
      final clock = FixedClock(fixed);
      expect(BrainTime.now(clock), equals(fixed));
      expect(BrainTime.now(clock), equals(fixed));
    });
  });
}
