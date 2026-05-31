// Tests for the `symbolic/` module (Plan step A.88 extraction).
//
// Surface under test:
//   * `SymbolicOp` — fixed alphabet of eight operators
//   * `AttrClause` — equality, hash, list-value handling
//   * `SymbolicFilter` — construction, immutability, isEmpty, equality, hash
//
// What this suite intentionally does NOT cover:
//   * The SQL compiler. That lives in
//     `tom_brain_memory/lib/src/retrieval/symbolic_recall.dart` and is
//     covered by `tom_brain_memory/test/a56_symbolic_recall_test.dart`.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('SymbolicOp', () {
    test('exposes exactly the eight named operators', () {
      // The alphabet is intentionally closed. Adding a new operator is a
      // coordinated change across every consumer; this test pins the
      // current shape.
      expect(SymbolicOp.values, hasLength(8));
      expect(
        SymbolicOp.values.map((op) => op.name).toSet(),
        equals(<String>{
          'eq', 'ne', 'lt', 'lte', 'gt', 'gte', 'inList', 'notInList',
        }),
      );
    });
  });

  group('AttrClause', () {
    test('exposes (field, op, value) on the public surface', () {
      final c = AttrClause('priority', SymbolicOp.gte, 5);
      expect(c.field, equals('priority'));
      expect(c.op, equals(SymbolicOp.gte));
      expect(c.value, equals(5));
    });

    test('equality is structural across field, op, and primitive value', () {
      final a = AttrClause('age', SymbolicOp.eq, 30);
      final b = AttrClause('age', SymbolicOp.eq, 30);
      final c = AttrClause('age', SymbolicOp.eq, 31);
      final d = AttrClause('age', SymbolicOp.ne, 30);
      final e = AttrClause('name', SymbolicOp.eq, 30);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
      expect(a, isNot(equals(e)));
    });

    test('equality covers null values (for IS NULL semantics)', () {
      final a = AttrClause('producer', SymbolicOp.eq, null);
      final b = AttrClause('producer', SymbolicOp.eq, null);
      final c = AttrClause('producer', SymbolicOp.eq, 'agent.x');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('equality is element-wise for list-valued clauses', () {
      final a = AttrClause('tag', SymbolicOp.inList, const ['x', 'y', 'z']);
      final b = AttrClause('tag', SymbolicOp.inList, const ['x', 'y', 'z']);
      final c = AttrClause('tag', SymbolicOp.inList, const ['x', 'y']);
      final d = AttrClause('tag', SymbolicOp.inList, const ['z', 'y', 'x']);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      // Order matters — the compiler renders `IN (?, ?, ?)` in the
      // order the caller supplied, so two different orders are two
      // different clauses by identity.
      expect(a, isNot(equals(d)));
    });

    test('toString renders a human-readable form', () {
      final c = AttrClause('priority', SymbolicOp.gte, 5);
      expect(c.toString(), equals('AttrClause(priority gte 5)'));
    });
  });

  group('SymbolicFilter', () {
    test('defaults to an empty filter (no narrowing)', () {
      final f = SymbolicFilter();
      expect(f.typeNames, isEmpty);
      expect(f.createdAfter, isNull);
      expect(f.createdBefore, isNull);
      expect(f.producer, isNull);
      expect(f.attributes, isEmpty);
      expect(f.isEmpty, isTrue);
    });

    test('isEmpty flips false when any narrowing is present', () {
      expect(SymbolicFilter(typeNames: {'Claim'}).isEmpty, isFalse);
      expect(SymbolicFilter(createdAfter: DateTime(2026)).isEmpty, isFalse);
      expect(SymbolicFilter(createdBefore: DateTime(2026)).isEmpty, isFalse);
      expect(SymbolicFilter(producer: 'agent.x').isEmpty, isFalse);
      expect(
        SymbolicFilter(attributes: [AttrClause('k', SymbolicOp.eq, 1)])
            .isEmpty,
        isFalse,
      );
    });

    test('const SymbolicFilter literal is supported (compile-time form)',
        () {
      // The 30+ existing call sites build `const SymbolicFilter(...)`.
      // Pin that capability so a future change does not silently break
      // them.
      const f = SymbolicFilter(typeNames: <String>{'Claim'});
      expect(f.typeNames, equals(<String>{'Claim'}));
      expect(f.isEmpty, isFalse);
    });

    test('const SymbolicFilter() with no args is the empty filter', () {
      const f = SymbolicFilter();
      expect(f.isEmpty, isTrue);
    });

    test('equality is structural across all six fields', () {
      final a = SymbolicFilter(
        typeNames: {'Claim', 'Conclusion'},
        createdAfter: DateTime.utc(2026, 1, 1),
        createdBefore: DateTime.utc(2026, 6, 1),
        producer: 'agent.researcher',
        attributes: [AttrClause('priority', SymbolicOp.gte, 5)],
      );
      // Same fields, different construction order for the set.
      final b = SymbolicFilter(
        typeNames: {'Conclusion', 'Claim'},
        createdAfter: DateTime.utc(2026, 1, 1),
        createdBefore: DateTime.utc(2026, 6, 1),
        producer: 'agent.researcher',
        attributes: [AttrClause('priority', SymbolicOp.gte, 5)],
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('equality distinguishes filters that differ in any single field',
        () {
      SymbolicFilter base() => SymbolicFilter(
            typeNames: {'Claim'},
            createdAfter: DateTime.utc(2026, 1, 1),
            createdBefore: DateTime.utc(2026, 6, 1),
            producer: 'agent.x',
            attributes: [AttrClause('priority', SymbolicOp.gte, 5)],
          );

      expect(
        base(),
        isNot(equals(SymbolicFilter(
          typeNames: {'Claim', 'Conclusion'},
          createdAfter: DateTime.utc(2026, 1, 1),
          createdBefore: DateTime.utc(2026, 6, 1),
          producer: 'agent.x',
          attributes: [AttrClause('priority', SymbolicOp.gte, 5)],
        ))),
      );
      expect(
        base(),
        isNot(equals(SymbolicFilter(
          typeNames: {'Claim'},
          createdAfter: DateTime.utc(2026, 2, 1),
          createdBefore: DateTime.utc(2026, 6, 1),
          producer: 'agent.x',
          attributes: [AttrClause('priority', SymbolicOp.gte, 5)],
        ))),
      );
      expect(
        base(),
        isNot(equals(SymbolicFilter(
          typeNames: {'Claim'},
          createdAfter: DateTime.utc(2026, 1, 1),
          createdBefore: DateTime.utc(2026, 5, 1),
          producer: 'agent.x',
          attributes: [AttrClause('priority', SymbolicOp.gte, 5)],
        ))),
      );
      expect(
        base(),
        isNot(equals(SymbolicFilter(
          typeNames: {'Claim'},
          createdAfter: DateTime.utc(2026, 1, 1),
          createdBefore: DateTime.utc(2026, 6, 1),
          producer: 'agent.y',
          attributes: [AttrClause('priority', SymbolicOp.gte, 5)],
        ))),
      );
      expect(
        base(),
        isNot(equals(SymbolicFilter(
          typeNames: {'Claim'},
          createdAfter: DateTime.utc(2026, 1, 1),
          createdBefore: DateTime.utc(2026, 6, 1),
          producer: 'agent.x',
          attributes: [AttrClause('priority', SymbolicOp.gt, 5)],
        ))),
      );
    });

    test('toString omits unset narrowing for legibility', () {
      expect(SymbolicFilter().toString(), equals('SymbolicFilter()'));
      expect(
        SymbolicFilter(typeNames: {'Claim'}).toString(),
        equals('SymbolicFilter(types={Claim})'),
      );
      expect(
        SymbolicFilter(producer: 'agent.x').toString(),
        equals('SymbolicFilter(producer=agent.x)'),
      );
    });
  });
}
