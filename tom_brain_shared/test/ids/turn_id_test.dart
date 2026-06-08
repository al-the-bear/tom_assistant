// Tests for TurnId (logging-spec §3 — the turn-correlation id).
//
// TurnId is a bare UTC timestamp `YYMMDD-HHMMSS.ssssss` (microsecond precision),
// backed by `TimestampId`. It is minted once at the access edge the instant an
// inbound request is admitted, and threaded through the whole turn so a trail
// filename / log line *starts with the turn's timestamp* (§3 / §4.2).
//
// The rules tested here:
//
//   * generate builds the bare `YYMMDD-HHMMSS.ssssss` form (no prefix)
//   * generate is monotonic — successive values never collide and sort
//     chronologically by string comparison
//   * generate(at:) encodes the supplied instant
//   * fromString round-trips a generated value and rejects a malformed one
//   * equality is value-based and type-aware

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('TurnId.generate', () {
    test('builds a bare YYMMDD-HHMMSS.ssssss form with no prefix', () {
      final id = TurnId.generate();
      expect(id.value, isNot(startsWith('turn_')));
      expect(id.value, matches(RegExp(r'^\d{6}-\d{6}\.\d{6}$')));
      expect(id.toString(), equals(id.value));
    });

    test('produces unique, strictly increasing values across many calls', () {
      const n = 4000;
      final seen = <String>{};
      String? previous;
      for (var i = 0; i < n; i++) {
        final value = TurnId.generate().value;
        seen.add(value);
        if (previous != null) {
          expect(value.compareTo(previous), greaterThan(0));
        }
        previous = value;
      }
      expect(seen.length, equals(n));
    });

    test('encodes the supplied instant in its timestamp portion', () {
      final at = DateTime.fromMicrosecondsSinceEpoch(
        DateTime.utc(2026, 6, 8, 12, 30, 15).microsecondsSinceEpoch + 402355,
        isUtc: true,
      );
      final id = TurnId.generate(at: at);
      expect(id.value, equals('260608-123015.402355'));
      expect(id.instant, equals(at));
    });
  });

  group('TurnId.fromString', () {
    test('round-trips a generated value', () {
      final id = TurnId.generate();
      final parsed = TurnId.fromString(id.value);
      expect(parsed, equals(id));
      expect(parsed.value, equals(id.value));
    });

    test('rejects a malformed timestamp', () {
      expect(
        () => TurnId.fromString('turn_not-a-ulid'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TurnId.fromString('260608-123015'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('TurnId equality', () {
    test('equal by value', () {
      final a = TurnId.generate();
      final b = TurnId.fromString(a.value);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
