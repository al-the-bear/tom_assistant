// Tests for TurnId (logging-spec §3 — the turn-correlation id).
//
// TurnId shares the `<prefix>_<26-char-ULID>` shape of NodeId/EdgeId/TrailId/
// StackEntryId, but with the prefix `turn` so a trail filename / log line reads
// `turn_<ULID>` (§3 / §4.2). It is minted once at the access edge the instant an
// inbound request is admitted, and threaded through the whole turn.
//
// The rules tested here mirror the sibling `PrefixedUlidId` types:
//
//   * generate builds the canonical `turn_<ULID>` form
//   * fromString round-trips a generated value
//   * fromString rejects a wrong prefix and a non-ULID payload
//   * equality is value-based and type-aware
//   * generated values are unique across many calls

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('TurnId.generate', () {
    test('builds the canonical turn_<ULID> form', () {
      final id = TurnId.generate();
      expect(id.value, startsWith('turn_'));
      expect(id.prefix, equals('turn'));
      // 'turn_' (5) + 26-char ULID.
      expect(id.value.length, equals('turn_'.length + Ulid.totalLength));
      expect(id.ulid.length, equals(Ulid.totalLength));
      expect(id.toString(), equals(id.value));
    });

    test('produces unique values across many calls', () {
      const n = 4000;
      final seen = <String>{};
      for (var i = 0; i < n; i++) {
        seen.add(TurnId.generate().value);
      }
      expect(seen.length, equals(n));
    });

    test('encodes the supplied instant in its timestamp portion', () {
      final at = DateTime.utc(2026, 6, 8, 12, 30);
      final id = TurnId.generate(at: at);
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

    test('rejects a wrong prefix', () {
      final ulid = Ulid.generate();
      expect(
        () => TurnId.fromString('t_$ulid'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a non-ULID payload', () {
      expect(
        () => TurnId.fromString('turn_not-a-ulid'),
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

    test('a TurnId never equals a TrailId with the same ULID payload', () {
      final ulid = Ulid.generate();
      final turn = TurnId.fromString('turn_$ulid');
      final trail = TrailId.fromString('t_$ulid');
      expect(turn, isNot(equals(trail)));
    });
  });
}
