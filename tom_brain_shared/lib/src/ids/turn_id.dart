// TurnId — correlates every record produced while serving one inbound request
// (logging-spec §3).
//
// Shape: a bare UTC timestamp `YYMMDD-HHMMSS.ssssss` (microsecond precision),
// e.g. `260608-190316.402355` — backed by `TimestampId`. Minted once at the
// access edge the instant an inbound request is admitted, then threaded through
// the whole turn — Access → dispatcher → procedure engine → substrate call — so
// a trail filename / log line *starts with the turn's timestamp* and `turnId` +
// `callSeq` uniquely name any LLM call across the system.
//
// This supersedes the earlier `turn_<ULID>` (`PrefixedUlidId`) scheme: the
// timestamp *is* the id, so trail files sort chronologically by name and are
// readable at a glance. `TurnId` stays a distinct nominal type for call-site
// type-safety, but its string form is the bare timestamp.

import 'timestamp_id.dart';

/// Identifier of a single turn — the unit of work that serves one inbound
/// request from admission to final answer.
final class TurnId implements Comparable<TurnId> {
  /// The underlying bare-timestamp id.
  final TimestampId stamp;

  const TurnId._(this.stamp);

  /// Generates a fresh `TurnId`.
  ///
  /// When [at] is omitted the value is monotonic wall-clock (collision-free);
  /// when supplied it is exactly that instant (used by tests for determinism).
  factory TurnId.generate({DateTime? at}) =>
      TurnId._(TimestampId.generate(at: at));

  /// Parses a `TurnId` from its canonical string form.
  ///
  /// Throws [FormatException] when `value` is not a valid
  /// `YYMMDD-HHMMSS.ssssss` timestamp.
  factory TurnId.fromString(String value) =>
      TurnId._(TimestampId.fromString(value));

  /// Full canonical form: `YYMMDD-HHMMSS.ssssss`.
  String get value => stamp.value;

  /// The UTC instant this turn id encodes.
  DateTime get instant => stamp.instant;

  @override
  int compareTo(TurnId other) => stamp.compareTo(other.stamp);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is TurnId && other.stamp == stamp);

  @override
  int get hashCode => Object.hash(TurnId, stamp);

  @override
  String toString() => value;
}
