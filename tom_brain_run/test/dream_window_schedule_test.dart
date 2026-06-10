// Dream window schedule (item b) — the pure daily time-slot primitive.
//
// `DreamWindow` is a half-open minute-of-day interval `[start, end)`; a window
// whose start is after its end wraps past midnight. `DreamWindowSchedule` is the
// union of several such windows — the "several time-slots in a day" the dream
// config carries — and decides whether a given local wall-clock instant falls in
// any of them. Both are pure: no clock, no I/O, so they are exhaustively unit
// testable.

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

/// A local wall-clock instant at [h]:[m] on an arbitrary fixed day.
DateTime _at(int h, int m) => DateTime(2026, 6, 10, h, m);

void main() {
  group('DreamWindow.parse', () {
    test('parses HH:MM start/end into minute-of-day bounds', () {
      final w = DreamWindow.parse('02:30', '05:00');
      expect(w.startMinute, 150); // 2*60 + 30
      expect(w.endMinute, 300); // 5*60
    });

    test('accepts 24:00 as the exclusive end-of-day bound', () {
      final w = DreamWindow.parse('22:00', '24:00');
      expect(w.endMinute, 1440);
    });

    test('rejects a zero-length window', () {
      expect(() => DreamWindow.parse('03:00', '03:00'),
          throwsA(isA<FormatException>()));
    });

    test('rejects a malformed time string', () {
      expect(() => DreamWindow.parse('2am', '05:00'),
          throwsA(isA<FormatException>()));
      expect(() => DreamWindow.parse('02:00', '25:00'),
          throwsA(isA<FormatException>()));
      expect(() => DreamWindow.parse('02:60', '05:00'),
          throwsA(isA<FormatException>()));
    });
  });

  group('DreamWindow.contains (same-day window)', () {
    final w = DreamWindow.parse('02:00', '05:00');

    test('includes the start, excludes the end (half-open)', () {
      expect(w.contains(_at(2, 0)), isTrue);
      expect(w.contains(_at(4, 59)), isTrue);
      expect(w.contains(_at(5, 0)), isFalse); // exclusive end
      expect(w.contains(_at(1, 59)), isFalse);
    });
  });

  group('DreamWindow.contains (midnight-wrapping window)', () {
    final w = DreamWindow.parse('23:00', '02:00');

    test('includes instants on both sides of midnight', () {
      expect(w.contains(_at(23, 0)), isTrue);
      expect(w.contains(_at(23, 30)), isTrue);
      expect(w.contains(_at(0, 0)), isTrue);
      expect(w.contains(_at(1, 59)), isTrue);
      expect(w.contains(_at(2, 0)), isFalse); // exclusive end
      expect(w.contains(_at(12, 0)), isFalse);
    });
  });

  group('DreamWindowSchedule', () {
    test('an empty schedule is always active (enabled, no windows)', () {
      final schedule = DreamWindowSchedule(windows: <DreamWindow>[]);
      expect(schedule.isActiveAt(_at(3, 0)), isTrue);
      expect(schedule.isActiveAt(_at(15, 0)), isTrue);
      expect(schedule.isAlwaysActive, isTrue);
    });

    test('is active when the instant falls in any window (union)', () {
      final schedule = DreamWindowSchedule(windows: <DreamWindow>[
        DreamWindow.parse('02:00', '05:00'),
        DreamWindow.parse('13:00', '14:00'),
      ]);
      expect(schedule.isActiveAt(_at(3, 0)), isTrue); // window 1
      expect(schedule.isActiveAt(_at(13, 30)), isTrue); // window 2
      expect(schedule.isActiveAt(_at(8, 0)), isFalse); // neither
      expect(schedule.isAlwaysActive, isFalse);
    });

    test('parseSlots builds the schedule from {start,end} maps', () {
      final schedule = DreamWindowSchedule.parseSlots(<Map<String, String>>[
        <String, String>{'start': '02:00', 'end': '05:00'},
        <String, String>{'start': '23:00', 'end': '01:00'},
      ]);
      expect(schedule.windows, hasLength(2));
      expect(schedule.isActiveAt(_at(0, 30)), isTrue); // wraps past midnight
    });
  });
}
