// Tests for the four ULID-based ID types: NodeId, EdgeId, TrailId,
// StackEntryId (Plan step A.10).
//
// These four share the `<prefix>_<26-char-ULID>` shape and therefore the
// same battery of invariants: generate produces a parseable value,
// fromString round-trips, the wrong prefix is rejected, an invalid ULID
// payload is rejected, equality is value-based, equality is type-aware
// (a NodeId is never equal to an EdgeId even if the value strings would
// otherwise match — they can't, but we check anyway), and compareTo
// preserves ULID lexicographic order.
//
// The five-IDs ProcedureId is a different shape and has its own test
// file.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Driver that codifies the per-subclass behaviour as a set of named
/// closures so the same test bodies run against all four ID types
/// without duplication.
class _IdContract {
  final String name;
  final String prefix;
  final PrefixedUlidId Function() generate;
  final PrefixedUlidId Function(String) fromString;

  const _IdContract({
    required this.name,
    required this.prefix,
    required this.generate,
    required this.fromString,
  });
}

void _runContract(_IdContract c) {
  group('${c.name} (prefix "${c.prefix}_")', () {
    test('generate produces a value with the correct prefix and ULID', () {
      final id = c.generate();
      expect(id.value.startsWith('${c.prefix}_'), isTrue);
      expect(Ulid.isValid(id.ulid), isTrue);
      expect(id.prefix, equals(c.prefix));
    });

    test('fromString round-trips a generated id', () {
      final original = c.generate();
      final parsed = c.fromString(original.value);
      expect(parsed.value, equals(original.value));
      expect(parsed, equals(original));
    });

    test('toString matches the canonical value', () {
      final id = c.generate();
      expect(id.toString(), equals(id.value));
    });

    test('instant recovers the encoded timestamp', () {
      // We can't go through `generate()` here because we want a known
      // timestamp; the test names a specific instant.
      final t = DateTime.utc(2026, 5, 30, 12, 0, 0);
      final ulid = Ulid.generate(at: t);
      final parsed = c.fromString('${c.prefix}_$ulid');
      expect(parsed.instant, equals(t));
    });

    test('fromString rejects missing prefix', () {
      // Bare ULID without prefix is rejected.
      final ulid = Ulid.generate();
      expect(
        () => c.fromString(ulid),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromString rejects the wrong prefix', () {
      // Build a sibling with a different prefix from the same ULID.
      final ulid = Ulid.generate();
      const allPrefixes = ['n', 'e', 't', 'se', 'p', 'x', 'unknown'];
      for (final p in allPrefixes) {
        if (p == c.prefix) continue;
        expect(
          () => c.fromString('${p}_$ulid'),
          throwsA(isA<FormatException>()),
          reason: 'wrong-prefix "$p" should be rejected for ${c.name}',
        );
      }
    });

    test('fromString rejects an invalid ULID payload', () {
      // Correct prefix, wrong payload.
      expect(
        () => c.fromString('${c.prefix}_NOT_A_VALID_ULID_PAYLOAD'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => c.fromString('${c.prefix}_'), // empty payload
        throwsA(isA<FormatException>()),
      );
    });

    test('two ids built from the same value are equal', () {
      final ulid = Ulid.generate();
      final a = c.fromString('${c.prefix}_$ulid');
      final b = c.fromString('${c.prefix}_$ulid');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('two ids built from different values are not equal', () {
      final a = c.generate();
      final b = c.generate();
      expect(a, isNot(equals(b)));
    });

    test('compareTo agrees with chronological order', () {
      final earlier = c.fromString(
        '${c.prefix}_${Ulid.generate(at: DateTime.utc(2020))}',
      );
      final later = c.fromString(
        '${c.prefix}_${Ulid.generate(at: DateTime.utc(2030))}',
      );
      expect(earlier.compareTo(later), lessThan(0));
      expect(later.compareTo(earlier), greaterThan(0));
      expect(earlier.compareTo(earlier), equals(0));
    });
  });
}

void main() {
  _runContract(_IdContract(
    name: 'NodeId',
    prefix: 'n',
    generate: NodeId.generate,
    fromString: NodeId.fromString,
  ));

  _runContract(_IdContract(
    name: 'EdgeId',
    prefix: 'e',
    generate: EdgeId.generate,
    fromString: EdgeId.fromString,
  ));

  _runContract(_IdContract(
    name: 'TrailId',
    prefix: 't',
    generate: TrailId.generate,
    fromString: TrailId.fromString,
  ));

  _runContract(_IdContract(
    name: 'StackEntryId',
    prefix: 'se',
    generate: StackEntryId.generate,
    fromString: StackEntryId.fromString,
  ));

  group('cross-type discipline', () {
    test('NodeId and EdgeId with the same payload string are not equal', () {
      final ulid = Ulid.generate();
      final n = NodeId.fromString('n_$ulid');
      final e = EdgeId.fromString('e_$ulid');
      // The value strings already differ ("n_…" vs "e_…"), so this is a
      // belt-and-braces check that confirms the runtimeType-aware
      // equality.
      expect(n, isNot(equals(e)));
      expect(n.hashCode, isNot(equals(e.hashCode)));
    });

    test('StackEntryId.fromString rejects an "s_" prefix', () {
      // The prefix is `se`; a single-letter `s_` must not be coerced.
      final ulid = Ulid.generate();
      expect(
        () => StackEntryId.fromString('s_$ulid'),
        throwsA(isA<FormatException>()),
      );
    });

    test('TrailId.fromString rejects a NodeId value', () {
      final n = NodeId.generate();
      expect(
        () => TrailId.fromString(n.value),
        throwsA(isA<FormatException>()),
      );
    });

    test('PrefixedUlidId base type accepts polymorphic use', () {
      // The point of exporting the abstract base: consumers can write
      // functions that take any prefixed-ULID id.
      final ids = <PrefixedUlidId>[
        NodeId.generate(),
        EdgeId.generate(),
        TrailId.generate(),
        StackEntryId.generate(),
      ];
      for (final id in ids) {
        expect(id.ulid, hasLength(Ulid.totalLength));
        expect(id.value, contains('_'));
      }
    });
  });
}
