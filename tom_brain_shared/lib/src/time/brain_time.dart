// `BrainTime` — the canonical timestamp value type for Tom Brain
// (Plan step A.15).
//
// Why a dedicated value type instead of raw `DateTime`:
//
//   * Two storage representations need to round-trip cheaply:
//       - Integer milliseconds since the Unix epoch (the SQLite-indexed
//         `createdAtMs` column from `memory_specification.md` § 12.2, the
//         ULID timestamp prefix, every range-query key).
//       - UTC `DateTime` (event JSON, trail dumps, log lines, the public
//         facade for code that wants conventional time arithmetic).
//     A wrapper that stores ms internally and projects both forms on
//     demand keeps the round-trip lossless and free.
//   * The UTC invariant is structural. The constructor accepts only a UTC
//     `DateTime` (or an int that is by construction zone-agnostic).
//     `BrainTime` never holds a local-time instant. Compare to the
//     `BrainEvent.toJson` assertion which catches the invariant only in
//     checked mode — by the time A.15's migration of `BrainEvent` lands,
//     local-time slip becomes a compile-time impossibility at the field
//     level.
//   * Ordering is total and trivially monotonic — it's an integer
//     compare. Memory's stack ordering, trail tail-reading, and the
//     dispatcher's preemption checkpoints all rely on a cheap `<`.
//   * "Now" is structurally injectable via [Clock] (see `clock.dart`).
//     Nothing in `tom_brain_shared` calls `DateTime.now()` outside the
//     `SystemClock` implementation. Tests freeze time by passing a
//     [FixedClock] or [MutableTestClock].
//
// Storage canonical form: integer milliseconds.
// The internal field is `int _ms`. The `DateTime` view is computed on
// demand and never cached — caching a UTC `DateTime` would double the
// memory footprint of every persisted timestamp, and `DateTime`'s
// constructor from a ms-int is allocation-light enough not to matter.
//
// Not implemented (deliberately):
//
//   * Sub-millisecond resolution. SQLite indexes on integer ms; ULID
//     timestamps are integer ms; the memory layer's resolution is
//     millisecond. Microsecond-precision time would force every
//     indexable column to grow without a consumer asking for it.
//   * Time zone metadata. Conversion to local time is a presentation
//     concern owned by the access layer.
//   * `Duration since(BrainTime other)` returning a signed `Duration`.
//     The brain's "time elapsed" reads always want `Duration` between an
//     earlier and a later instant; the asymmetric API is `later
//     .difference(earlier)`, matching `DateTime.difference`.

import 'clock.dart';

/// Canonical timestamp value type for Tom Brain.
///
/// Immutable. Stored internally as integer milliseconds since the Unix
/// epoch (always UTC). Projects two views on demand: [toMs] for indexed
/// storage and [toDateTime] for human-readable JSON / log output.
///
/// Equality and hash are by millisecond value. Two `BrainTime`s
/// constructed from the same instant (whether via [fromMs], [fromDateTime],
/// or [now]) compare equal.
///
/// Ordering is total and provided three ways:
///
///   * [compareTo] for use with `List.sort`.
///   * [<], [<=], [>], [>=] for direct call-site predicates.
///   * [isBefore], [isAfter], [isAtSameMomentAs] mirror the `DateTime`
///     vocabulary for code that reads more naturally that way.
final class BrainTime implements Comparable<BrainTime> {
  /// Canonical storage: milliseconds since the Unix epoch, UTC.
  final int _ms;

  /// Private constructor. Callers use the named factories, which validate
  /// input (range for [fromMs], UTC-ness for [fromDateTime]).
  const BrainTime._(this._ms);

  /// Constructs a [BrainTime] from a raw millisecond count.
  ///
  /// [ms] must be non-negative. Negative values would represent instants
  /// before 1970-01-01 UTC, which never occur in the brain (nothing
  /// pre-dates the epoch of "this brain came into existence", which is
  /// after 2025) and almost always indicate a sign bug at the caller.
  ///
  /// [ms] must also fit within the 48-bit ULID timestamp range so that
  /// any `BrainTime` can be used to seed a ULID without losing precision.
  /// That bound is `2^48 - 1 ≈ year 10895` — comfortably beyond any real
  /// use.
  factory BrainTime.fromMs(int ms) {
    if (ms < 0) {
      throw ArgumentError.value(
        ms,
        'ms',
        'BrainTime ms must be non-negative (got $ms); the brain has no '
            'pre-epoch timestamps and a negative value almost always '
            'indicates a sign bug at the caller',
      );
    }
    if (ms > _maxUlidCompatibleMs) {
      throw ArgumentError.value(
        ms,
        'ms',
        'BrainTime ms must fit in 48 bits to remain ULID-compatible '
            '(max $_maxUlidCompatibleMs)',
      );
    }
    return BrainTime._(ms);
  }

