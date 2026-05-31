// Tests for `DiagnosticSeverity` and `DiagnosticSeverityCompare`
// (Plan step A.14).
//
// Surface under test:
//   * Five levels declared in the documented order (debug → error).
//   * Enum ordering by `.index` matches the severity ordering.
//   * `atLeast` returns true when this severity ≥ threshold.
//   * Operators `<` and `<=` agree with `.index` comparison.
//   * `.name` returns the lowercase enum-constant name for JSON
//     serialisation (used by DiagnosticEnvelope.toJson).

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('DiagnosticSeverity', () {
    test('declares five levels in severity order', () {
      expect(DiagnosticSeverity.values, hasLength(5));
      expect(
        DiagnosticSeverity.values,
        orderedEquals(<DiagnosticSeverity>[
          DiagnosticSeverity.debug,
          DiagnosticSeverity.info,
          DiagnosticSeverity.notice,
          DiagnosticSeverity.warning,
          DiagnosticSeverity.error,
        ]),
      );
    });

    test('index matches the severity order', () {
      expect(DiagnosticSeverity.debug.index, equals(0));
      expect(DiagnosticSeverity.info.index, equals(1));
      expect(DiagnosticSeverity.notice.index, equals(2));
      expect(DiagnosticSeverity.warning.index, equals(3));
      expect(DiagnosticSeverity.error.index, equals(4));
    });

    test('name returns the enum constant name for JSON encoding', () {
      expect(DiagnosticSeverity.debug.name, equals('debug'));
      expect(DiagnosticSeverity.info.name, equals('info'));
      expect(DiagnosticSeverity.notice.name, equals('notice'));
      expect(DiagnosticSeverity.warning.name, equals('warning'));
      expect(DiagnosticSeverity.error.name, equals('error'));
    });
  });

  group('DiagnosticSeverityCompare.atLeast', () {
    test('true when this severity equals the threshold', () {
      expect(
        DiagnosticSeverity.info.atLeast(DiagnosticSeverity.info),
        isTrue,
      );
    });

    test('true when this severity exceeds the threshold', () {
      expect(
        DiagnosticSeverity.error.atLeast(DiagnosticSeverity.warning),
        isTrue,
      );
      expect(
        DiagnosticSeverity.warning.atLeast(DiagnosticSeverity.notice),
        isTrue,
      );
    });

    test('false when this severity is below the threshold', () {
      expect(
        DiagnosticSeverity.debug.atLeast(DiagnosticSeverity.info),
        isFalse,
      );
      expect(
        DiagnosticSeverity.notice.atLeast(DiagnosticSeverity.warning),
        isFalse,
      );
    });

    test('filters a stream by severity threshold', () async {
      final all = <DiagnosticSeverity>[
        DiagnosticSeverity.debug,
        DiagnosticSeverity.info,
        DiagnosticSeverity.notice,
        DiagnosticSeverity.warning,
        DiagnosticSeverity.error,
      ];
      final filtered = all
          .where((s) => s.atLeast(DiagnosticSeverity.warning))
          .toList();
      expect(
        filtered,
        equals(<DiagnosticSeverity>[
          DiagnosticSeverity.warning,
          DiagnosticSeverity.error,
        ]),
      );
    });
  });

  group('DiagnosticSeverityCompare operators', () {
    test('< is strict less-than by index', () {
      expect(
        DiagnosticSeverity.debug < DiagnosticSeverity.info,
        isTrue,
      );
      expect(
        DiagnosticSeverity.info < DiagnosticSeverity.info,
        isFalse,
      );
      expect(
        DiagnosticSeverity.error < DiagnosticSeverity.warning,
        isFalse,
      );
    });

    test('<= is less-than-or-equal by index', () {
      expect(
        DiagnosticSeverity.info <= DiagnosticSeverity.info,
        isTrue,
      );
      expect(
        DiagnosticSeverity.debug <= DiagnosticSeverity.warning,
        isTrue,
      );
      expect(
        DiagnosticSeverity.error <= DiagnosticSeverity.warning,
        isFalse,
      );
    });
  });
}
