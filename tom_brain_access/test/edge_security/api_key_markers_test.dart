// memory_session_profiles_plan.md step 2 — the pure §3.1 marker tokeniser
// `parseApiKeyMarkers`. Modelled on `telegram_command_test.dart`'s table style.
//
// Proves the whole §15 marker-parser table:
//   * prefix / suffix / interleaved markers all yield the same residual;
//   * a missing marker → null selector;
//   * both markers present;
//   * a duplicate session-/memory- marker throws (`marker.duplicate`);
//   * an empty residual (markers-only / empty token) → '';
//   * a `_` inside the real key survives as rejoined residual segments;
//   * leading / trailing / doubled underscores are absorbed.
//
// Pure, no I/O — the edge wiring (authenticate residual + apply prefixes) is
// plan step 5; this suite locks the grammar in isolation.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:test/test.dart';

void main() {
  group('parseApiKeyMarkers — § 3.1 grammar', () {
    test('a bare key with no markers → residual key, both selectors null', () {
      final markers = parseApiKeyMarkers('sk-real');
      expect(markers.residualKey, 'sk-real');
      expect(markers.sessionSelector, isNull);
      expect(markers.memorySelector, isNull);
    });

    test('a prefix session marker is stripped; residual is the key', () {
      final markers = parseApiKeyMarkers('session-foo_sk-real');
      expect(markers.residualKey, 'sk-real');
      expect(markers.sessionSelector, 'foo');
      expect(markers.memorySelector, isNull);
    });

    test('a suffix memory marker is stripped; residual is the key', () {
      final markers = parseApiKeyMarkers('sk-real_memory-bar');
      expect(markers.residualKey, 'sk-real');
      expect(markers.sessionSelector, isNull);
      expect(markers.memorySelector, 'bar');
    });

    test('interleaved markers yield the same residual and both selectors', () {
      final markers = parseApiKeyMarkers('session-foo_sk-real_memory-bar');
      expect(markers.residualKey, 'sk-real');
      expect(markers.sessionSelector, 'foo');
      expect(markers.memorySelector, 'bar');
    });

    test('marker order is irrelevant — all three orderings agree on residual',
        () {
      for (final token in <String>[
        'session-foo_sk-real_memory-bar',
        'memory-bar_session-foo_sk-real',
        'sk-real_session-foo_memory-bar',
      ]) {
        final markers = parseApiKeyMarkers(token);
        expect(markers.residualKey, 'sk-real', reason: token);
        expect(markers.sessionSelector, 'foo', reason: token);
        expect(markers.memorySelector, 'bar', reason: token);
      }
    });

    test('markers-only token → empty residual (the keyless / no-key case)', () {
      final markers = parseApiKeyMarkers('session-foo_memory-bar');
      expect(markers.residualKey, isEmpty);
      expect(markers.sessionSelector, 'foo');
      expect(markers.memorySelector, 'bar');
    });

    test('empty token → empty residual, both selectors null', () {
      final markers = parseApiKeyMarkers('');
      expect(markers.residualKey, isEmpty);
      expect(markers.sessionSelector, isNull);
      expect(markers.memorySelector, isNull);
    });

    test('a `_` inside the real key survives as rejoined residual segments',
        () {
      final markers = parseApiKeyMarkers('sk_real_key_memory-bar');
      expect(markers.residualKey, 'sk_real_key');
      expect(markers.memorySelector, 'bar');
      expect(markers.sessionSelector, isNull);
    });

    test('leading / trailing / doubled underscores are absorbed', () {
      final markers = parseApiKeyMarkers('__session-foo__sk-real__');
      expect(markers.residualKey, 'sk-real');
      expect(markers.sessionSelector, 'foo');
      expect(markers.memorySelector, isNull);
    });

    test('a marker value may itself contain a dash (verbatim, after the first '
        'literal)', () {
      final markers = parseApiKeyMarkers('session-foo-bar_sk-real');
      expect(markers.sessionSelector, 'foo-bar');
      expect(markers.residualKey, 'sk-real');
    });

    test('matching is case-sensitive: an uppercased literal is not a marker',
        () {
      final markers = parseApiKeyMarkers('Session-foo_sk-real');
      expect(markers.sessionSelector, isNull);
      // `Session-foo` is an ordinary residual segment, rejoined with the key.
      expect(markers.residualKey, 'Session-foo_sk-real');
    });
  });

  group('parseApiKeyMarkers — duplicate-marker error (§ 3.1 step 4)', () {
    test('two session markers throw duplicateMarker / code marker.duplicate',
        () {
      expect(
        () => parseApiKeyMarkers('session-a_session-b_sk-real'),
        throwsA(
          isA<ApiKeyMarkerException>()
              .having((e) => e.reason, 'reason',
                  ApiKeyMarkerFailureReason.duplicateMarker)
              .having((e) => e.code, 'code', 'marker.duplicate'),
        ),
      );
    });

    test('two memory markers throw duplicateMarker', () {
      expect(
        () => parseApiKeyMarkers('memory-a_memory-b_sk-real'),
        throwsA(isA<ApiKeyMarkerException>().having(
            (e) => e.reason, 'reason',
            ApiKeyMarkerFailureReason.duplicateMarker)),
      );
    });

    test('one of each is NOT a duplicate', () {
      expect(() => parseApiKeyMarkers('session-a_memory-b_sk-real'),
          returnsNormally);
    });
  });
}
