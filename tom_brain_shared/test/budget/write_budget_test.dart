// Tests for `WriteBudget` (Plan step A.12).
//
// Surface under test:
//   * Construction: positive components, zero-allowed, negative-rejected
//     per component
//   * `WriteBudget.readOnly` constant + `isReadOnly` predicate
//   * Equality, hashCode, toString

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('WriteBudget construction', () {
    test('positive components are accepted', () {
      final wb = WriteBudget(maxNodes: 10, maxEdges: 20, maxStackEntries: 5);
      expect(wb.maxNodes, equals(10));
      expect(wb.maxEdges, equals(20));
      expect(wb.maxStackEntries, equals(5));
      expect(wb.isReadOnly, isFalse);
    });

    test('zero in any component is accepted (means "no writes of this kind")',
        () {
      final wb = WriteBudget(maxNodes: 0, maxEdges: 5, maxStackEntries: 0);
      expect(wb.maxNodes, equals(0));
      expect(wb.maxEdges, equals(5));
      expect(wb.maxStackEntries, equals(0));
      expect(wb.isReadOnly, isFalse,
          reason: 'maxEdges > 0 — not read-only overall.');
    });

    test('negative maxNodes is rejected', () {
      expect(
        () => WriteBudget(maxNodes: -1, maxEdges: 0, maxStackEntries: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative maxEdges is rejected', () {
      expect(
        () => WriteBudget(maxNodes: 0, maxEdges: -1, maxStackEntries: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative maxStackEntries is rejected', () {
      expect(
        () => WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('WriteBudget.readOnly', () {
    test('is the all-zero budget', () {
      expect(WriteBudget.readOnly.maxNodes, equals(0));
      expect(WriteBudget.readOnly.maxEdges, equals(0));
      expect(WriteBudget.readOnly.maxStackEntries, equals(0));
      expect(WriteBudget.readOnly.isReadOnly, isTrue);
    });

    test('equals an explicit all-zero construction', () {
      expect(
        WriteBudget.readOnly,
        equals(
          WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0),
        ),
      );
    });
  });

  group('WriteBudget equality and hash', () {
    test('equal budgets have equal hashCodes', () {
      final a = WriteBudget(maxNodes: 10, maxEdges: 20, maxStackEntries: 5);
      final b = WriteBudget(maxNodes: 10, maxEdges: 20, maxStackEntries: 5);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing components are unequal', () {
      expect(
        WriteBudget(maxNodes: 1, maxEdges: 0, maxStackEntries: 0) ==
            WriteBudget(maxNodes: 2, maxEdges: 0, maxStackEntries: 0),
        isFalse,
      );
    });

    test('not equal to an arbitrary Object', () {
      final wb = WriteBudget(maxNodes: 0, maxEdges: 0, maxStackEntries: 0);
      expect(wb == Object(), isFalse);
    });
  });

  group('WriteBudget toString', () {
    test('names every component', () {
      final s = WriteBudget(
        maxNodes: 1,
        maxEdges: 2,
        maxStackEntries: 3,
      ).toString();
      expect(s, contains('maxNodes: 1'));
      expect(s, contains('maxEdges: 2'));
      expect(s, contains('maxStackEntries: 3'));
    });
  });
}
