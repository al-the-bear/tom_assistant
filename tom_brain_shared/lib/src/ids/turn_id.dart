// TurnId — correlates every record produced while serving one inbound request
// (logging-spec §3).
//
// Shape: `turn_<26-char-ULID>`. Minted once at the access edge the instant an
// inbound request is admitted, then threaded through the whole turn — Access →
// dispatcher → procedure engine → substrate call — so a log line / trail
// filename reads `turn_<ULID>` and `turnId` + `callSeq` uniquely name any LLM
// call across the system.

import 'prefixed_ulid_id.dart';
import 'ulid.dart';

/// Identifier of a single turn — the unit of work that serves one inbound
/// request from admission to final answer.
final class TurnId extends PrefixedUlidId {
  static const String _prefix = 'turn';

  TurnId._(super.value) : super.raw();

  /// Generates a fresh `TurnId`.
  factory TurnId.generate({DateTime? at, List<int>? randomness}) =>
      TurnId._('${_prefix}_${Ulid.generate(at: at, randomness: randomness)}');

  /// Parses a `TurnId` from its canonical string form.
  ///
  /// Throws [FormatException] when `value` does not start with `turn_` or its
  /// payload is not a valid ULID.
  factory TurnId.fromString(String value) =>
      TurnId._(validatePrefixedUlid(value, _prefix, 'TurnId'));

  @override
  String get prefix => _prefix;
}
