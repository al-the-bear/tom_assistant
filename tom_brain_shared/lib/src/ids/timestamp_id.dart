// TimestampId — a bare UTC-timestamp identifier of the form
// `YYMMDD-HHMMSS.ssssss` (microsecond precision), e.g. `260608-190316.402355`.
//
// This is the id scheme behind `TurnId` and the access-layer `sessionId`
// (logging-spec §3). Two properties make it the right shape for the trail
// surfaces:
//
//   * **It is its own timestamp.** Every trail file is named after the id, so a
//     file literally *starts with the moment it was produced*. Sorting a folder
//     by name sorts it by time; a glance at a filename tells you when. The
//     trail-cap janitor (logging-spec §10) relies on lexicographic order
//     equalling chronological order — a fixed-width zero-padded timestamp gives
//     exactly that.
//   * **It carries no prefix.** Unlike `turn_<ULID>` / `sess-<ts>-<n>`, there is
//     no leading token to strip before the timestamp is readable.
//
// Uniqueness without randomness: `generate()` is **monotonic**. Wall-clock
// microseconds are unique in the common case, but two ids minted inside the same
// microsecond would collide; the generator advances to the next free microsecond
// instead, so the value is collision-free without a random or counter suffix.
// The id may therefore drift a few microseconds ahead of the wall clock under a
// burst — an accepted, documented trade for a clean, suffix-free id.
//
// `TimestampId` is deliberately *not* a memory-node primary key (those stay
// `n_<ULID>`), so this scheme has no SQLite impact.

/// A bare UTC-timestamp identifier of the form `YYMMDD-HHMMSS.ssssss`.
final class TimestampId implements Comparable<TimestampId> {
  /// Canonical form: `YYMMDD-HHMMSS.ssssss` (UTC, microsecond precision).
  final String value;

  const TimestampId._(this.value);

  /// `YYMMDD-HHMMSS.ssssss`: 6-digit date, `-`, 6-digit time, `.`, 6-digit micros.
  static final RegExp _pattern = RegExp(r'^\d{6}-\d{6}\.\d{6}$');

  /// High-water mark used to keep [generate] strictly increasing.
  static int _lastMicros = 0;

  /// Generates a fresh `TimestampId`.
  ///
  /// When [at] is omitted the value is taken from the wall clock and is
  /// **monotonic** — strictly greater than every prior generated value, so
  /// successive ids never collide. When [at] is supplied the value is exactly
  /// that instant (used by tests for determinism); the supplied path does not
  /// touch the monotonic high-water mark.
  factory TimestampId.generate({DateTime? at}) {
    if (at != null) {
      return TimestampId._(format(at.toUtc().microsecondsSinceEpoch));
    }
    var micros = DateTime.now().microsecondsSinceEpoch;
    if (micros <= _lastMicros) {
      micros = _lastMicros + 1;
    }
    _lastMicros = micros;
    return TimestampId._(format(micros));
  }

  /// Parses a `TimestampId` from its canonical string form.
  ///
  /// Throws [FormatException] when `value` does not match `YYMMDD-HHMMSS.ssssss`.
  factory TimestampId.fromString(String value) {
    if (!_pattern.hasMatch(value)) {
      throw FormatException(
        'TimestampId must match YYMMDD-HHMMSS.ssssss',
        value,
      );
    }
    return TimestampId._(value);
  }

  /// Whether `value` is a well-formed `TimestampId` string.
  static bool isValid(String value) => _pattern.hasMatch(value);

  /// Formats microseconds-since-epoch as `YYMMDD-HHMMSS.ssssss` in UTC.
  static String format(int microsSinceEpoch) {
    final dt = DateTime.fromMicrosecondsSinceEpoch(
      microsSinceEpoch,
      isUtc: true,
    );
    final micros = microsSinceEpoch.remainder(1000000).abs();
    final yy = _pad2(dt.year % 100);
    final mo = _pad2(dt.month);
    final da = _pad2(dt.day);
    final hh = _pad2(dt.hour);
    final mi = _pad2(dt.minute);
    final ss = _pad2(dt.second);
    final us = micros.toString().padLeft(6, '0');
    return '$yy$mo$da-$hh$mi$ss.$us';
  }

  /// The UTC instant this id encodes (microsecond precision).
  ///
  /// The two-digit year is interpreted as `2000 + YY`.
  DateTime get instant {
    final yy = 2000 + int.parse(value.substring(0, 2));
    final mo = int.parse(value.substring(2, 4));
    final da = int.parse(value.substring(4, 6));
    final hh = int.parse(value.substring(7, 9));
    final mi = int.parse(value.substring(9, 11));
    final ss = int.parse(value.substring(11, 13));
    final us = int.parse(value.substring(14, 20));
    return DateTime.utc(yy, mo, da, hh, mi, ss, us ~/ 1000, us % 1000);
  }

  static String _pad2(int v) => v.toString().padLeft(2, '0');

  @override
  int compareTo(TimestampId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TimestampId && other.value == value);

  @override
  int get hashCode => Object.hash(TimestampId, value);

  @override
  String toString() => value;
}
