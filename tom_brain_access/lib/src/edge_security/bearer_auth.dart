// E.28 — Bearer-token authentication for the OpenAI HTTP edge.
//
// The plan line for E.28 reads "Implement bearer-token auth via
// `TomBearerAuthentication`." This is the first of the four edge-security
// checks (proto spec § 8): it runs *before* an `Access` is constructed
// (AC-3, AC-4) and, on the OpenAI channel, a failure surfaces as a `401`
// JSON envelope and the request never becomes an `Access`.
//
// Relationship to the rest of the edge (proto spec § 7.1 / § 8):
//
//   * This step is the **OpenAI** auth check. The Telegram auth check is a
//     user-id whitelist (E.22, in the Telegram adapter) — a different
//     mechanism, so it is not part of this file.
//   * Auth (E.28) validates the *credential*; the `IdentityResolver`
//     (E.24) maps the validated credential to a `ResolvedIdentity`. The two
//     are deliberately separate: this file answers "is this a real bearer
//     credential?", the resolver answers "whose is it?". Boot composition
//     (E.41+) feeds both from one credential config so there is a single
//     source of truth for the accepted-token set; the seam between the
//     authenticated principal and the resolver's lookup is a boot decision
//     (logged Q-E.28.1), not an E.28 one.
//
// Precedent. This mirrors the Phase-A A.76 bearer-auth contract
// (`tom_brain_memory/lib/src/mcp_server/bearer_auth.dart`) deliberately:
// same `BearerTokenAuthenticator` interface, same `BearerAuthFailure` /
// `BearerAuthFailureReason` taxonomy, same `Jwt…` / `Static…`
// implementations wired through `TomBearerAuthentication`. A.76 ships those
// types behind `tom_brain_memory`'s `lib/src/`, and the access prototype
// does not (and must not) depend on `tom_brain_memory` (the edge never
// reaches past the dispatcher), so the types are re-implemented here rather
// than imported. The phase-end reuse-extraction pass (E.52) is the place to
// decide whether this taxonomy should be lifted into `tom_brain_shared` and
// consumed by both — see Q-E.28.2.
//
// What differs from A.76: the credential channel. A.76 carries the token in
// the MCP `initialize` request's `_meta` map (stdio / UNIX-socket transports
// expose no `Authorization` header); the OpenAI HTTP edge carries it in the
// standard `Authorization: Bearer <token>` request header. So this file adds
// [parseBearerHeader] (the HTTP-header equivalent of A.76's `_meta` key) and
// the `401` mapping ([bearerAuthHttpStatus]); the authenticator contract is
// otherwise identical.
//
// Scope discipline (per the strict per-substep log; mirrors E.24 – E.27).
// E.28 is the bearer-credential authenticator + the HTTP-header parser only.
// It does NOT:
//
//   * map the failure onto a shelf `Response` — the OpenAI adapter owns the
//     wire shape (its `_errorResponse` helper builds the envelope); this
//     file exposes only the stable failure taxonomy and the documented
//     `401` status constant the adapter reads. Channel-blind, exactly like
//     E.24's `IdentityResolutionException`.
//   * wire into the adapter route flow or boot — that is E.41+ composition.
//   * resolve identity (E.24), sessions (E.25), or personas (E.26).
//   * implement rate limiting (E.29), quota (E.30), or the anchor pre-check
//     (E.31) — the other three edge-security checks.

import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomBearerAuthentication, TomClientJwtToken, TomPrincipal;

/// The HTTP request header that carries the bearer credential on the
/// OpenAI channel. Lower-cased because shelf normalises header names to
/// lower-case; callers reading from a shelf `Request.headers` map should
/// look this key up directly.
const String authorizationHeaderName = 'authorization';

/// The HTTP request header every gateway edge reads to associate an inbound
/// request with a kept session (proto spec § 5.2, hub § 22.9). Lower-cased
/// because shelf normalises header names to lower-case; the edges look this
/// key up directly in the `Request.headers` map and thread the value into
/// `toInboundRequest(sessionId:)`. `null` when the client sent none — the
/// request is then routed to the default session.
const String tomSessionHeaderName = 'x-tom-session';

