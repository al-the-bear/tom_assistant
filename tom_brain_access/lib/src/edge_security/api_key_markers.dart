// The API-key marker grammar (memory_session_profiles.md § 3.1) — the pure
// tokeniser that splits a Bearer token into the session/memory *selectors* it
// embeds and the *residual key* that is actually authenticated.
//
// ── Why a separate pure function ─────────────────────────────────────────
//
// memory_session_profiles.md gives session/memory selection through the
// credential itself: a Bearer token may embed up to three markers —
// `session-<sel>`, `memory-<sel>`, and `profile-<sel>` (the third axis,
// session_configuration.md § 3) — that pick a conversation session, a memory
// profile, and a behaviour profile, and whatever is left is the real key.
// Parsing runs at the edge *before* authentication (MSP-3): the markers are
// stripped first; the residual is what `IdentityResolver.resolveBearer` then
// validates.
//
// This file is that strip step and nothing more. It is pure (no I/O, no
// state), exactly like [parseBearerHeader] and `parseTelegramCommand`, so the
// whole §15 marker table is unit-testable in isolation. The edge wiring —
// `parseBearerHeader` → [parseApiKeyMarkers] → authenticate residual → apply
// prefixes → resolve profile → stamp `Access` — is plan step 5; prefix
// resolution + config is step 3. Here we only produce `{ residualKey,
// sessionSelector?, memorySelector?, profileSelector? }`.
//
// ── The grammar (§ 3.1, the D-1 recommended default) ─────────────────────
//
//   1. Split the token on `_` into segments; drop empty segments (this absorbs
//      leading / trailing and doubled underscores — the request's "potentially
//      with leading/trailing underscores").
//   2. A segment matching `^session-(.+)$` is the session marker (value =
//      group 1); a segment matching `^memory-(.+)$` is the memory marker; a
//      segment matching `^profile-(.+)$` is the profile marker.
//   3. At most one of each — a second occurrence of any is a duplicate
//      error ([ApiKeyMarkerFailureReason.duplicateMarker], wire code
//      `marker.duplicate`, surfaced as `400 invalid_api_key` at the edge,
//      § 13).
//   4. All remaining (non-marker) segments, rejoined with `_` in original
//      order, form the residual key.
//
// Markers may appear before, after, or interleaved with the key segments.
// Matching is case-sensitive on the `session-`/`memory-`/`profile-` literal;
// values are preserved verbatim. Because a marker value is one
// underscore-delimited segment, selector values are `_`-free by construction
// (D-1); a real key may contain `_` (it survives as rejoined residual
// segments).

/// The reserved credential value for keyless access (§ 6, MSP-2).
///
/// A request whose residual key is empty — the Bearer token carried only
/// markers, or was effectively empty (§ 3.2) — is treated as **keyless** and
/// authenticated under this well-known credential. It is an *ordinary*
/// `apiKeys:` entry: keyless access is admitted only while a `no-key` entry is
/// configured (so authenticating it succeeds), and removing that entry
/// re-closes keyless access with no other change (MSP-2). Authentication is
/// never bypassed — "keyless" is a *configured* key, not an absence of one.
const String noKeyCredential = 'no-key';

/// The result of [parseApiKeyMarkers]: the markers stripped from a Bearer
/// token plus the residual key left for authentication.
///
/// [residualKey] is the token with all markers removed (the segments rejoined
/// with `_`); it may be empty when the token carried only markers — the edge
/// then treats the request as keyless and substitutes the well-known `no-key`
/// credential (§ 3.2 / § 6, plan step 4). [sessionSelector] / [memorySelector]
/// / [profileSelector] are the verbatim marker values, or `null` when the
/// corresponding marker was absent (the edge defaults an absent selector to
/// `default`, § 3.2).
final class ApiKeyMarkers {
  /// The token with the `session-`/`memory-` markers stripped — the credential
  /// that is actually authenticated. May be `''` (markers-only / empty token).
  final String residualKey;

  /// The `session-<value>` marker's value, or `null` if no session marker was
  /// present. Never empty when non-null (the grammar requires `(.+)`).
  final String? sessionSelector;

  /// The `memory-<value>` marker's value, or `null` if no memory marker was
  /// present. Never empty when non-null (the grammar requires `(.+)`).
  final String? memorySelector;

  /// The `profile-<value>` marker's value (the third selection axis,
  /// session_configuration.md § 3), or `null` if no profile marker was present.
  /// Never empty when non-null (the grammar requires `(.+)`). The edge resolves
  /// an absent selector to the configured Telegram default / the built-in
  /// `default` profile (plan step 5).
  final String? profileSelector;

  /// Builds a marker result.
  const ApiKeyMarkers({
    required this.residualKey,
    required this.sessionSelector,
    required this.memorySelector,
    required this.profileSelector,
  });

  /// Whether the token carried no real key — [residualKey] is empty, so the
  /// request is keyless and resolves to [noKeyCredential] (§ 3.2 / § 6).
  bool get isKeyless => residualKey.isEmpty;

