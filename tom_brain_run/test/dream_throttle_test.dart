// DreamThrottle (dream-redesign part d) — the sliding-window rate limiter that
// bounds how many LLM-using dream agents may fire per window.
//
// These tests pin the throttle in isolation: the global cap, the per-lane cap
// stacking on top of it, the embedding-only exemption, that a denied acquire
// costs no budget, and that budget is released as tokens age past the window.
//
// Test ids: TH-1 … TH-7.

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

void main() {
  group('DreamThrottle', () {
    test('TH-1: a positive global cap admits exactly that many per window', () {
      final throttle = DreamThrottle(
        maxCallsPerWindow: 3,
        window: const Duration(seconds: 60),
      );
      // Same instant: three admitted, the fourth denied.
      expect(throttle.tryAcquire('fast', 0), isTrue);
      expect(throttle.tryAcquire('fast', 0), isTrue);
      expect(throttle.tryAcquire('fast', 0), isTrue);
      expect(throttle.tryAcquire('fast', 0), isFalse);
    });

    test('TH-2: budget is released once tokens age past the window', () {
      final throttle = DreamThrottle(
        maxCallsPerWindow: 2,
        window: const Duration(seconds: 60),
      );
      expect(throttle.tryAcquire('fast', 0), isTrue);
      expect(throttle.tryAcquire('fast', 0), isTrue);
      expect(throttle.tryAcquire('fast', 0), isFalse);

      // 60s later the two original tokens have aged out (cut-off is inclusive).
      expect(throttle.tryAcquire('fast', 60000), isTrue);
      expect(throttle.tryAcquire('fast', 60000), isTrue);
      expect(throttle.tryAcquire('fast', 60000), isFalse);
    });

    test('TH-3: a per-lane cap bounds one lane below the global budget', () {
      final throttle = DreamThrottle(
        maxCallsPerWindow: 10,
        window: const Duration(seconds: 60),
        perLaneMaxCallsPerWindow: <String, int>{'noisy': 1},
      );
      expect(throttle.tryAcquire('noisy', 0), isTrue);
      // The lane is capped at 1 even though the global budget has 9 left.
      expect(throttle.tryAcquire('noisy', 0), isFalse);
      // A different, uncapped lane still draws on the global budget.
      expect(throttle.tryAcquire('other', 0), isTrue);
    });

    test('TH-4: an exhausted global budget denies even an under-cap lane', () {
      final throttle = DreamThrottle(
        maxCallsPerWindow: 1,
        window: const Duration(seconds: 60),
        perLaneMaxCallsPerWindow: <String, int>{'noisy': 5},
      );
      expect(throttle.tryAcquire('noisy', 0), isTrue);
      // Lane budget has room (1 of 5) but the global budget is spent.
      expect(throttle.tryAcquire('noisy', 0), isFalse);
    });

    test('TH-5: a denied acquire consumes no budget', () {
      final throttle = DreamThrottle(
        maxCallsPerWindow: 1,
        window: const Duration(seconds: 60),
      );
      expect(throttle.tryAcquire('fast', 0), isTrue);
      expect(throttle.tryAcquire('fast', 0), isFalse);
      expect(throttle.tryAcquire('fast', 0), isFalse);
      // After the window clears, exactly one slot is free again — the denials
      // never counted against it.
      expect(throttle.tryAcquire('fast', 60000), isTrue);
      expect(throttle.tryAcquire('fast', 60000), isFalse);
    });

    test('TH-6: the embedding-only agents are exempt by default', () {
      final throttle = DreamThrottle(
        maxCallsPerWindow: 1,
        window: const Duration(seconds: 60),
      );
      for (final agent in DreamThrottle.defaultEmbeddingOnlyAgents) {
        expect(throttle.isExempt(agent), isTrue, reason: agent);
      }
      expect(throttle.isExempt('dream_extract_v1'), isFalse);
    });

    test('TH-7: a custom exempt set overrides the default', () {
      final throttle = DreamThrottle(
        maxCallsPerWindow: 1,
        window: const Duration(seconds: 60),
        embeddingOnlyAgents: <String>{'my_embedder_v1'},
      );
      expect(throttle.isExempt('my_embedder_v1'), isTrue);
      // The default members are no longer exempt under the custom set.
      expect(throttle.isExempt('dream_recentroid_v1'), isFalse);
    });

    test('TH-8: a non-positive bound is rejected at construction', () {
      expect(
        () => DreamThrottle(
            maxCallsPerWindow: 0, window: const Duration(seconds: 60)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () =>
            DreamThrottle(maxCallsPerWindow: 1, window: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('DreamThrottleSettings', () {
    test('TH-9: rejects non-positive bounds', () {
      expect(
        () => DreamThrottleSettings(
            maxCallsPerWindow: 0, window: const Duration(seconds: 1)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => DreamThrottleSettings(
            maxCallsPerWindow: 1, window: Duration.zero),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