/// The credential scheme the OpenAI channel uses. Compared
/// case-insensitively against the first token of the `Authorization`
/// header (RFC 7235 auth-schemes are case-insensitive).
const String bearerScheme = 'Bearer';

/// The lower-cased form of [bearerScheme], pre-folded once so the header
/// comparison ([parseBearerHeader]) is a direct equality rather than a
/// `.toLowerCase()` on every request.
const String _bearerSchemeLower = 'bearer';

/// The HTTP status every [BearerAuthFailure] maps to on the OpenAI channel
/// (proto spec § 8: "OpenAI failure: `401` JSON"). Exposed as a single
/// constant so the OpenAI adapter (E.41+) has one source of truth for the
/// status rather than hard-coding `401` at the call site.
const int bearerAuthHttpStatus = 401;

/// Validates a bearer token presented on an inbound request.
///
/// Implementations are responsible for **authentication only** —
/// converting a token string into a [TomPrincipal] or rejecting it.
/// Authorisation (role / entitlement checks against the principal) is not
/// an edge concern in the prototype; the dispatcher reads only
/// `identity.principalId` (AC-7).
///
/// Implementations must be synchronous: edge security runs on the inbound
/// hot path, before an `Access` exists, and must add no network / LLM call.
abstract interface class BearerTokenAuthenticator {
  /// Validates [token] and returns the resulting principal.
  ///
  /// Throws [BearerAuthFailure] if [token] is missing, malformed, or
  /// otherwise rejected.
  TomPrincipal authenticate(String token);
}

/// Raised when a bearer credential cannot be accepted.
///
/// Carries a stable [reason] tag — useful for telemetry and tests — plus a
/// human-readable [message]. On the OpenAI channel the adapter translates
/// every instance into a [bearerAuthHttpStatus] (`401`) error envelope; the
/// underlying [message] is **not** leaked to the client unmodified, because
/// token-introspection error details can be a side-channel for
/// token-guessing attacks. The token string itself is never put in the
/// message.
class BearerAuthFailure implements Exception {
  /// Stable enum-like tag for the failure category.
  final BearerAuthFailureReason reason;

  /// Human-readable diagnostic, intended for server-side logs only.
  final String message;

  const BearerAuthFailure(this.reason, this.message);

  @override
  String toString() => 'BearerAuthFailure(${reason.name}): $message';
}

/// Categories of bearer-token authentication failure.
///
/// The set is closed by design — per AC-12 (no backwards compatibility),
/// adding a new category is a version bump, not a silent extension.
enum BearerAuthFailureReason {
  /// No `Authorization` header was present (or it carried no token) when one
  /// was required.
  missing,

  /// The header / token was present but could not be parsed (wrong scheme,
  /// malformed JWT, unknown format, …).
  malformed,

  /// The token parsed but failed authentication (guest principal, expired,
  /// unknown subject, …).
  rejected,
}

/// Parses the bearer token out of an `Authorization` request header.
///
/// Accepts the standard `Authorization: Bearer <token>` shape. The scheme
/// is matched case-insensitively (RFC 7235). Returns the raw token string.
///
/// Throws [BearerAuthFailure]:
///   * [BearerAuthFailureReason.missing] when [authorizationHeader] is null,
///     blank, or the `Bearer` scheme carries no token after it.
///   * [BearerAuthFailureReason.malformed] when the header is present but is
///     not a single `Bearer <token>` pair (wrong scheme, extra parts).
///
/// The header value is never echoed into the failure message — a malformed
/// `Authorization` header can itself contain a near-miss token.
String parseBearerHeader(String? authorizationHeader) {
  final header = authorizationHeader?.trim() ?? '';
  if (header.isEmpty) {
    throw const BearerAuthFailure(
      BearerAuthFailureReason.missing,
      'No Authorization header present.',
    );
  }
  final parts = header.split(RegExp(r'\s+'));
  if (parts.length != 2) {
    throw const BearerAuthFailure(
      BearerAuthFailureReason.malformed,
      'Authorization header is not a single "Bearer <token>" pair.',
    );
  }
  if (parts[0].toLowerCase() != _bearerSchemeLower) {
    throw const BearerAuthFailure(
      BearerAuthFailureReason.malformed,
      'Authorization header does not use the Bearer scheme.',
    );
  }
  final token = parts[1];
  if (token.isEmpty) {
    throw const BearerAuthFailure(
      BearerAuthFailureReason.missing,
      'Bearer scheme carries no token.',
    );
  }
  return token;
}

