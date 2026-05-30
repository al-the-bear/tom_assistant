// NodeId — identifies a vertex in the memory graph.
//
// Shape: `n_<26-char-ULID>`. Every Event, Claim, Concept, Conclusion,
// Question, Pattern, Contradiction and Source node carries one of these as
// its primary key.

import 'prefixed_ulid_id.dart';
import 'ulid.dart';

/// Identifier of a node in the memory graph.
final class NodeId extends PrefixedUlidId {
  static const String _prefix = 'n';

  NodeId._(super.value) : super.raw();

  /// Generates a fresh `NodeId` with a freshly minted ULID.
  ///
  /// `at` overrides the timestamp source — production code leaves it
  /// `null`; tests use it to make ordering deterministic.
  factory NodeId.generate({DateTime? at, List<int>? randomness}) =>
      NodeId._('${_prefix}_${Ulid.generate(at: at, randomness: randomness)}');

  /// Parses a `NodeId` from its canonical string form.
  ///
  /// Throws [FormatException] when `value` does not start with `n_` or its
  /// payload is not a valid ULID. The check is strict by design: silently
  /// coercing the wrong shape would let an EdgeId leak into a NodeId column
  /// and cost us a day of debugging downstream.
  factory NodeId.fromString(String value) =>
      NodeId._(validatePrefixedUlid(value, _prefix, 'NodeId'));

  @override
  String get prefix => _prefix;
}
