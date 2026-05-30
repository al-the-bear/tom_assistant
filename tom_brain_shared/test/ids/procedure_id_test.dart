// Tests for ProcedureId (Plan step A.10).
//
// ProcedureId has a different shape from the other four IDs: it carries a
// human-readable slug and a monotonic integer version, not a ULID. The
// rules being tested here:
//
//   * named constructor builds the canonical "p_<slug>_v<version>" form
//   * slug rule: starts with lowercase letter, body is [a-z0-9_]*
//   * version rule: positive integer (>= 1)
//   * fromString parses the canonical form
//   * fromString rejects invalid shapes (uppercase, leading digit, hyphen,
//     missing version, version zero)
//   * nextVersion bumps and returns a new value
//   * equality is by (slug, version) pair
//   * compareTo orders by slug then numerically by version
//     (NOT lexicographically — `v10` must follow `v2`)

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('ProcedureId construction', () {
    test('named constructor builds canonical form', () {
      final id = ProcedureId(slug: 'author_new_procedure', version: 1);
      expect(id.value, equals('p_author_new_procedure_v1'));
      expect(id.toString(), equals('p_author_new_procedure_v1'));
      expect(id.slug, equals('author_new_procedure'));
      expect(id.version, equals(1));
    });

    test('accepts a single-letter slug', () {
      final id = ProcedureId(slug: 'a', version: 1);
      expect(id.value, equals('p_a_v1'));
    });

    test('accepts digits and underscores after the leading letter', () {
      final id = ProcedureId(slug: 'recall_v2_warmup_3', version: 7);
      expect(id.value, equals('p_recall_v2_warmup_3_v7'));
    });

    test('rejects empty slug', () {
      expect(
        () => ProcedureId(slug: '', version: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects uppercase slug', () {
      expect(
        () => ProcedureId(slug: 'AuthorNewProcedure', version: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects slug with leading digit', () {
      expect(
        () => ProcedureId(slug: '1author', version: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects slug with leading underscore', () {
      expect(
        () => ProcedureId(slug: '_author', version: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects slug with hyphen', () {
      expect(
        () => ProcedureId(slug: 'author-new', version: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects version zero', () {
      expect(
        () => ProcedureId(slug: 'a', version: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects negative version', () {
      expect(
        () => ProcedureId(slug: 'a', version: -1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('ProcedureId.fromString', () {
    test('round-trips a constructed value', () {
      final id = ProcedureId(slug: 'author_new_procedure', version: 3);
      final parsed = ProcedureId.fromString(id.value);
      expect(parsed, equals(id));
      expect(parsed.slug, equals('author_new_procedure'));
      expect(parsed.version, equals(3));
    });

    test('parses a slug that itself contains `_v<digits>`', () {
      // The full regex is anchored on the trailing `_v<digits>$`. A slug
      // body that happens to contain "_v2" must NOT be misread as the
      // version segment.
      final parsed = ProcedureId.fromString('p_recall_v2_warmup_3_v7');
      expect(parsed.slug, equals('recall_v2_warmup_3'));
      expect(parsed.version, equals(7));
    });

    test('rejects missing "p_" prefix', () {
      expect(
        () => ProcedureId.fromString('q_author_v1'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing "_v<digits>" suffix', () {
      expect(
        () => ProcedureId.fromString('p_author'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects version with leading zero', () {
      expect(
        () => ProcedureId.fromString('p_a_v01'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects version zero', () {
      expect(
        () => ProcedureId.fromString('p_a_v0'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty slug between prefix and version', () {
      expect(
        () => ProcedureId.fromString('p__v1'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects uppercase slug', () {
      expect(
        () => ProcedureId.fromString('p_Author_v1'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ProcedureId.nextVersion', () {
    test('bumps the version by one', () {
      final v1 = ProcedureId(slug: 'a', version: 1);
      final v2 = v1.nextVersion();
      expect(v2.slug, equals('a'));
      expect(v2.version, equals(2));
      expect(v2.value, equals('p_a_v2'));
    });

    test('chained nextVersion calls compose', () {
      final v1 = ProcedureId(slug: 'a', version: 1);
      final v5 = v1.nextVersion().nextVersion().nextVersion().nextVersion();
      expect(v5.version, equals(5));
    });
  });

  group('ProcedureId equality and hashing', () {
    test('equal by (slug, version)', () {
      final a = ProcedureId(slug: 'author', version: 2);
      final b = ProcedureId.fromString('p_author_v2');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different version: not equal', () {
      final a = ProcedureId(slug: 'author', version: 1);
      final b = ProcedureId(slug: 'author', version: 2);
      expect(a, isNot(equals(b)));
    });

    test('different slug: not equal', () {
      final a = ProcedureId(slug: 'author_a', version: 1);
      final b = ProcedureId(slug: 'author_b', version: 1);
      expect(a, isNot(equals(b)));
    });
  });

  group('ProcedureId.compareTo', () {
    test('orders by slug first', () {
      final a = ProcedureId(slug: 'apple', version: 99);
      final z = ProcedureId(slug: 'zebra', version: 1);
      expect(a.compareTo(z), lessThan(0));
    });

    test('within the same slug, orders by NUMERIC version, not lexical', () {
      final v2 = ProcedureId(slug: 'a', version: 2);
      final v10 = ProcedureId(slug: 'a', version: 10);
      // String compare would put 'p_a_v10' before 'p_a_v2'; numeric must
      // not.
      expect(v2.compareTo(v10), lessThan(0));
      expect(v10.compareTo(v2), greaterThan(0));
    });

    test('equal pair compares to zero', () {
      final a = ProcedureId(slug: 'a', version: 1);
      final b = ProcedureId(slug: 'a', version: 1);
      expect(a.compareTo(b), equals(0));
    });
  });
}
