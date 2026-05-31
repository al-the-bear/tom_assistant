// A.76 — Bearer-token authentication for the MCP server.
//
// The plan line for A.76 reads "Wire `TomBearerAuthentication` from
// `tom_core_server` for the bearer-token check." `TomBearerAuthentication`
// actually lives in `tom_core_kernel` (see Q-A.22.2); both packages are
// already direct dependencies of this package, so the wiring works
// regardless of which one the plan named.
//
// The MCP wire protocol used by `dart_mcp` 0.5.1 does not carry an
// `Authorization` header on stdio / UNIX-socket transports — the
// only request-level extensibility point exposed at the `initialize`
// boundary is the `_meta` map (memory spec § 3.2 cross-references the
// MCP specification's `_meta` extensibility rule). We therefore agree a
// well-known meta key, [bearerTokenMetaKey], under which the client
// MUST place the token when the server is constructed with a non-null
// [BearerTokenAuthenticator].
//
// Two implementations ship at A.76:
//
//   - [JwtBearerTokenAuthenticator] — the canonical implementation
//     the plan calls for. Parses the token as a `TomClientJwtToken`
//     (no secret-data decryption needed at the protocol boundary —
//     authorisation against the secret data is the tool handler's
//     job, not the authenticator's), then runs the token through
//     `TomBearerAuthentication.convertTokenPayloadToPrincipal` to get
//     a [TomPrincipal]. Tokens that fail to parse, or that produce a
//     guest / non-authenticated principal, are rejected.
//   - [StaticBearerTokenAuthenticator] — a deployment-grade simple
//     shared-secret implementation, also used by the conformance
//     tests. Accepts a fixed `Map<String, TomPrincipal>` from token
//     string to principal; unknown tokens are rejected.
//
// Both implementations satisfy the same [BearerTokenAuthenticator]
// contract: validate or throw [BearerAuthFailure]. The server
// (`tom_brain_memory_mcp_server.dart`) treats the authenticator as
// opaque and exercises it only at `initialize` time.
//
// Hard-invariant alignment (memory spec):
//
//   - § 1.2 — "memory does not call LLMs on the hot path". Bearer
//     validation is a pure synchronous predicate; it does not reach
//     out for token introspection, key rotation, or anything else
//     that could escalate to an LLM call.
//   - § 1.7 — "no backwards compatibility". The `_meta` key for the
//     bearer token ([bearerTokenMetaKey]) is part of the v1 contract
//     and would be version-bumped, not silently renamed.
//
// Open questions deferred to the prototype-questions log:
//
//   - Q-A.76.1 — Should we add a revocation list / nonce cache?
//     Currently no; revocation is the deploying operator's
//     responsibility (rotate the signing key, refuse the JWT).
//   - Q-A.76.2 — Should authorisation (role / entitlement check)
//     also live here, or strictly in the tool handlers? Currently:
//     here we authenticate (who are you?), tool handlers authorise
//     (are you allowed?). A.77 will register per-tool entitlement
//     requirements.

import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomBearerAuthentication, TomClientJwtToken, TomPrincipal;

/// The JSON-RPC `_meta` key under which clients must place the bearer
/// token at `initialize` time when the server is configured with a
/// [BearerTokenAuthenticator].
///
/// Picked to be namespaced (`tomBrain…`) so it does not collide with
/// the MCP standard `_meta.progressToken` reservation or with other
/// `_meta` consumers a host might layer on.
const bearerTokenMetaKey = 'tomBrainBearerToken';

/// Validates a bearer token presented during the MCP `initialize`
/// handshake.
///
/// Implementations are responsible for **authentication only** —
/// converting a token string into a [TomPrincipal] or rejecting it.
/// Per-tool authorisation (role / entitlement checks against the
/// principal) is the tool handler's job, scheduled for A.77.
///
/// Implementations must be synchronous: the MCP `initialize` handshake
/// is on the hot path and memory spec § 1.2 forbids any LLM / network
/// call at this layer.
abstract interface class BearerTokenAuthenticator {
  /// Validates [token] and returns the resulting principal.
  ///
  /// Throws [BearerAuthFailure] if [token] is missing, malformed, or
  /// otherwise rejected.
  TomPrincipal authenticate(String token);
}

/// Raised when a bearer token cannot be accepted.
///
/// Carries a stable [reason] tag — useful for telemetry and tests —
/// plus a human-readable [message]. The MCP server translates this
/// into a JSON-RPC error during `initialize` (memory spec § 3.2);
/// the underlying message is **not** leaked to the client unmodified
/// because token-introspection error details can be a side-channel
/// for token-guessing attacks.
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
/// The set is closed by design — per memory spec § 1.7, adding a new
/// category is a version bump, not a silent extension.
enum BearerAuthFailureReason {
  /// No `_meta.tomBrainBearerToken` field was present on the
  /// `initialize` request when the server requires one.
  missing,

  /// The token string was present but could not be parsed (malformed
  /// JWT, unknown format, …).
  malformed,

  /// The token parsed but failed authentication (guest principal,
  /// expired, unknown subject, …).
  rejected,
}

/// JWT-based bearer authenticator wiring
/// `TomBearerAuthentication.convertTokenPayloadToPrincipal`.
///
/// This is the canonical A.76 implementation. The token is parsed as a
/// [TomClientJwtToken] without secret-data decryption — the protocol
/// boundary only cares whether the token resolves to a non-guest
/// principal. Decryption of secret-data (roles / entitlements) is
/// done later, in tool-handler authorisation paths, where the key
/// material is available.
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

    TomClientJwtToken parsed;
    try {
      parsed = TomClientJwtToken(token, decrypt: false);
    } catch (error) {
      // `TomClientJwtToken` raises miscellaneous parse errors; we
      // collapse them all into a single `malformed` failure so the
      // client never sees the internal exception text.
      throw BearerAuthFailure(
        BearerAuthFailureReason.malformed,
        'Bearer token failed to parse as JWT: $error',
      );
    }

    if (parsed.payload == null) {
      throw const BearerAuthFailure(
        BearerAuthFailureReason.malformed,
        'Bearer JWT carries no payload.',
      );
    }

    final TomPrincipal principal;
    try {
      principal = TomBearerAuthentication.convertTokenPayloadToPrincipal(
        parsed,
      );
    } catch (error) {
      throw BearerAuthFailure(
        BearerAuthFailureReason.malformed,
        'Bearer JWT payload could not be converted to a principal: $error',
      );
    }

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
/// Maps a closed set of token strings to pre-built principals.
///
/// Two intended uses:
///
///   1. Deployments where the operator wants a simple token-per-client
///      model (a UNIX-socket pair shared by two cooperating processes
///      on the same host, for instance).
///   2. Test bootstraps — the A.76 conformance tests use this
///      implementation to avoid pulling crypto setup into the test.
///
/// Unknown tokens raise [BearerAuthFailureReason.rejected]; empty
/// tokens raise [BearerAuthFailureReason.missing].
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
