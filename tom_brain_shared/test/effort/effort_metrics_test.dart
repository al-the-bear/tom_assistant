// EffortMetrics unit tests (added at the C.48 reuse-extraction pass when
// the type moved into `tom_brain_shared`).
//
// Covers the value-type contract the run recorder and the dispatcher's
// harvester both rely on: zero defaults, the derived `estimatedTokens`,
// the `plus` fold and `withWallClockMs` copy, value equality / hashCode,
// the closed JSON shape, and the non-negativity asserts.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;

void main() {
  group('EffortMetrics', () {
    test('zero is all-zero and estimatedTokens is 0', () {
      const m = EffortMetrics.zero;
      expect(m.wallClockMs, 0);
      expect(m.llmCalls, 0);
      expect(m.inputTokens, 0);
      expect(m.outputTokens, 0);
      expect(m.toolCalls, 0);
      expect(m.memoryReads, 0);
      expect(m.memoryWrites, 0);
      expect(m.estimatedTokens, 0);
    });

    test('default constructor equals zero', () {
      expect(const EffortMetrics(), EffortMetrics.zero);
    });

    test('estimatedTokens is inputTokens + outputTokens', () {
      const m = EffortMetrics(inputTokens: 30, outputTokens: 12);
      expect(m.estimatedTokens, 42);
    });

    test('plus sums fieldwise', () {
      const a = EffortMetrics(
        wallClockMs: 1,
        llmCalls: 2,
        inputTokens: 3,
        outputTokens: 4,
        toolCalls: 5,
        memoryReads: 6,
        memoryWrites: 7,
      );
      const b = EffortMetrics(
        wallClockMs: 10,
        llmCalls: 20,
        inputTokens: 30,
        outputTokens: 40,
        toolCalls: 50,
        memoryReads: 60,
        memoryWrites: 70,
      );

      final sum = a.plus(b);

      expect(sum.wallClockMs, 11);
      expect(sum.llmCalls, 22);
      expect(sum.inputTokens, 33);
      expect(sum.outputTokens, 44);
      expect(sum.toolCalls, 55);
      expect(sum.memoryReads, 66);
      expect(sum.memoryWrites, 77);
    });

    test('plus is the identity with zero', () {
      const m = EffortMetrics(llmCalls: 3, inputTokens: 9);
      expect(m.plus(EffortMetrics.zero), m);
      expect(EffortMetrics.zero.plus(m), m);
    });

    test('withWallClockMs replaces only wallClockMs', () {
      const m = EffortMetrics(
        wallClockMs: 5,
        llmCalls: 2,
        inputTokens: 8,
      );

      final stamped = m.withWallClockMs(999);

      expect(stamped.wallClockMs, 999);
      expect(stamped.llmCalls, 2);
      expect(stamped.inputTokens, 8);
    });

    test('value equality and hashCode', () {
      const a = EffortMetrics(llmCalls: 1, inputTokens: 2);
      const b = EffortMetrics(llmCalls: 1, inputTokens: 2);
      const c = EffortMetrics(llmCalls: 1, inputTokens: 3);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('toJson carries the seven metrics plus the derived estimatedTokens',
        () {
      const m = EffortMetrics(
        wallClockMs: 100,
        llmCalls: 2,
        inputTokens: 30,
        outputTokens: 12,
        toolCalls: 1,
        memoryReads: 4,
        memoryWrites: 5,
      );

      final json = m.toJson();

      expect(json.keys.toSet(), <String>{
        'wallClockMs',
        'llmCalls',
        'inputTokens',
        'outputTokens',
        'toolCalls',
        'memoryReads',
        'memoryWrites',
        'estimatedTokens',
      });
      expect(json['estimatedTokens'], 42);
      expect(json['memoryWrites'], 5);
    });

    test('toJson is unmodifiable', () {
      expect(
        () => const EffortMetrics().toJson()['wallClockMs'] = 1,
        throwsUnsupportedError,
      );
    });

    test('negative fields trip the asserts', () {
      expect(() => EffortMetrics(wallClockMs: -1), throwsA(isA<AssertionError>()));
      expect(() => EffortMetrics(llmCalls: -1), throwsA(isA<AssertionError>()));
      expect(
          () => EffortMetrics(memoryWrites: -1), throwsA(isA<AssertionError>()));
    });
  });
}
