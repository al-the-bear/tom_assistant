// The API-key marker grammar (memory_session_profiles.md § 3.1) — the pure
// tokeniser that splits a Bearer token into the session/memory *selectors* it
// embeds and the *residual key* that is actually authenticated.
//
// ── Why a separate pure function ─────────────────────────────────────────
//
// memory_session_profiles.md gives session/memory selection through the
// credential itself: a Bearer token may embed up to two markers —
// `session-<sel>` and `memory-<sel>` — that pick a conversation session and a
// memory profile, and whatever is left is the real key. Parsing runs at the
// edge *before* authentication (MSP-3): the markers are stripped first; the
// residual is what `IdentityResolver.resolveBearer` then validates.
//
// This file is that strip step and nothing more. It is pure (no I/O, no
// state), exactly like [parseBearerHeader] and `parseTelegramCommand`, so the
// whole §15 marker table is unit-testable in isolation. The edge wiring —
// `parseBearerHeader` → [parseApiKeyMarkers] → authenticate residual → apply
// prefixes → stamp `Access` — is plan step 5; prefix resolution + config is
// step 3. Here we only produce `{ residualKey, sessionSelector?,
// memorySelector? }`.
//
// ── The grammar (§ 3.1, the D-1 recommended default) ─────────────────────
//
//   1. Split the token on `_` into segments; drop empty segments (this absorbs
//      leading / trailing and doubled underscores — the request's "potentially
//      with leading/trailing underscores").
//   2. A segment matching `^session-(.+)$` is the session marker (value =
//      group 1); a segment matching `^memory-(.+)$` is the memory marker.
//   3. At most one of each — a second occurrence of either is a duplicate
//      error ([ApiKeyMarkerFailureReason.duplicateMarker], wire code
//      `marker.duplicate`, surfaced as `400 invalid_api_key` at the edge,
//      § 13).
//   4. All remaining (non-marker) segments, rejoined with `_` in original
//      order, form the residual key.
//
// Markers may appear before, after, or interleaved with the key segments.
// Matching is case-sensitive on the `session-`/`memory-` literal; values are
// preserved verbatim. Because a marker value is one underscore-delimited
// segment, selector values are `_`-free by construction (D-1); a real key may
// contain `_` (it survives as rejoined residual segments).

/// The result of [parseApiKeyMarkers]: the markers stripped from a Bearer
/// token plus the residual key left for authentication.
///
/// [residualKey] is the token with both markers removed (the segments rejoined
/// with `_`); it may be empty when the token carried only markers — the edge
/// then treats the request as keyless and substitutes the well-known `no-key`
/// credential (§ 3.2 / § 6, plan step 4). [sessionSelector] / [memorySelector]
/// are the verbatim marker values, or `null` when the corresponding marker was
/// absent (the edge defaults an absent selector to `default`, § 3.2).
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

  /// Builds a marker result.
  const ApiKeyMarkers({
    required this.residualKey,
    required this.sessionSelector,
    required this.memorySelector,
  });

  @override
  String toString() => 'ApiKeyMarkers(residualKey: "$residualKey", '
      'session: $sessionSelector, memory: $memorySelector)';
}

/// Categories of API-key marker parse failure.
///
/// The set is closed by design (mirrors [BearerAuthFailureReason] and the
/// no-backwards-compatibility discipline, AC-12): adding a category is a
/// version bump, not a silent extension. § 3.1 defines exactly one — a
/// repeated marker.
enum ApiKeyMarkerFailureReason {
  /// A second `session-` or `memory-` marker appeared in one token. At most
  /// one of each is allowed (§ 3.1 step 4).
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

/// Parses the session/memory markers out of a Bearer [token] (§ 3.1).
///
/// Returns the [ApiKeyMarkers] — the residual key plus the (optional) session
/// and memory selectors. Pure: no I/O, no state.
///
/// Throws [ApiKeyMarkerException] ([ApiKeyMarkerFailureReason.duplicateMarker])
/// when a second `session-` or `memory-` marker appears in the same token.
ApiKeyMarkers parseApiKeyMarkers(String token) {
  String? sessionSelector;
  String? memorySelector;
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

    residualSegments.add(segment);
  }

  return ApiKeyMarkers(
    residualKey: residualSegments.join('_'),
    sessionSelector: sessionSelector,
    memorySelector: memorySelector,
  );
}
