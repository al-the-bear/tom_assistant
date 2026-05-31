// StackEntryId — identifies a single entry inside one of the bootstrap
// stacks (questions_open, automation_ideas, interests, inflight,
// recent_runs, restructure_backlog).
//
// Shape: `se_<26-char-ULID>`. The two-letter prefix is intentional: a
// single-letter `s_` would collide too easily with any future "session" or
// "snapshot" identifier.

import 'prefixed_ulid_id.dart';
import 'ulid.dart';

/// Identifier of an entry within a bootstrap stack.
final class StackEntryId extends PrefixedUlidId {
  static const String _prefix = 'se';

  StackEntryId._(super.value) : super.raw();

  /// Generates a fresh `StackEntryId`.
  factory StackEntryId.generate({DateTime? at, List<int>? randomness}) =>
      StackEntryId._(
        '${_prefix}_${Ulid.generate(at: at, randomness: randomness)}',
      );

  /// Parses a `StackEntryId` from its canonical string form.
  ///
  /// Throws [FormatException] when `value` does not start with `se_` or
  /// its payload is not a valid ULID. In particular, `s_<ulid>` is
  /// rejected: the prefix is `se`, not `s`.
  factory StackEntryId.fromString(String value) =>
      StackEntryId._(validatePrefixedUlid(value, _prefix, 'StackEntryId'));

  @override
  String get prefix => _prefix;
}
