// Tests for `BrainVersion` (Plan step A.16).
//
// Coverage targets:
//
//   * Construction via `fromInt` — accepted range, both rejection
//     paths (below 1, above maxValue).
//   * `initial` constant equals `fromInt(1)`.
//   * `parse` — bare digits, "v"-prefixed digits, every documented
//     failure mode (empty, lone "v", explicit sign, non-digits, dotted
//     "semver-style" input, out-of-range integer).
//   * `next` — advances by 1; throws at the ceiling.
//   * `isImmediateSuccessorOf` / `isImmediatePredecessorOf` — both
//     true and false cases, including the symmetric pair.
//   * Equality + hash — same value equal, different unequal,
//     `identical` short-circuit, cross-type rejection (cast through
//     `Object` to silence the analyzer's `unrelated_type_equality_checks`
//     lint — the cast is conceptually correct because we're asserting
//     behaviour of the inherited `Object` `==` contract on a non-
//     `BrainVersion` operand).
//   * Ordering — `compareTo`, the four operators, sorting a list, a
//     full chain of `next()` calls produces strictly ascending values.
//   * `toString` round-trips through `parse`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('BrainVersion construction', () {
    test('fromInt(1) succeeds', () {
      expect(BrainVersion.fromInt(1).value, 1);
    });

    test('fromInt accepts arbitrary positive value within range', () {
      expect(BrainVersion.fromInt(42).value, 42);
      expect(BrainVersion.fromInt(123456).value, 123456);
    });

    test('fromInt accepts the maximum value', () {
      expect(BrainVersion.fromInt(BrainVersion.maxValue).value,
          BrainVersion.maxValue);
    });

    test('fromInt rejects 0 with a message pointing at Maybe', () {
      expect(
        () => BrainVersion.fromInt(0),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('Maybe<BrainVersion>'),
          ),
        ),
      );
    });

    test('fromInt rejects negatives', () {
      expect(() => BrainVersion.fromInt(-1), throwsArgumentError);
      expect(() => BrainVersion.fromInt(-9999), throwsArgumentError);
    });

    test('fromInt rejects above maxValue', () {
      expect(
        () => BrainVersion.fromInt(BrainVersion.maxValue + 1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('JS-safe'),
          ),
        ),
      );
    });

    test('initial is BrainVersion.fromInt(1)', () {
      expect(BrainVersion.initial, BrainVersion.fromInt(1));
      expect(BrainVersion.initial.value, 1);
    });

    test('initial is a compile-time constant', () {
      // Verified by usage: the const context below would fail to compile
      // if `BrainVersion.initial` were not a const.
      const v = BrainVersion.initial;
      expect(v.value, 1);
    });

    test('maxValue equals 2^53 - 1 (JS-safe integer ceiling)', () {
      expect(BrainVersion.maxValue, 9007199254740991);
    });
  });

  group('BrainVersion.parse', () {
    test('accepts bare digits', () {
      expect(BrainVersion.parse('1'), BrainVersion.initial);
      expect(BrainVersion.parse('42').value, 42);
    });

    test('accepts "v"-prefixed digits', () {
      expect(BrainVersion.parse('v1'), BrainVersion.initial);
      expect(BrainVersion.parse('v42').value, 42);
    });

    test('round-trips through toString', () {
      for (final n in [1, 2, 17, 1024, 1 << 30, BrainVersion.maxValue]) {
        final v = BrainVersion.fromInt(n);
        expect(BrainVersion.parse(v.toString()), v);
      }
    });

    test('rejects the empty string', () {
      expect(() => BrainVersion.parse(''), throwsFormatException);
    });

    test('rejects a lone "v" prefix', () {
      expect(() => BrainVersion.parse('v'), throwsFormatException);
    });

    test('rejects explicit signs', () {
      expect(() => BrainVersion.parse('+1'), throwsFormatException);
      expect(() => BrainVersion.parse('-1'), throwsFormatException);
      expect(() => BrainVersion.parse('v-3'), throwsFormatException);
      expect(() => BrainVersion.parse('v+3'), throwsFormatException);
    });

    test('rejects non-digit garbage', () {
      expect(() => BrainVersion.parse('vabc'), throwsFormatException);
      expect(() => BrainVersion.parse('hello'), throwsFormatException);
      expect(() => BrainVersion.parse('v1x'), throwsFormatException);
    });

    test('rejects dotted "semver-style" input', () {
      // The brain does not use semver; the dotted form is the most
      // likely accidental input and must be refused at parse time.
      expect(() => BrainVersion.parse('1.2'), throwsFormatException);
      expect(() => BrainVersion.parse('1.2.3'), throwsFormatException);
      expect(() => BrainVersion.parse('v1.2'), throwsFormatException);
    });

    test('rejects 0 with an ArgumentError, not a FormatException', () {
      // "0" parses as an integer but fails the range check.
      expect(() => BrainVersion.parse('0'), throwsArgumentError);
      expect(() => BrainVersion.parse('v0'), throwsArgumentError);
    });

    test('rejects integers above maxValue', () {
      final overflow = (BrainVersion.maxValue + 1).toString();
      expect(() => BrainVersion.parse(overflow), throwsArgumentError);
      expect(() => BrainVersion.parse('v$overflow'), throwsArgumentError);
    });
  });

  group('BrainVersion.next', () {
    test('returns value + 1', () {
      expect(BrainVersion.initial.next().value, 2);
      expect(BrainVersion.fromInt(99).next().value, 100);
    });

    test('chained next() calls produce strictly ascending values', () {
      final chain = <BrainVersion>[BrainVersion.initial];
      for (var i = 0; i < 50; i++) {
        chain.add(chain.last.next());
      }
      for (var i = 1; i < chain.length; i++) {
        expect(chain[i] > chain[i - 1], isTrue);
        expect(chain[i].isImmediateSuccessorOf(chain[i - 1]), isTrue);
      }
      expect(chain.last.value, 51);
    });

    test('throws StateError at the ceiling', () {
      final ceiling = BrainVersion.fromInt(BrainVersion.maxValue);
      expect(ceiling.next, throwsA(isA<StateError>()));
    });
  });

  group('BrainVersion immediate-neighbour predicates', () {
    final v3 = BrainVersion.fromInt(3);
    final v4 = BrainVersion.fromInt(4);
    final v5 = BrainVersion.fromInt(5);

    test('isImmediateSuccessorOf is true for value + 1, false otherwise', () {
      expect(v4.isImmediateSuccessorOf(v3), isTrue);
      expect(v5.isImmediateSuccessorOf(v4), isTrue);
      expect(v5.isImmediateSuccessorOf(v3), isFalse); // gap of 2
      expect(v3.isImmediateSuccessorOf(v4), isFalse); // wrong direction
      expect(v3.isImmediateSuccessorOf(v3), isFalse); // same value
    });

    test('isImmediatePredecessorOf is the symmetric of isImmediateSuccessorOf',
        () {
      expect(v3.isImmediatePredecessorOf(v4), isTrue);
      expect(v4.isImmediatePredecessorOf(v5), isTrue);
      expect(v3.isImmediatePredecessorOf(v5), isFalse);
      expect(v4.isImmediatePredecessorOf(v3), isFalse);
      expect(v3.isImmediatePredecessorOf(v3), isFalse);

      // Symmetry property.
      for (final pair in [
        [v3, v4],
        [v4, v5]
      ]) {
        expect(pair[0].isImmediatePredecessorOf(pair[1]),
            pair[1].isImmediateSuccessorOf(pair[0]));
      }
    });
  });

  group('BrainVersion equality + hash', () {
    test('same value is equal', () {
      expect(BrainVersion.fromInt(42) == BrainVersion.fromInt(42), isTrue);
      expect(BrainVersion.fromInt(42).hashCode,
          BrainVersion.fromInt(42).hashCode);
    });

    test('different values are unequal', () {
      expect(BrainVersion.fromInt(42) == BrainVersion.fromInt(43), isFalse);
    });

    test('identical short-circuits', () {
      const v = BrainVersion.initial;
      // ignore: unrelated_type_equality_checks
      expect(identical(v, v), isTrue);
      expect(v == v, isTrue);
    });

    test('cross-type comparison returns false (no throw)', () {
      final v = BrainVersion.fromInt(5);
      // Cast through Object so the analyzer accepts the deliberate
      // mismatch; we are asserting the inherited Object.== contract.
      expect((v as Object) == 5, isFalse);
      expect((v as Object) == '5', isFalse);
      // Equality against an untyped `Object?` holding null also returns
      // false. The local nullable cast keeps the analyzer from folding
      // the comparison into a compile-time constant.
      final Object? maybeNull = DateTime.now().millisecondsSinceEpoch == 0
          ? v
          : null;
      expect((v as Object) == maybeNull, isFalse);
    });

    test('hashCode matches the underlying int', () {
      // Not a binding contract, just a sanity check that the obvious
      // delegation is in place.
      expect(BrainVersion.fromInt(7).hashCode, 7.hashCode);
    });
  });

  group('BrainVersion ordering', () {
    final v1 = BrainVersion.initial;
    final v2 = BrainVersion.fromInt(2);
    final v10 = BrainVersion.fromInt(10);

    test('compareTo respects the natural order', () {
      expect(v1.compareTo(v2), lessThan(0));
      expect(v2.compareTo(v1), greaterThan(0));
      expect(v1.compareTo(v1), 0);
    });

    test('< / <= / > / >= match compareTo', () {
      expect(v1 < v2, isTrue);
      expect(v2 < v1, isFalse);
      expect(v1 < v1, isFalse);

      expect(v1 <= v2, isTrue);
      expect(v1 <= v1, isTrue);
      expect(v2 <= v1, isFalse);

      expect(v2 > v1, isTrue);
      expect(v1 > v2, isFalse);
      expect(v1 > v1, isFalse);

      expect(v2 >= v1, isTrue);
      expect(v1 >= v1, isTrue);
      expect(v1 >= v2, isFalse);
    });

    test('sorting a shuffled list produces ascending order', () {
      final list = <BrainVersion>[v10, v1, v2, BrainVersion.fromInt(5)];
      list.sort();
      expect(list.map((v) => v.value).toList(), [1, 2, 5, 10]);
    });
  });

  group('BrainVersion.toString', () {
    test('uses the "v<digits>" form', () {
      expect(BrainVersion.initial.toString(), 'v1');
      expect(BrainVersion.fromInt(42).toString(), 'v42');
      expect(BrainVersion.fromInt(BrainVersion.maxValue).toString(),
          'v${BrainVersion.maxValue}');
    });
  });
}
