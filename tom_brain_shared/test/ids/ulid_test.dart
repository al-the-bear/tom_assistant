// Tests for the ULID generator/validator (Plan step A.10).
//
// These tests cover the contract of `Ulid` independent of any concrete
// identifier type. Prefix-validation behaviour lives in the per-type
// tests next door.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('Ulid.generate', () {
    test('produces a string of exactly 26 chars', () {
      final u = Ulid.generate();
      expect(u, hasLength(Ulid.totalLength));
      expect(Ulid.totalLength, equals(26));
    });

    test('uses only Crockford alphabet chars', () {
      // Generate a bunch — flushing out any rare codepoint mistake.
      for (var i = 0; i < 256; i++) {
        final u = Ulid.generate();
        for (final ch in u.split('')) {
          expect(
            Ulid.alphabet.contains(ch),
            isTrue,
            reason: 'ULID "$u" contains non-Crockford char "$ch"',
          );
        }
      }
    });

    test('produces unique values across many calls', () {
      const n = 5000;
      final seen = <String>{};
      for (var i = 0; i < n; i++) {
        seen.add(Ulid.generate());
      }
      // Single-ms collisions are theoretically possible with 80 bits of
      // randomness but vanishingly unlikely at n=5000.
      expect(seen.length, equals(n));
    });

    test('lexicographic order matches chronological order across ms', () {
      final earlier = Ulid.generate(at: DateTime.utc(2020, 1, 1));
      final later = Ulid.generate(at: DateTime.utc(2030, 1, 1));
      expect(earlier.compareTo(later), lessThan(0));
    });

    test('round-trips the timestamp', () {
      // Pick an arbitrary instant; the encoder is ms-resolution so we
      // strip sub-ms precision before comparing.
      final t = DateTime.utc(2026, 5, 30, 12, 34, 56, 789);
      final u = Ulid.generate(at: t);
      expect(Ulid.timestampOf(u), equals(t));
    });

    test('accepts epoch as the lowest timestamp', () {
      final u = Ulid.generate(at: DateTime.fromMillisecondsSinceEpoch(0));
      expect(u.substring(0, Ulid.timestampLength), equals('0000000000'));
    });

    test('rejects a timestamp past 2^48 - 1 ms', () {
      // Build a DateTime past the ULID range. DateTime allows it; ULID
      // does not.
      final beyond = DateTime.fromMillisecondsSinceEpoch(
        Ulid.maxTimestampMs + 1,
      );
      expect(
        () => Ulid.generate(at: beyond),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts a deterministic randomness vector and reproduces it', () {
      final at = DateTime.utc(2026, 1, 1);
      final r = List<int>.generate(Ulid.randomnessLength, (i) => i);
      final a = Ulid.generate(at: at, randomness: r);
      final b = Ulid.generate(at: at, randomness: r);
      expect(a, equals(b));
      // First 10 chars are the timestamp; the remainder is deterministic.
      expect(
        a.substring(Ulid.timestampLength),
        equals('0123456789ABCDEF'),
      );
    });

    test('rejects a randomness vector of the wrong length', () {
      expect(
        () => Ulid.generate(randomness: List<int>.filled(15, 0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a randomness vector with out-of-range entries', () {
      final r = List<int>.filled(Ulid.randomnessLength, 0);
      r[3] = 32; // out of [0..31]
      expect(
        () => Ulid.generate(randomness: r),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Ulid.isValid', () {
    test('accepts a generated ULID', () {
      expect(Ulid.isValid(Ulid.generate()), isTrue);
    });

    test('rejects empty string', () {
      expect(Ulid.isValid(''), isFalse);
    });

    test('rejects a string of the wrong length', () {
      expect(Ulid.isValid('A' * 25), isFalse);
      expect(Ulid.isValid('A' * 27), isFalse);
    });

    test('rejects a string containing a non-Crockford char', () {
      // `I`, `L`, `O`, `U` are explicitly outside the Crockford alphabet.
      final base = 'A' * 25;
      expect(Ulid.isValid('${base}I'), isFalse);
      expect(Ulid.isValid('${base}L'), isFalse);
      expect(Ulid.isValid('${base}O'), isFalse);
      expect(Ulid.isValid('${base}U'), isFalse);
    });

    test('rejects a lowercase encoding', () {
      // ULIDs in this codebase are uppercase canonical; lowercase would
      // break the lexicographic-ordering guarantee against uppercase
      // siblings.
      expect(Ulid.isValid('a' * 26), isFalse);
    });
  });

  group('Ulid.timestampOf', () {
    test('throws FormatException on a non-ULID input', () {
      expect(
        () => Ulid.timestampOf('not-a-ulid'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
