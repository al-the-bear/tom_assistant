// Profile resolution seam (session_configuration.md § 4.2 / § 4.3, plan step 5).
//
// ── Why a function seam, not a `ProfileRegistry` import ───────────────────
//
// The edge resolves a token's `profile-<name>` marker (parsed by
// `parseApiKeyMarkers`, step 4) to a [ResolvedProfile] it stamps on `Access`.
// The resolution itself — parsing `profiles:`, clamping budgets, validating
// roles — lives in `ProfileRegistry`, which is owned by `tom_brain_run`
// (SCP-6). `tom_brain_access` must NOT import `tom_brain_run`: the dependency
// arrow points the other way (the run-side provisioner *assembles* the access
// layer). So the edge holds only a [ProfileResolver] function, exactly like the
// `KindHintEmbedder` / `KindHintClassifier` substrate/memory seams (E.33/E.16).
// The run-side provisioner supplies `(sel) => registry.resolve(sel ?? 'default',
// …ceilings)` and translates run's `UnknownProfileException` into the
// access-local [ProfileResolutionException] below. [ResolvedProfile] itself is
// in `tom_brain_shared`, so the signature is dependency-legal.
//
// When no resolver is wired (the pre-feature default, profiles off) the edge
// resolves every request to `const ResolvedProfile.cognitiveDefault()` — the
// SC-5 byte-compatible default, so `Access.profile` keeps today's behaviour
// with no wiring (SCP-18).

import 'package:tom_brain_shared/tom_brain_shared.dart' show ResolvedProfile;

/// Resolves an optional `profile-<name>` selector to its boot-resolved
/// [ResolvedProfile] (the seam the edge calls; the run-side provisioner
/// implements it over the live `ProfileRegistry`, SCP-18).
///
/// A `null` selector means the request carried no `profile-` marker — the
/// implementation resolves the built-in `default` profile. An unknown selector
/// must throw [ProfileResolutionException] (the run side translates its
/// `UnknownProfileException`), which the edge maps to `400` /
/// `profile.unknown`.
typedef ProfileResolver = ResolvedProfile Function(String? profileSelector);

/// Raised when a token's `profile-<name>` marker names a profile that is not
/// configured (the access-local mirror of run's `UnknownProfileException`).
///
/// Carries the non-secret [profileName] for the operator-facing message; the
/// credential's residual key is never put in [message] (a near-miss secret must
/// not leak — same discipline as [ApiKeyMarkerException]). The edge maps this to
/// the OpenAI `400` / `invalid_request_error` envelope with [code]
/// `profile.unknown`.
class ProfileResolutionException implements Exception {
  /// The unknown profile selector the credential named (non-secret).
  final String profileName;

  /// Human-readable diagnostic, intended for server-side logs / the error
  /// envelope. Never carries the residual credential.
  final String message;

  /// Builds a profile-resolution failure for the named profile.
  const ProfileResolutionException(this.profileName, this.message);

  /// The stable wire code the edge maps onto the OpenAI error envelope
  /// (plan step 5 done-when: `profile.unknown`).
  String get code => 'profile.unknown';

  @override
  String toString() => 'ProfileResolutionException($profileName): $message';
}
