// PT-2.1 — the presentation helpers. Pure functions, so unit-tested directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/views/format.dart';

void main() {
  group('formatWallClock', () {
    test('seconds for >=1000ms', () => expect(formatWallClock(2100), '2.1s'));
    test('milliseconds below 1000', () => expect(formatWallClock(800), '800ms'));
    test('null → em dash', () => expect(formatWallClock(null), '—'));
  });

  group('formatClock', () {
    test('HH:MM:SS in local time', () {
      final t = DateTime(2026, 1, 1, 9, 4, 7);
      expect(formatClock(t), '09:04:07');
    });
    test('null → em dash', () => expect(formatClock(null), '—'));
  });
}