  /// The credential the edge actually authenticates (§ 3.2): [residualKey]
  /// when the token carried a real key, else the well-known [noKeyCredential]
  /// for the keyless case. The literal token `no-key` already equals
  /// [noKeyCredential], so it maps to itself (with or without markers, e.g.
  /// `session-demo_no-key_memory-demo`).
  ///
  /// `IdentityResolver.resolveBearer` validates this value: an empty residual
  /// is admitted only when a `no-key` `apiKeys:` entry is configured, and is
  /// rejected (`401`) otherwise (MSP-2). The substitution never fabricates
  /// identity — it only names the credential to authenticate.
  String get effectiveResidualKey =>
      residualKey.isEmpty ? noKeyCredential : residualKey;

  @override
  String toString() => 'ApiKeyMarkers(residualKey: "$residualKey", '
      'session: $sessionSelector, memory: $memorySelector, '
      'profile: $profileSelector)';
}

/// Categories of API-key marker parse failure.
///
/// The set is closed by design (mirrors [BearerAuthFailureReason] and the
/// no-backwards-compatibility discipline, AC-12): adding a category is a
/// version bump, not a silent extension. § 3.1 defines exactly one — a
/// repeated marker.
enum ApiKeyMarkerFailureReason {
  /// A second `session-`, `memory-`, or `profile-` marker appeared in one
  /// token. At most one of each is allowed (§ 3.1 step 4).
  duplicateMarker,
}

/// Raised when a Bearer token's embedded markers cannot be parsed.
///
/// Carries a stable [reason] tag and the [code] the edge surfaces as the
/// OpenAI `invalid_api_key` error code (§ 13). The token string itself is
/// never put in the [message] — a near-miss credential must not leak.
class ApiKeyMarkerException implements Exception {
  /// Stable enum-like tag for the failure category.
  final ApiKeyMarkerFailureReason reason;

  /// Human-readable diagnostic, intended for server-side logs only.
  final String message;

  /// Builds a marker parse failure.
  const ApiKeyMarkerException(this.reason, this.message);

  /// The stable wire code the edge maps onto the OpenAI `invalid_api_key`
  /// error envelope (§ 13). One per [reason]; switch is exhaustive so a new
  /// reason forces a code decision.
  String get code => switch (reason) {
        ApiKeyMarkerFailureReason.duplicateMarker => 'marker.duplicate',
      };

  @override
  String toString() => 'ApiKeyMarkerException(${reason.name}): $message';
}

/// Matches a `session-<value>` segment; group 1 is the verbatim selector.
final RegExp _sessionMarker = RegExp(r'^session-(.+)$');

/// Matches a `memory-<value>` segment; group 1 is the verbatim selector.
final RegExp _memoryMarker = RegExp(r'^memory-(.+)$');

/// Matches a `profile-<value>` segment; group 1 is the verbatim selector
/// (the third selection axis, session_configuration.md § 3).
final RegExp _profileMarker = RegExp(r'^profile-(.+)$');

/// Parses the session/memory/profile markers out of a Bearer [token] (§ 3.1).
///
/// Returns the [ApiKeyMarkers] — the residual key plus the (optional) session,
/// memory and profile selectors. Pure: no I/O, no state.
///
/// Throws [ApiKeyMarkerException] ([ApiKeyMarkerFailureReason.duplicateMarker])
/// when a second `session-`, `memory-`, or `profile-` marker appears in the
/// same token.
ApiKeyMarkers parseApiKeyMarkers(String token) {
  String? sessionSelector;
  String? memorySelector;
  String? profileSelector;
  final residualSegments = <String>[];

  for (final segment in token.split('_')) {
    if (segment.isEmpty) continue; // absorb leading/trailing/doubled `_`

    final sessionMatch = _sessionMarker.firstMatch(segment);
    if (sessionMatch != null) {
      if (sessionSelector != null) {
        throw const ApiKeyMarkerException(
          ApiKeyMarkerFailureReason.duplicateMarker,
          'Token carries more than one session- marker.',
        );
      }
      sessionSelector = sessionMatch.group(1);
      continue;
    }

    final memoryMatch = _memoryMarker.firstMatch(segment);
    if (memoryMatch != null) {
      if (memorySelector != null) {
        throw const ApiKeyMarkerException(
          ApiKeyMarkerFailureReason.duplicateMarker,
          'Token carries more than one memory- marker.',
        );
      }
      memorySelector = memoryMatch.group(1);
      continue;
    }

    final profileMatch = _profileMarker.firstMatch(segment);
    if (profileMatch != null) {
      if (profileSelector != null) {
        throw const ApiKeyMarkerException(
          ApiKeyMarkerFailureReason.duplicateMarker,
          'Token carries more than one profile- marker.',
        );
      }
      profileSelector = profileMatch.group(1);
      continue;
    }

    residualSegments.add(segment);
  }

  return ApiKeyMarkers(
    residualKey: residualSegments.join('_'),
    sessionSelector: sessionSelector,
    memorySelector: memorySelector,
    profileSelector: profileSelector,
  );
}
