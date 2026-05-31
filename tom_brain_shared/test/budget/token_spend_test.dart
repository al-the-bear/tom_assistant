// Tests for `TokenSpend` (Plan step A.12).
//
// Surface under test:
//   * Construction: defaults, explicit positives, negative rejection
//   * `total` derivation
//   * `+` operator (component-wise accumulation, zero identity)
//   * Equality, hashCode, toString
//   * The `zero` constant

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('TokenSpend construction', () {
    test('defaults to (0, 0)', () {
      final s = TokenSpend();
      expect(s.input, equals(0));
      expect(s.output, equals(0));
      expect(s.total, equals(0));
    });

    test('explicit positive components are accepted', () {
      final s = TokenSpend(input: 120, output: 30);
      expect(s.input, equals(120));
      expect(s.output, equals(30));
      expect(s.total, equals(150));
    });

    test('negative input is rejected', () {
      expect(
        () => TokenSpend(input: -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative output is rejected', () {
      expect(
        () => TokenSpend(output: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('TokenSpend.zero', () {
    test('zero constant is (0, 0)', () {
      expect(TokenSpend.zero.input, equals(0));
      expect(TokenSpend.zero.output, equals(0));
      expect(TokenSpend.zero.total, equals(0));
    });

    test('adding zero is the identity', () {
      final s = TokenSpend(input: 10, output: 20);
      expect(s + TokenSpend.zero, equals(s));
      expect(TokenSpend.zero + s, equals(s));
    });
  });

  group('TokenSpend +', () {
    test('component-wise sum', () {
      final a = TokenSpend(input: 100, output: 50);
      final b = TokenSpend(input: 25, output: 5);
      final sum = a + b;
      expect(sum.input, equals(125));
      expect(sum.output, equals(55));
      expect(sum.total, equals(180));
    });

    test('+ is commutative', () {
      final a = TokenSpend(input: 7, output: 11);
      final b = TokenSpend(input: 3, output: 13);
      expect(a + b, equals(b + a));
    });
  });

  group('TokenSpend equality and hash', () {
    test('equal spends have equal hashCodes', () {
      final a = TokenSpend(input: 42, output: 7);
      final b = TokenSpend(input: 42, output: 7);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different components are unequal', () {
      expect(
        TokenSpend(input: 1, output: 2) == TokenSpend(input: 2, output: 1),
        isFalse,
      );
    });

    test('not equal to an arbitrary Object', () {
      expect(TokenSpend(input: 1) == Object(), isFalse);
    });
  });

  group('TokenSpend toString', () {
    test('names both components', () {
      final s = TokenSpend(input: 5, output: 3).toString();
      expect(s, contains('input: 5'));
      expect(s, contains('output: 3'));
    });
  });
}
