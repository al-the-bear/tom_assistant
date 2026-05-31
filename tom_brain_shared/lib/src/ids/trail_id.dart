// TrailId — identifies a thinking-trail recorded as JSONL.
//
// Shape: `t_<26-char-ULID>`. Each invocation of the thinking loop produces
// one trail; the TrailId is the file-system filename (after a `.jsonl`
// suffix) and the foreign key from any memory node that cites the trail.

import 'prefixed_ulid_id.dart';
import 'ulid.dart';

/// Identifier of a thinking trail.
final class TrailId extends PrefixedUlidId {
  static const String _prefix = 't';

  TrailId._(super.value) : super.raw();

  /// Generates a fresh `TrailId`.
  factory TrailId.generate({DateTime? at, List<int>? randomness}) =>
      TrailId._('${_prefix}_${Ulid.generate(at: at, randomness: randomness)}');

  /// Parses a `TrailId` from its canonical string form.
  ///
  /// Throws [FormatException] when `value` does not start with `t_` or its
  /// payload is not a valid ULID.
  factory TrailId.fromString(String value) =>
      TrailId._(validatePrefixedUlid(value, _prefix, 'TrailId'));

  @override
  String get prefix => _prefix;
}
