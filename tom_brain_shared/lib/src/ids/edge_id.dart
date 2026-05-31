// EdgeId — identifies an edge in the memory graph.
//
// Shape: `e_<26-char-ULID>`. Every typed relation from the closed 12-edge
// alphabet (supports, contradicts, refines, …) is materialised as a graph
// row with an EdgeId primary key.

import 'prefixed_ulid_id.dart';
import 'ulid.dart';

/// Identifier of an edge in the memory graph.
final class EdgeId extends PrefixedUlidId {
  static const String _prefix = 'e';

  EdgeId._(super.value) : super.raw();

  /// Generates a fresh `EdgeId`.
  factory EdgeId.generate({DateTime? at, List<int>? randomness}) =>
      EdgeId._('${_prefix}_${Ulid.generate(at: at, randomness: randomness)}');

  /// Parses an `EdgeId` from its canonical string form.
  ///
  /// Throws [FormatException] when `value` does not start with `e_` or its
  /// payload is not a valid ULID.
  factory EdgeId.fromString(String value) =>
      EdgeId._(validatePrefixedUlid(value, _prefix, 'EdgeId'));

  @override
  String get prefix => _prefix;
}
