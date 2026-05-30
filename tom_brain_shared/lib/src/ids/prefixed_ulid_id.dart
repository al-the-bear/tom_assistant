// Shared base for IDs of shape `<prefix>_<26-char-ULID>`.
//
// Four of the five identifier types in Tom Brain share this exact shape:
// NodeId (`n_`), EdgeId (`e_`), TrailId (`t_`), StackEntryId (`se_`). The
// fifth one, ProcedureId, is a separate shape and does not extend this.
//
// Design notes:
//   * `value` carries the *full* string including the prefix. That is what
//     gets written to SQLite, JSONL, and the MCP wire — keeping it as the
//     canonical form means subclasses don't have to rebuild it on every
//     `toString`.
//   * Equality is value-based and type-aware: a NodeId 'n_X' is never equal
//     to a TrailId 't_X', even before the prefix would distinguish them,
//     because we also compare `runtimeType`. Two distinct subclasses with
//     overlapping payloads should never collide.
//   * `compareTo` sorts by full `value`, which means lexicographic order
//     coincides with chronological order within a single ID type. That
//     property matters for SQLite range scans.

import 'ulid.dart';

/// Common surface for ULID-based prefixed identifiers.
///
/// Concrete subclasses bind a fixed [prefix] (e.g. `'n'`, `'e'`, `'t'`,
/// `'se'`) and provide their own `generate` / `fromString` constructors.
abstract base class PrefixedUlidId implements Comparable<PrefixedUlidId> {
  /// The prefix without the trailing underscore separator.
  String get prefix;

  /// Full canonical form: `<prefix>_<26-char-ULID>`.
  final String value;

  /// Subclasses pass in a value that is already known to be well-formed.
  /// Public construction goes through `fromString` or `generate` factories
  /// on the subclass, which call this with a validated payload.
  const PrefixedUlidId.raw(this.value);

  /// The ULID portion, with the prefix and separator stripped.
  String get ulid => value.substring(prefix.length + 1);

  /// The instant encoded in the ULID's timestamp portion.
  DateTime get instant => Ulid.timestampOf(ulid);

  @override
  int compareTo(PrefixedUlidId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PrefixedUlidId &&
          other.runtimeType == runtimeType &&
          other.value == value);

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;
}

/// Internal helper for subclasses to centralise the validation rule.
/// Throws [FormatException] when `value` doesn't match `<prefix>_<ULID>`.
///
/// Exposed only via subclass factories — not part of the public API.
String validatePrefixedUlid(String value, String prefix, String typeName) {
  final expected = '${prefix}_';
  if (!value.startsWith(expected)) {
    throw FormatException(
      '$typeName must start with "$expected"',
      value,
    );
  }
  final payload = value.substring(expected.length);
  if (!Ulid.isValid(payload)) {
    throw FormatException(
      '$typeName payload is not a valid ULID',
      value,
    );
  }
  return value;
}
