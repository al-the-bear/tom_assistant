// Tests for TimestampId (logging-spec §3) — the bare UTC-timestamp id of the
// form `YYMMDD-HHMMSS.ssssss` (microsecond precision) that backs both `TurnId`
// and the access-layer `sessionId`.
//
// The two load-bearing properties:
//
//   * lexicographic order == chronological order (the trail-cap janitor relies
//     on this), guaranteed by a fixed-width zero-padded layout;
//   * uniqueness without a random/counter suffix, achieved by a monotonic
//     generator that advances to the next free microsecond on collision.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('TimestampId.generate', () {
    test('produces the canonical YYMMDD-HHMMSS.ssssss form', () {
      final id = TimestampId.generate();
      expect(id.value, matches(RegExp(r'^\d{6}-\d{6}\.\d{6}$')));
      expect(TimestampId.isValid(id.value), isTrue);
    });

    test('is strictly monotonic across a tight burst', () {
      const n = 5000;
      final values = <String>[];
      for (var i = 0; i < n; i++) {
        values.add(TimestampId.generate().value);
      }
      expect(values.toSet().length, equals(n), reason: 'all unique');
      final sorted = [...values]..sort();
      expect(values, equals(sorted),
          reason: 'monotonic: generated order == lexicographic order');
    });

    test('encodes the supplied instant exactly', () {
      final at = DateTime.fromMicrosecondsSinceEpoch(
        DateTime.utc(2026, 6, 8, 19, 3, 16).microsecondsSinceEpoch + 402355,
        isUtc: true,
      );
      final id = TimestampId.generate(at: at);
      expect(id.value, equals('260608-190316.402355'));
    });

    test('supplied-instant path does not perturb the monotonic clock', () {
      // A far-past explicit instant must not drag the high-water mark backwards.
      final past = DateTime.utc(2001, 1, 1);
      TimestampId.generate(at: past);
      final a = TimestampId.generate().value;
      final b = TimestampId.generate().value;
      expect(b.compareTo(a), greaterThan(0));
    });
  });

  group('TimestampId.format', () {
    test('pads every field to fixed width', () {
      final micros = DateTime.utc(2026, 1, 2, 3, 4, 5).microsecondsSinceEpoch + 7;
      expect(TimestampId.format(micros), equals('260102-030405.000007'));
    });

    test('renders the two-digit year as year % 100', () {
      final micros = DateTime.utc(2099, 12, 31, 23, 59, 59).microsecondsSinceEpoch;
      expect(TimestampId.format(micros), equals('991231-235959.000000'));
    });
  });

  group('TimestampId.instant', () {
    test('round-trips through format/parse to the microsecond', () {
      final at = DateTime.fromMicrosecondsSinceEpoch(
        DateTime.utc(2026, 6, 8, 19, 3, 16).microsecondsSinceEpoch + 402355,
        isUtc: true,
      );
      final id = TimestampId.generate(at: at);
      expect(id.instant, equals(at));
      expect(id.instant.isUtc, isTrue);
    });

    test('interprets the two-digit year as 2000 + YY', () {
      final id = TimestampId.fromString('260608-190316.402355');
      expect(id.instant.year, equals(2026));
    });
  });

  group('TimestampId.fromString', () {
    test('round-trips a generated value', () {
      final id = TimestampId.generate();
      expect(TimestampId.fromString(id.value), equals(id));
    });

    test('rejects malformed strings', () {
      for (final bad in [
        '260608-190316', // missing micros
        '260608-190316.40235', // 5-digit micros
        '260608-190316.4023555', // 7-digit micros
        '2606-08-190316.402355', // wrong date layout
        'turn_260608-190316.402355', // leading prefix
        '',
      ]) {
        expect(
          () => TimestampId.fromString(bad),
          throwsA(isA<FormatException>()),
          reason: 'should reject "$bad"',
        );
        expect(TimestampId.isValid(bad), isFalse, reason: 'isValid("$bad")');
      }
    });
  });

  group('TimestampId equality and ordering', () {
    test('equal by value', () {
      final a = TimestampId.fromString('260608-190316.402355');
      final b = TimestampId.fromString('260608-190316.402355');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('compareTo orders chronologically', () {
      final earlier = TimestampId.fromString('260608-190316.402355');
      final later = TimestampId.fromString('260608-190316.402356');
      expect(earlier.compareTo(later), lessThan(0));
      expect(later.compareTo(earlier), greaterThan(0));
    });
  });
}
