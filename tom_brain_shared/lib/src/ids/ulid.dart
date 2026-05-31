// Pure-Dart ULID (Universally Unique Lexicographically Sortable Identifier).
//
// Format: 26 characters of Crockford base32.
//   * First 10 chars  : 48-bit unsigned ms-since-epoch timestamp.
//   * Last  16 chars  : 80 bits of randomness from `Random.secure()`.
//
// We deliberately keep this self-contained instead of pulling a `ulid`
// package. `tom_brain_shared` is allowed exactly one runtime dependency
// (`tom_basics`); a hundred lines of Crockford encoding is cheaper than
// arguing about that contract.
//
// Why ULID over UUIDv4: ULIDs sort by time when stored as strings, which
// matters because every memory-graph identifier ends up as a primary key in
// SQLite. Lexicographic == chronological gives us index locality for free.

import 'dart:math';

/// Pure-Dart ULID generator and validator.
///
/// All methods are static; this type holds no state. The single piece of
/// shared mutable state is a `Random.secure()` instance, lazily allocated.
abstract final class Ulid {
  /// Crockford base32 alphabet. No `I`, `L`, `O`, `U` — by design.
  static const String alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// Number of timestamp chars (48 bits / 5 bits-per-char = 9.6 → 10).
  static const int timestampLength = 10;

  /// Number of randomness chars (80 bits / 5 = 16).
  static const int randomnessLength = 16;

  /// Total ULID string length.
  static const int totalLength = timestampLength + randomnessLength;

  /// Maximum representable timestamp: 2^48 - 1 ms ≈ year 10895.
  static const int maxTimestampMs = 0xFFFFFFFFFFFF;

  static final Random _random = Random.secure();

  /// Generates a fresh ULID. When `at` is supplied it is used as the
  /// timestamp source; otherwise `DateTime.now()` is used.
  ///
  /// The optional `randomness` parameter exists for tests that need
  /// determinism. Production code never passes it.
  static String generate({DateTime? at, List<int>? randomness}) {
    final ts = (at ?? DateTime.now()).millisecondsSinceEpoch;
    if (ts < 0 || ts > maxTimestampMs) {
      throw ArgumentError.value(
        at,
        'at',
        'timestamp out of ULID range (0..2^48-1 ms)',
      );
    }
    return _encodeTimestamp(ts) + _encodeRandomness(randomness);
  }

  /// True when `s` is a syntactically valid ULID string (length 26,
  /// uppercase Crockford alphabet, no separators).
  static bool isValid(String s) {
    if (s.length != totalLength) return false;
    for (var i = 0; i < s.length; i++) {
      if (!alphabet.contains(s[i])) return false;
    }
    return true;
  }

  /// Recovers the millisecond timestamp encoded in a ULID.
  ///
  /// Throws [FormatException] when `ulid` is not a valid ULID string.
  static DateTime timestampOf(String ulid) {
    if (!isValid(ulid)) {
      throw FormatException('not a valid ULID string', ulid);
    }
    var ts = 0;
    for (var i = 0; i < timestampLength; i++) {
      ts = (ts << 5) | alphabet.indexOf(ulid[i]);
    }
    // Return UTC: ULIDs encode an absolute instant. Returning a
    // local-zone DateTime here would surprise tests that pass UTC in.
    return DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true);
  }

  static String _encodeTimestamp(int ts) {
    final buf = List<String>.filled(timestampLength, '0');
    var n = ts;
    for (var i = timestampLength - 1; i >= 0; i--) {
      buf[i] = alphabet[n & 0x1F];
      n >>= 5;
    }
    return buf.join();
  }

  static String _encodeRandomness(List<int>? supplied) {
    final buf = List<String>.filled(randomnessLength, '0');
    if (supplied != null) {
      if (supplied.length != randomnessLength) {
        throw ArgumentError.value(
          supplied,
          'randomness',
          'must be exactly $randomnessLength entries of [0..31]',
        );
      }
      for (var i = 0; i < randomnessLength; i++) {
        final v = supplied[i];
        if (v < 0 || v > 31) {
          throw ArgumentError.value(
            supplied,
            'randomness',
            'entry $i = $v out of range [0..31]',
          );
        }
        buf[i] = alphabet[v];
      }
    } else {
      for (var i = 0; i < randomnessLength; i++) {
        buf[i] = alphabet[_random.nextInt(32)];
      }
    }
    return buf.join();
  }
}