/// Convenience: parse an `Authorization` header and authenticate it in one
/// call.
///
/// Equivalent to `authenticator.authenticate(parseBearerHeader(header))`,
/// surfacing the same [BearerAuthFailure] taxonomy for both the parse and
/// the authentication step. This is the single entry point the OpenAI
/// adapter (E.41+) calls per request.
TomPrincipal authenticateBearerHeader(
  BearerTokenAuthenticator authenticator,
  String? authorizationHeader,
) {
  final token = parseBearerHeader(authorizationHeader);
  return authenticator.authenticate(token);
}

/// Runs [action], collapsing *any* thrown error into a single
/// [BearerAuthFailureReason.malformed] failure tagged with [context].
///
/// The two JWT steps ([TomClientJwtToken] parsing and principal conversion)
/// share this collapse: a token-introspection error must never ride into the
/// client-facing failure path. Only the error's **kind**
/// (`error.runtimeType`) is recorded, never its `toString()` — if the
/// underlying decoder ever interpolated a token fragment into its exception
/// text, `toString()` would leak it (G.3.4); the runtime type cannot.
T _catchAsMalformed<T>(T Function() action, String context) {
  try {
    return action();
  } catch (error) {
    throw BearerAuthFailure(
      BearerAuthFailureReason.malformed,
      '$context (${error.runtimeType}).',
    );
  }
}

/// JWT-based bearer authenticator wiring
/// `TomBearerAuthentication.convertTokenPayloadToPrincipal`.
///
/// This is the canonical implementation the plan calls for. The token is
/// parsed as a [TomClientJwtToken] without secret-data decryption — the edge
/// only cares whether the token resolves to a non-guest principal.
/// Decryption of secret-data (roles / entitlements) is out of scope at the
/// edge (the dispatcher reads only `principalId`).
class JwtBearerTokenAuthenticator implements BearerTokenAuthenticator {
  const JwtBearerTokenAuthenticator();

  @override
  TomPrincipal authenticate(String token) {
    if (token.isEmpty) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.missing,
        'Empty bearer token.',
      );
    }

    final parsed = _catchAsMalformed(
      () => TomClientJwtToken(token, decrypt: false),
      'Bearer token failed to parse as JWT',
    );

    if (parsed.payload == null) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.malformed,
        'Bearer JWT carries no payload.',
      );
    }

    final principal = _catchAsMalformed(
      () => TomBearerAuthentication.convertTokenPayloadToPrincipal(parsed),
      'Bearer JWT payload could not be converted to a principal',
    );

    if (!principal.authenticated) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.rejected,
        'Bearer JWT resolves to a guest / non-authenticated principal.',
      );
    }

    return principal;
  }
}

/// Static shared-secret authenticator.
///
/// Maps a closed set of token strings to pre-built principals. This is the
/// prototype's default — the OpenAI tokens are opaque shared secrets
/// configured at boot (the same set the [parseBearerHeader] output is keyed
/// against), not signed JWTs. The [JwtBearerTokenAuthenticator] is the
/// upgrade path when a deployment issues real JWTs.
///
/// Unknown tokens raise [BearerAuthFailureReason.rejected]; empty tokens
/// raise [BearerAuthFailureReason.missing]. The token string itself never
/// appears in the failure message.
class StaticBearerTokenAuthenticator implements BearerTokenAuthenticator {
  /// Token-string → principal map. The map is copied defensively so a
  /// mutation after construction cannot grant or revoke access.
  final Map<String, TomPrincipal> _tokens;

  StaticBearerTokenAuthenticator(Map<String, TomPrincipal> tokens)
      : _tokens = Map<String, TomPrincipal>.unmodifiable(tokens);

  @override
  TomPrincipal authenticate(String token) {
    if (token.isEmpty) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.missing,
        'Empty bearer token.',
      );
    }
    final principal = _tokens[token];
    if (principal == null) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.rejected,
        'Bearer token is not a member of the configured shared-secret set.',
      );
    }
    return principal;
  }
}
