// A.76 — Concrete bearer-token authenticators for the MCP server.
//
// The *generic* MCP transport-auth contract — the
// [BearerTokenAuthenticator] interface, the [BearerAuthFailure] /
// [BearerAuthFailureReason] taxonomy, the `_meta` slot key
// ([bearerTokenMetaKey]), and the JSON-RPC error code
// ([bearerAuthRpcErrorCode]) — was promoted to `tom_core_agentic`
// (`src/mcp_auth/`) by Tom Brain completion-plan item 8 so every MCP
// server in the framework reuses one contract. This file keeps only the
// two concrete authenticators, which are kernel-coupled (they resolve to
// a `TomPrincipal`) and therefore cannot live in the `tom_basics`-only
// agentic package. Both bind `BearerTokenAuthenticator<TomPrincipal>`.
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

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show BearerAuthFailure, BearerAuthFailureReason, BearerTokenAuthenticator;
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomBearerAuthentication, TomClientJwtToken, TomPrincipal;

/// JWT-based bearer authenticator wiring
/// `TomBearerAuthentication.convertTokenPayloadToPrincipal`.
///
/// This is the canonical A.76 implementation. The token is parsed as a
/// [TomClientJwtToken] without secret-data decryption — the protocol
/// boundary only cares whether the token resolves to a non-guest
/// principal. Decryption of secret-data (roles / entitlements) is
/// done later, in tool-handler authorisation paths, where the key
/// material is available.
class JwtBearerTokenAuthenticator
    implements BearerTokenAuthenticator<TomPrincipal> {
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
class StaticBearerTokenAuthenticator
    implements BearerTokenAuthenticator<TomPrincipal> {
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
