// A hand-rolled RFC 4122 version-4 UUID generator (memory_session_profiles.md
// § 7, decision D-6).
//
// ── Why not `package:uuid` ───────────────────────────────────────────
//
// The access package declares exactly six runtime dependencies plus
// shelf/yaml; `test/dependency_surface_test.dart` fails CI on any undeclared
// *direct* dependency. `uuid` is only a *transitive* dependency (it arrives via
// `tom_basics`), so importing it here would be an undeclared direct dependency.
// Rather than widen the surface for one value, `/create_api_key` mints its key
// with this 16-line generator over `dart:math`'s cryptographically-secure RNG.
//
// ── Why a v4 UUID is the right key shape (D-6) ───────────────────────
//
// A v4 UUID is built from hex digits and `-` only — it carries no `_`. That
// matters because the bearer-token marker tokeniser (§ 3.1, `api_key_markers.dart`)
// splits a token on `_` to lift out the `session-` / `memory-` selectors; a key
// with no `_` survives that split untouched as a clean residual, so a generated
// key authenticates exactly as minted. (A `TimestampId` is *not* a UUID and is
// not `_`-free, which is why it is not used here.)

import 'dart:math';

/// Generates a fresh RFC 4122 version-4 UUID using a cryptographically-secure
/// random source.
///
/// The returned string is the canonical 36-character form
/// `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` — lower-case hex with the version
/// nibble fixed to `4` and the variant nibble to one of `8`/`9`/`a`/`b`. It
/// contains no `_`, so it passes through the §3.1 marker tokeniser as a clean
/// residual key (D-6).
String uuidV4() {
  final Random rng = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));

  // Version 4 (random) in the high nibble of byte 6; RFC 4122 variant (10xx) in
  // the high bits of byte 8.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < 16; i++) {
    buffer.write(hex(bytes[i]));
    if (i == 3 || i == 5 || i == 7 || i == 9) {
      buffer.write('-');
    }
  }
  return buffer.toString();
}