  /// Constructs a [BrainTime] from a `DateTime`.
  ///
  /// [dt] must be UTC. The constructor refuses local-time inputs rather
  /// than silently coercing — silent coercion is what would let a local-
  /// time bug slip past the type system into the millisecond store and
  /// reappear as drift in retrieval ordering or off-by-one in a budget
  /// deadline. Callers with a local-time `DateTime` must call `.toUtc()`
  /// at the call site, so the conversion is named where it happens.
  factory BrainTime.fromDateTime(DateTime dt) {
    if (!dt.isUtc) {
      throw ArgumentError.value(
        dt,
        'dt',
        'BrainTime.fromDateTime requires a UTC DateTime; call .toUtc() at '
            'the call site if your source is local time',
      );
    }
    return BrainTime.fromMs(dt.millisecondsSinceEpoch);
  }

  /// Constructs a [BrainTime] for the current instant as observed by
  /// [clock].
  ///
  /// `clock` is required. There is no default — the whole point of the
  /// [Clock] abstraction is that callers say which clock they read.
  /// Production code injects `const SystemClock()`; tests inject a
  /// [FixedClock] or [MutableTestClock].
  factory BrainTime.now(Clock clock) => clock.nowBrainTime();

  /// Parses an ISO-8601 string produced by [toIso8601String].
  ///
  /// Round-trip: `BrainTime.parse(t.toIso8601String()) == t` for any
  /// in-range `t`. Throws [FormatException] when the input does not
  /// parse, and [ArgumentError] when it parses but the result is out of
  /// range (e.g. negative or beyond the 48-bit ULID bound).
  factory BrainTime.parse(String iso) {
    final dt = DateTime.parse(iso).toUtc();
    return BrainTime.fromMs(dt.millisecondsSinceEpoch);
  }

  /// Constructs from explicit UTC components. Mirrors `DateTime.utc`.
  /// Convenience for test fixtures and ad-hoc constants.
  factory BrainTime.utc(
    int year, [
    int month = 1,
    int day = 1,
    int hour = 0,
    int minute = 0,
    int second = 0,
    int millisecond = 0,
  ]) =>
      BrainTime.fromDateTime(
        DateTime.utc(year, month, day, hour, minute, second, millisecond),
      );

  /// The Unix epoch (1970-01-01T00:00:00Z). Useful as a sentinel.
  static const BrainTime epoch = BrainTime._(0);

  /// Upper bound on the ms field — 48 bits, matching the ULID timestamp
  /// range. Picked so any `BrainTime` can drive `Ulid.generate(at: ...)`
  /// without losing precision.
  static const int _maxUlidCompatibleMs = 0xFFFFFFFFFFFF;

  /// Returns the canonical integer-ms form, suitable for SQLite indexes
  /// and ULID timestamp prefixes.
  int toMs() => _ms;

  /// Returns the UTC `DateTime` view. Computed on demand; not cached.
  DateTime toDateTime() => DateTime.fromMillisecondsSinceEpoch(_ms, isUtc: true);

  /// Returns the ISO-8601 UTC string form.
  ///
  /// Equivalent to `toDateTime().toIso8601String()` and round-trips
  /// through [BrainTime.parse].
  String toIso8601String() => toDateTime().toIso8601String();

  /// Returns this instant shifted forward by [delta].
  ///
  /// [delta] may be negative (use [minus] for clarity if subtracting).
  BrainTime plus(Duration delta) => BrainTime.fromMs(_ms + delta.inMilliseconds);

  /// Returns this instant shifted backward by [delta].
  ///
  /// Equivalent to `plus(-delta)`. Provided so subtraction reads naturally
  /// at the call site without negating a duration manually.
  BrainTime minus(Duration delta) =>
      BrainTime.fromMs(_ms - delta.inMilliseconds);

  /// Duration from [earlier] to this instant.
  ///
  /// Positive when this instant is later than [earlier]. Mirrors
  /// `DateTime.difference`: `later.difference(earlier)` is the natural
  /// reading order.
  Duration difference(BrainTime earlier) =>
      Duration(milliseconds: _ms - earlier._ms);

  /// True when this instant is strictly before [other].
  bool isBefore(BrainTime other) => _ms < other._ms;

  /// True when this instant is strictly after [other].
  bool isAfter(BrainTime other) => _ms > other._ms;

  /// True when this instant equals [other] (same millisecond).
  bool isAtSameMomentAs(BrainTime other) => _ms == other._ms;

  @override
  int compareTo(BrainTime other) => _ms.compareTo(other._ms);

  /// Strictly-before comparator. Equivalent to [isBefore].
  bool operator <(BrainTime other) => _ms < other._ms;

  /// At-or-before comparator.
  bool operator <=(BrainTime other) => _ms <= other._ms;

  /// Strictly-after comparator. Equivalent to [isAfter].
  bool operator >(BrainTime other) => _ms > other._ms;

  /// At-or-after comparator.
  bool operator >=(BrainTime other) => _ms >= other._ms;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is BrainTime && other._ms == _ms);

  @override
  int get hashCode => _ms.hashCode;

  /// Debug-friendly representation. Not part of any wire format — wire
  /// serialisation uses [toMs] or [toIso8601String] explicitly.
  @override
  String toString() => 'BrainTime($_ms, ${toIso8601String()})';
}
