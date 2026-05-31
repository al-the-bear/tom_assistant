// Tests for `Budget` (Plan step A.12).
//
// Surface under test:
//   * Construction: positive components, zero-allowed, negative rejected
//     per each component
//   * `covers(delta)` predicate (component-wise; first overflow rejects)
//   * `minus(delta)` happy path returns a reduced envelope
//   * `minus(delta)` exact-cover edge case yields an exhausted envelope
//   * `minus(delta)` overflow raises `BudgetExceededError` with the right
//     dimension name
//   * `isExhausted` predicate
//   * `BudgetExceededError.dimension` reports the first overflowing
//     component (precedence: wallClockMs > tokenSpend > toolCalls >
//     memoryWrites)
//   * Equality, hashCode, toString

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('Budget construction', () {
    test('positive components are accepted', () {
      final b = Budget(
        wallClockMs: 120000,
        tokenSpend: 40000,
        toolCalls: 30,
        memoryWrites: 6,
      );
      expect(b.wallClockMs, equals(120000));
      expect(b.tokenSpend, equals(40000));
      expect(b.toolCalls, equals(30));
      expect(b.memoryWrites, equals(6));
      expect(b.isExhausted, isFalse);
    });

    test('all-zero budget is allowed (an already-exhausted envelope)', () {
      final b = Budget(
        wallClockMs: 0,
        tokenSpend: 0,
        toolCalls: 0,
        memoryWrites: 0,
      );
      expect(b.isExhausted, isTrue);
    });

    test('negative wallClockMs is rejected', () {
      expect(
        () => Budget(
          wallClockMs: -1,
          tokenSpend: 0,
          toolCalls: 0,
          memoryWrites: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative tokenSpend is rejected', () {
      expect(
        () => Budget(
          wallClockMs: 0,
          tokenSpend: -1,
          toolCalls: 0,
          memoryWrites: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative toolCalls is rejected', () {
      expect(
        () => Budget(
          wallClockMs: 0,
          tokenSpend: 0,
          toolCalls: -1,
          memoryWrites: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative memoryWrites is rejected', () {
      expect(
        () => Budget(
          wallClockMs: 0,
          tokenSpend: 0,
          toolCalls: 0,
          memoryWrites: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Budget.covers', () {
    final budget = Budget(
      wallClockMs: 100,
      tokenSpend: 50,
      toolCalls: 5,
      memoryWrites: 3,
    );

    test('covers the zero delta', () {
      expect(budget.covers(BudgetDelta.zero), isTrue);
    });

    test('covers a delta strictly under each component', () {
      expect(
        budget.covers(
          BudgetDelta(
            wallClockMs: 50,
            tokenSpend: 25,
            toolCalls: 2,
            memoryWrites: 1,
          ),
        ),
        isTrue,
      );
    });

    test('covers a delta that exactly equals the envelope', () {
      expect(
        budget.covers(
          BudgetDelta(
            wallClockMs: 100,
            tokenSpend: 50,
            toolCalls: 5,
            memoryWrites: 3,
          ),
        ),
        isTrue,
      );
    });

    test('rejects when wallClockMs overflows', () {
      expect(budget.covers(BudgetDelta(wallClockMs: 101)), isFalse);
    });

    test('rejects when tokenSpend overflows', () {
      expect(budget.covers(BudgetDelta(tokenSpend: 51)), isFalse);
    });

    test('rejects when toolCalls overflows', () {
      expect(budget.covers(BudgetDelta(toolCalls: 6)), isFalse);
    });

    test('rejects when memoryWrites overflows', () {
      expect(budget.covers(BudgetDelta(memoryWrites: 4)), isFalse);
    });
  });

  group('Budget.minus', () {
    final budget = Budget(
      wallClockMs: 100,
      tokenSpend: 50,
      toolCalls: 5,
      memoryWrites: 3,
    );

    test('subtracting zero is the identity', () {
      expect(budget.minus(BudgetDelta.zero), equals(budget));
    });

    test('subtracting a strict-cover delta reduces each component', () {
      final reduced = budget.minus(
        BudgetDelta(
          wallClockMs: 40,
          tokenSpend: 20,
          toolCalls: 1,
          memoryWrites: 1,
        ),
      );
      expect(reduced.wallClockMs, equals(60));
      expect(reduced.tokenSpend, equals(30));
      expect(reduced.toolCalls, equals(4));
      expect(reduced.memoryWrites, equals(2));
    });

    test('subtracting the exact envelope returns an exhausted budget', () {
      final exhausted = budget.minus(
        BudgetDelta(
          wallClockMs: 100,
          tokenSpend: 50,
          toolCalls: 5,
          memoryWrites: 3,
        ),
      );
      expect(exhausted.isExhausted, isTrue);
    });

    test('overflow raises BudgetExceededError naming wallClockMs first', () {
      expect(
        () => budget.minus(BudgetDelta(wallClockMs: 101)),
        throwsA(
          isA<BudgetExceededError>()
              .having((e) => e.dimension, 'dimension', 'wallClockMs'),
        ),
      );
    });

    test('overflow on tokenSpend names tokenSpend', () {
      expect(
        () => budget.minus(BudgetDelta(tokenSpend: 51)),
        throwsA(
          isA<BudgetExceededError>()
              .having((e) => e.dimension, 'dimension', 'tokenSpend'),
        ),
      );
    });

    test('overflow on toolCalls names toolCalls', () {
      expect(
        () => budget.minus(BudgetDelta(toolCalls: 6)),
        throwsA(
          isA<BudgetExceededError>()
              .having((e) => e.dimension, 'dimension', 'toolCalls'),
        ),
      );
    });

    test('overflow on memoryWrites names memoryWrites', () {
      expect(
        () => budget.minus(BudgetDelta(memoryWrites: 4)),
        throwsA(
          isA<BudgetExceededError>()
              .having((e) => e.dimension, 'dimension', 'memoryWrites'),
        ),
      );
    });

    test('multi-overflow names the wallClockMs dimension first (precedence)',
        () {
      // When several dimensions would overflow at once, the reported one is
      // wallClockMs > tokenSpend > toolCalls > memoryWrites — the order the
      // observability event will use.
      expect(
        () => budget.minus(
          BudgetDelta(
            wallClockMs: 999,
            tokenSpend: 999,
            toolCalls: 999,
            memoryWrites: 999,
          ),
        ),
        throwsA(
          isA<BudgetExceededError>()
              .having((e) => e.dimension, 'dimension', 'wallClockMs'),
        ),
      );
    });

    test('BudgetExceededError exposes remaining and attempted', () {
      final delta = BudgetDelta(tokenSpend: 51);
      try {
        budget.minus(delta);
        fail('expected BudgetExceededError to be thrown');
      } on BudgetExceededError catch (e) {
        expect(e.remaining, equals(budget));
        expect(e.attempted, equals(delta));
        expect(e.toString(), contains('tokenSpend'));
      }
    });
  });

  group('Budget equality and hash', () {
    test('equal budgets have equal hashCodes', () {
      final a = Budget(
        wallClockMs: 1,
        tokenSpend: 2,
        toolCalls: 3,
        memoryWrites: 4,
      );
      final b = Budget(
        wallClockMs: 1,
        tokenSpend: 2,
        toolCalls: 3,
        memoryWrites: 4,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing budgets are unequal', () {
      final a = Budget(
        wallClockMs: 1,
        tokenSpend: 0,
        toolCalls: 0,
        memoryWrites: 0,
      );
      final b = Budget(
        wallClockMs: 2,
        tokenSpend: 0,
        toolCalls: 0,
        memoryWrites: 0,
      );
      expect(a == b, isFalse);
    });

    test('not equal to an arbitrary Object', () {
      // Equality must return false (not throw) for non-Budget operands —
      // this is the contract every Dart value type carries. We compare to a
      // plain `Object()` so the analyzer doesn't flag the check as an
      // unrelated-type comparison.
      final b = Budget(
        wallClockMs: 0,
        tokenSpend: 0,
        toolCalls: 0,
        memoryWrites: 0,
      );
      expect(b == Object(), isFalse);
    });
  });

  group('Budget toString', () {
    test('names every component', () {
      final s = Budget(
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
