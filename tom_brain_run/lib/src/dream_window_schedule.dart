// Dream window schedule (item b) — the daily time-slots dreaming is allowed in.
//
// The dream config carries "several time-slots in a day" during which the
// scheduled dream cadence may run (e.g. `02:00`–`05:00` and `13:00`–`14:00`).
// This file owns the pure value types that model those slots and answer the one
// question the [DreamController] gate asks each heartbeat: *is now inside any
// configured window?*
//
// Both types are pure timing primitives — no clock, no I/O. The controller
// supplies the wall-clock instant (local time, since a human configures
// "between 2 and 5 at night" in local terms); the schedule only does interval
// arithmetic on minute-of-day. That keeps the window logic exhaustively unit
// testable independently of any time source.
//
// Semantics:
//
//   * A [DreamWindow] is a half-open interval `[start, end)` over minute-of-day.
//     `start < end` is a same-day window; `start > end` wraps past midnight
//     (e.g. `23:00`–`02:00` covers 23:00..23:59 and 00:00..01:59). A zero-length
//     window (`start == end`) is rejected — it would match nothing, so it is
//     almost certainly a config mistake.
//   * A [DreamWindowSchedule] is the *union* of its windows. An **empty**
//     schedule is "always active": an operator that enables dreaming but names
//     no windows wants the brain to dream whenever it is otherwise idle, not
//     never.

/// One daily time-slot dreaming is allowed in — a half-open `[start, end)`
/// minute-of-day interval that may wrap past midnight.
final class DreamWindow {
  /// Builds a window from explicit minute-of-day bounds.
  ///
  /// [startMinute] is in `[0, 1439]`; [endMinute] is in `[1, 1440]` (1440 is the
  /// exclusive end-of-day `24:00`). The two must differ — a zero-length window
  /// matches nothing.
  const DreamWindow({required this.startMinute, required this.endMinute});

  /// Parses a `"HH:MM"`–`"HH:MM"` slot into a [DreamWindow].
  ///
  /// Each bound is `HH:MM` with `HH` in `0..24` and `MM` in `0..59`; the special
  /// value `24:00` (= 1440) is the exclusive end-of-day. A malformed bound or a
  /// zero-length window is a [FormatException].
  factory DreamWindow.parse(String start, String end) {
    final startMinute = _parseMinuteOfDay(start);
    final endMinute = _parseMinuteOfDay(end);
    if (startMinute == endMinute) {
      throw FormatException(
        'Dream window must have positive length; got $start–$end.',
      );
    }
    return DreamWindow(startMinute: startMinute, endMinute: endMinute);
  }

  /// The inclusive start, in minutes since local midnight (`0..1439`).
  final int startMinute;

  /// The exclusive end, in minutes since local midnight (`1..1440`).
  final int endMinute;

  /// Whether the local wall-clock [instant] falls inside this window.
  ///
  /// Half-open: the start minute is included, the end minute excluded. A
  /// wrapping window (`startMinute > endMinute`) matches an instant that is at or
  /// after the start *or* strictly before the end.
  bool contains(DateTime instant) {
    final minute = instant.hour * 60 + instant.minute;
    if (startMinute < endMinute) {
      return minute >= startMinute && minute < endMinute;
    }
    // Wrapping window: [start, 24:00) ∪ [00:00, end).
    return minute >= startMinute || minute < endMinute;
  }

  /// Parses a `HH:MM` bound into minute-of-day, accepting `24:00` as 1440.
  static int _parseMinuteOfDay(String hhmm) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
    if (match == null) {
      throw FormatException('Malformed time "$hhmm"; expected HH:MM.');
    }
    final hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    if (minutes > 59 || hours > 24 || (hours == 24 && minutes != 0)) {
      throw FormatException('Time "$hhmm" is out of range (00:00..24:00).');
    }
    return hours * 60 + minutes;
  }
}

/// The union of the daily dream windows — the "several time-slots in a day"
/// dreaming is allowed in (item b).
///
/// An **empty** schedule is always active: enabling dreaming without naming any
/// window means "dream whenever otherwise idle", not "never dream".
final class DreamWindowSchedule {
  /// Builds a schedule over [windows] (copied unmodifiable).
  DreamWindowSchedule({required List<DreamWindow> windows})
      : windows = List<DreamWindow>.unmodifiable(windows);

  /// Builds a schedule from a list of `{start, end}` `HH:MM` slot maps — the
  /// shape the `dream.windows` config section carries.
  ///
  /// Each slot must hold a `start` and an `end` string; a malformed bound or a
  /// zero-length window surfaces as a [FormatException] from [DreamWindow.parse].
  factory DreamWindowSchedule.parseSlots(List<Map<String, String>> slots) =>
      DreamWindowSchedule(
        windows: <DreamWindow>[
          for (final slot in slots)
            DreamWindow.parse(slot['start']!, slot['end']!),
        ],
      );

  /// The configured windows, in declaration order.
  final List<DreamWindow> windows;

  /// Whether this schedule imposes no window restriction (empty windows).
  bool get isAlwaysActive => windows.isEmpty;

  /// Whether the local wall-clock [instant] falls in any configured window.
  ///
  /// An empty schedule ([isAlwaysActive]) is always active.
  bool isActiveAt(DateTime instant) {
    if (windows.isEmpty) return true;
    for (final window in windows) {
      if (window.contains(instant)) return true;
    }
    return false;
  }
}
