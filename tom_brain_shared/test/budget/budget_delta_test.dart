// Tests for `BudgetDelta` (Plan step A.12).
//
// Surface under test:
//   * Construction: defaults, explicit positives, negative rejection per
//     each component
//   * `zero` constant + isZero predicate
//   * `+` operator (component-wise sum)
//   * `BudgetDelta.fromTokenSpend` bridge
//   * Equality, hashCode, toString

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('BudgetDelta construction', () {
    test('all components default to 0', () {
      final d = BudgetDelta();
      expect(d.wallClockMs, equals(0));
      expect(d.tokenSpend, equals(0));
      expect(d.toolCalls, equals(0));
      expect(d.memoryWrites, equals(0));
      expect(d.isZero, isTrue);
    });

    test('explicit positive components are accepted', () {
      final d = BudgetDelta(
        wallClockMs: 200,
        tokenSpend: 150,
        toolCalls: 2,
        memoryWrites: 1,
      );
      expect(d.wallClockMs, equals(200));
      expect(d.tokenSpend, equals(150));
      expect(d.toolCalls, equals(2));
      expect(d.memoryWrites, equals(1));
      expect(d.isZero, isFalse);
    });

    test('negative wallClockMs is rejected', () {
      expect(() => BudgetDelta(wallClockMs: -1), throwsA(isA<ArgumentError>()));
    });

    test('negative tokenSpend is rejected', () {
      expect(() => BudgetDelta(tokenSpend: -1), throwsA(isA<ArgumentError>()));
    });

    test('negative toolCalls is rejected', () {
      expect(() => BudgetDelta(toolCalls: -1), throwsA(isA<ArgumentError>()));
    });

    test('negative memoryWrites is rejected', () {
      expect(
        () => BudgetDelta(memoryWrites: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('BudgetDelta.zero', () {
    test('is the all-zero delta', () {
      expect(BudgetDelta.zero.isZero, isTrue);
      expect(BudgetDelta.zero, equals(BudgetDelta()));
    });

    test('is the additive identity', () {
      final d = BudgetDelta(
        wallClockMs: 7,
        tokenSpend: 11,
        toolCalls: 1,
        memoryWrites: 2,
      );
      expect(d + BudgetDelta.zero, equals(d));
      expect(BudgetDelta.zero + d, equals(d));
    });
  });

  group('BudgetDelta +', () {
    test('component-wise sum', () {
      final a = BudgetDelta(
        wallClockMs: 100,
        tokenSpend: 50,
        toolCalls: 1,
        memoryWrites: 2,
      );
      final b = BudgetDelta(
        wallClockMs: 25,
        tokenSpend: 15,
        toolCalls: 4,
        memoryWrites: 1,
      );
      final sum = a + b;
      expect(sum.wallClockMs, equals(125));
      expect(sum.tokenSpend, equals(65));
      expect(sum.toolCalls, equals(5));
      expect(sum.memoryWrites, equals(3));
    });

    test('+ is commutative', () {
      final a = BudgetDelta(wallClockMs: 3, tokenSpend: 5);
      final b = BudgetDelta(wallClockMs: 7, toolCalls: 1);
      expect(a + b, equals(b + a));
    });
  });

  group('BudgetDelta.fromTokenSpend', () {
    test('maps TokenSpend.total to tokenSpend', () {
      final spend = TokenSpend(input: 100, output: 25);
      final d = BudgetDelta.fromTokenSpend(spend);
      expect(d.tokenSpend, equals(125));
      expect(d.wallClockMs, equals(0));
      expect(d.toolCalls, equals(0));
      expect(d.memoryWrites, equals(0));
    });

    test('accepts the other three dimensions as named args', () {
      final spend = TokenSpend(input: 10, output: 5);
      final d = BudgetDelta.fromTokenSpend(
        spend,
        wallClockMs: 200,
        toolCalls: 1,
        memoryWrites: 0,
      );
      expect(d.wallClockMs, equals(200));
      expect(d.tokenSpend, equals(15));
      expect(d.toolCalls, equals(1));
      expect(d.memoryWrites, equals(0));
    });
  });

  group('BudgetDelta equality and hash', () {
    test('equal deltas have equal hashCodes', () {
      final a = BudgetDelta(
        wallClockMs: 100,
        tokenSpend: 50,
        toolCalls: 1,
        memoryWrites: 0,
      );
      final b = BudgetDelta(
        wallClockMs: 100,
        tokenSpend: 50,
        toolCalls: 1,
        memoryWrites: 0,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing components are unequal', () {
      expect(
        BudgetDelta(tokenSpend: 1) == BudgetDelta(tokenSpend: 2),
        isFalse,
      );
    });

    test('not equal to an arbitrary Object', () {
      expect(BudgetDelta() == Object(), isFalse);
    });
  });

  group('BudgetDelta toString', () {
    test('names every component', () {
      final s = BudgetDelta(
        wallClockMs: 1,
        tokenSpend: 2,
        toolCalls: 3,
        memoryWrites: 4,
      ).toString();
      expect(s, contains('wallClockMs: 1'));
      expect(s, contains('tokenSpend: 2'));
      expect(s, contains('toolCalls: 3'));
      expect(s, contains('memoryWrites: 4'));
    });
  });
}
