// `IdentityResolver` — the edge step that resolves *who* an inbound request
// is, exactly once (E.24).
//
// What this file owns (Plan § Phase E, substep E.24; proto spec § 7.1;
// AC-7):
//
//   * `IdentityBinding` — the prototype's principal-facts record: the
//     stable principal id plus the human-readable facts used to build a
//     `tom_core_kernel` `TomPrincipal`. Boot (E.41+) loads these from
//     configuration, one per known credential.
//   * `IdentityResolutionException` — the typed failure when a credential
//     reaches the resolver with no binding. A credential is validated by
//     the edge "Auth" step (bearer auth E.28 / Telegram whitelist E.22)
//     *before* the resolver runs; an unbound credential here is a
//     configuration mismatch, surfaced loudly rather than silently scoping
//     memory to a fabricated identity.
//   * `IdentityResolver` — maps an OpenAI bearer token / a Telegram user id
//     → an internal `TomPrincipal` (via the kernel identity primitives) →
//     a `tom_brain_shared` `ResolvedIdentity` (the minimal handle the
//     dispatcher threads into the memory scope, § 4.3). Resolution happens
//     once per request; the handle rides the `Access` (AC-7), and the
//     dispatcher never re-authenticates — it reads only
//     `identity.principalId`.
//
// Why a binding registry (not credential-derived identities):
//
//   A bearer token is a secret — deriving a `principalId` from it would
//   leak the secret into the memory scope and the logs. The registry maps
//   a credential to a *stable, non-secret* principal id chosen at config
//   time. Telegram user ids are public, but they go through the same
//   registry so the same person's OpenAI and Telegram credentials can map
//   to one principal id (the channel distinction is the `SessionManager`'s
//   job, E.25, not the identity's).
//
// Why build a real `TomPrincipal` in the middle:
//
//   `tom_brain_shared` may not import `tom_core_kernel` (it is the pure
//   types layer), so `ResolvedIdentity` is deliberately minimal. The
//   access prototype depends on both, so it is the layer that turns the
//   kernel's rich `TomPrincipal` into the dispatcher-facing handle. Doing
//   the projection here keeps the kernel coupling out of the shared types
//   while still satisfying "via tom_core_kernel's identity primitives".
//
// Scope discipline (per the strict per-substep log). E.24 is the
// credential → principal → identity resolver only. It does NOT:
//
//   * resolve sessions (E.25, `SessionManager`) or personas (E.26,
//     `PersonaResolver`) — the other two resolvers that fill an `Access`.
//   * validate credentials — that is the edge "Auth" step (bearer auth
//     E.28 / whitelist E.22); the resolver consumes an already-validated
//     credential.
//   * construct an `Access` or wire boot (E.41+).

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart';

/// The prototype's principal-facts record for one known credential.
///
/// Immutable value object. Boot (E.41+) builds one per configured
/// credential and hands the set to the [IdentityResolver]. It carries the
/// facts needed to construct a `tom_core_kernel` [TomPrincipal] and the
/// stable [principalId] that flows — non-secret — into the memory scope.
final class IdentityBinding {
  /// The stable, non-secret principal identifier. Non-empty — an empty id
  /// would silently scope memory writes to nothing. This is the value that
  /// becomes [ResolvedIdentity.principalId]; it is chosen at config time
  /// and is never derived from a secret credential.
  final String principalId;

  /// The principal's login username (the kernel [TomUser.username]).
  /// Defaults to [principalId] when a deployment has no separate username.
  final String username;

  /// The principal's numeric kernel id ([TomUser.id]). Defaults to `-1`
  /// (the kernel's "unset" sentinel) — the prototype keys identity on the
  /// string [principalId], not the numeric id.
  final int numericId;

  /// Optional human-readable display name (the kernel [TomUser.firstname]),
  /// surfaced on [ResolvedIdentity.displayName] for logs / persona
  /// enrichment. Never load-bearing for authorization.
  final String? displayName;

  /// Opaque, config-sourced claims (roles, scopes, quota refs) carried onto
  /// [ResolvedIdentity.claims]. The dispatcher does not interpret them.
  final Map<String, Object?> claims;

  /// Builds an immutable binding. [principalId] must be non-empty.
  IdentityBinding({
    required this.principalId,
    String? username,
    this.numericId = -1,
    this.displayName,
    Map<String, Object?> claims = const {},
  })  : username = username ?? principalId,
        claims = Map.unmodifiable(claims) {
    if (principalId.isEmpty) {
      throw ArgumentError.value(
        principalId,
        'principalId',
        'must be non-empty',
      );
    }
  }
}

/// Thrown when a credential reaches the resolver with no [IdentityBinding].
///
/// The edge "Auth" step (bearer auth E.28 / Telegram whitelist E.22)
/// validates a credential *before* the resolver runs, so an unbound
/// credential here means the identity registry and the auth configuration
/// have drifted apart. Surfaced as a typed failure rather than a fabricated
/// identity so the mismatch is loud, not silent.
final class IdentityResolutionException implements Exception {
  /// Names the channel whose credential could not be resolved
  /// (`'openai'` / `'ollama'` / `'anthropic'` / `'telegram'`).
  final String channel;

  /// A non-secret description of what failed. For Telegram this is the user
  /// id; for OpenAI it is a redacted note — the bearer token itself is
  /// never put in the message.
  final String detail;

  /// Builds the exception for [channel] with the non-secret [detail].
  const IdentityResolutionException(this.channel, this.detail);

  @override
  String toString() =>
      'IdentityResolutionException($channel): no identity binding — $detail';
}

/// Resolves an inbound credential to a [ResolvedIdentity], exactly once at
/// the edge (AC-7).
///
/// Two channels, two credential kinds: an OpenAI bearer token and a
/// Telegram user id. Each is looked up in its own binding map, built into a
/// `tom_core_kernel` [TomPrincipal] (the "internal principal" of proto spec
/// § 7.1), and projected to the minimal [ResolvedIdentity] the dispatcher
/// threads into the memory scope. Stateless after construction; the binding
/// maps are immutable.
final class IdentityResolver {
  /// OpenAI bearer token → binding. The token is a secret used only as a
  /// lookup key; the resulting [ResolvedIdentity.principalId] is the
  /// binding's non-secret id, never the token.
  final Map<String, IdentityBinding> _byBearerToken;

  /// Telegram user id → binding.
  final Map<String, IdentityBinding> _byTelegramUserId;

  /// Authenticated-principal username → binding, derived from the bearer
  /// bindings (E.24 / Q-E.51.4). This is the index [resolveOpenAiPrincipal]
  /// consumes: when a bearer authenticator (E.28) is wired it yields the
  /// validated principal, and the resolver maps that principal to its binding
  /// by its non-secret [IdentityBinding.username] — never by the raw secret
  /// token. Built from the same `bearerTokenBindings`, so there is one
  /// configured source of truth for the accepted set.
  final Map<String, IdentityBinding> _byPrincipalUsername;

  /// Builds a resolver over the given credential → binding maps.
  ///
  /// The two bearer-keyed indices ([_byBearerToken] / [_byPrincipalUsername])
  /// are copied into *growable* maps so a runtime credential (`/create_api_key`,
  /// MSP-7) can be admitted into them via [admitBearer]; the Telegram index is
  /// copied into an unmodifiable view (no channel admits Telegram ids at
  /// runtime). Copying defensively either way means the constructor arguments
  /// cannot be mutated through this resolver.
  IdentityResolver({
    Map<String, IdentityBinding> bearerTokenBindings = const {},
    Map<String, IdentityBinding> telegramUserIdBindings = const {},
  })  : _byBearerToken = Map.of(bearerTokenBindings),
        _byTelegramUserId = Map.unmodifiable(telegramUserIdBindings),
        _byPrincipalUsername = <String, IdentityBinding>{
          for (final binding in bearerTokenBindings.values)
            binding.username: binding,
        };

  /// Admits a runtime bearer credential: [token] now resolves to [binding] on
  /// both the token-keyed ([resolveBearer]) and principal-keyed
  /// ([resolveBearerPrincipal]) paths (MSP-7).
  ///
  /// The live half of `/create_api_key` (MSPP-42): a key minted at runtime must
  /// authenticate on the very next request. Both indices are updated together so
  /// the new credential resolves whichever bearer path the deployment uses.
  void admitBearer(String token, IdentityBinding binding) {
    _byBearerToken[token] = binding;
    _byPrincipalUsername[binding.username] = binding;
  }

  /// Removes a runtime bearer credential admitted by [admitBearer] — the exact
  /// reverse, used to roll a failed `/create_api_key` back to disk (§ 13).
  ///
  /// A no-op when [token] is unknown. The principal-username index entry is
  /// removed only when it still points at the same binding the token mapped to,
  /// so revoking one runtime key never strips another principal that happens to
  /// share a username.
  void revokeBearer(String token) {
    final IdentityBinding? binding = _byBearerToken.remove(token);
    if (binding == null) {
      return;
    }
    if (identical(_byPrincipalUsername[binding.username], binding)) {
      _byPrincipalUsername.remove(binding.username);
    }
  }

  /// Resolves a bearer [bearerToken] arriving over [channel] to its
  /// [ResolvedIdentity].
  ///
  /// The token-keyed path, used when no bearer authenticator (E.28) is wired —
  /// the identity registry is then the sole credential gate. Identity itself is
  /// channel-blind (E.24): the OpenAI, Ollama (#27), and Anthropic (#28) HTTP
  /// channels all share one `bearerTokenBindings` map, so the same token
  /// resolves to the same principal whichever HTTP dialect it arrived on. The
  /// [channel] is carried only so an unbound-token failure names the channel
  /// the request came in on, keeping logs readable across the resolvers.
  ///
  /// Throws [IdentityResolutionException] when the token has no binding. The
  /// token is treated as a secret — never echoed into the exception or the
  /// resolved identity. When an authenticator *is* wired, the assembler uses
  /// [resolveBearerPrincipal] instead, so identity is never re-resolved from
  /// the raw token (Q-E.51.4).
  ResolvedIdentity resolveBearer(String bearerToken, {required String channel}) {
    final binding = _byBearerToken[bearerToken];
    if (binding == null) {
      throw IdentityResolutionException(channel, 'unrecognised bearer token');
    }
    return _project(binding);
  }

  /// Resolves an OpenAI [bearerToken] to its [ResolvedIdentity].
  ///
  /// Convenience delegate to [resolveBearer] with `channel: 'openai'`, kept so
  /// the OpenAI call sites (and the embeddings passthrough) read at their own
  /// channel name.
  ResolvedIdentity resolveOpenAiBearer(String bearerToken) =>
      resolveBearer(bearerToken, channel: 'openai');

  /// Resolves an already-validated bearer [principal] arriving over [channel]
  /// to its [ResolvedIdentity] (Q-E.51.4).
  ///
  /// The composed counterpart to [resolveBearer]. When a bearer authenticator
  /// (E.28) is wired, it validates the credential and produces the principal;
  /// the resolver consumes that principal *directly* rather than re-resolving
  /// from the raw secret token. The join key is the principal's non-secret
  /// [TomPrincipal.username], matched against the bearer bindings' usernames —
  /// so the stable, config-chosen [ResolvedIdentity.principalId] (which may
  /// differ from the login username) and the binding's claims are still the
  /// source of truth. The bindings are channel-blind, so the same principal
  /// resolves identically across the HTTP channels; [channel] only names the
  /// failure.
  ///
  /// Throws [IdentityResolutionException] when the validated principal has no
  /// identity binding. This makes "authenticated but not provisioned" (e.g. a
  /// valid JWT for a principal absent from the registry) one coherent decision
  /// — a loud failure, never a fabricated identity — instead of an auth pass
  /// followed by an independent, surprising token-lookup miss.
  ResolvedIdentity resolveBearerPrincipal(
    TomPrincipal principal, {
    required String channel,
  }) {
    final binding = _byPrincipalUsername[principal.username];
    if (binding == null) {
      throw IdentityResolutionException(
        channel,
        'authenticated principal has no identity binding',
      );
    }
    return _project(binding);
  }

  /// Resolves an already-validated OpenAI bearer [principal] to its
  /// [ResolvedIdentity].
  ///
  /// Convenience delegate to [resolveBearerPrincipal] with `channel: 'openai'`.
  ResolvedIdentity resolveOpenAiPrincipal(TomPrincipal principal) =>
      resolveBearerPrincipal(principal, channel: 'openai');

  /// Resolves a Telegram [userId] to its [ResolvedIdentity].
  ///
  /// Throws [IdentityResolutionException] (carrying the public [userId])
  /// when the user id has no binding.
  ResolvedIdentity resolveTelegramUser(String userId) {
    final binding = _byTelegramUserId[userId];
    if (binding == null) {
      throw IdentityResolutionException(
        'telegram',
        'unrecognised user id $userId',
      );
    }
    return _project(binding);
  }

  /// Builds a kernel [TomPrincipal] from [binding] and projects it to the
  /// minimal [ResolvedIdentity].
  ///
  /// The intermediate `TomPrincipal` is the "internal principal" proto spec
  /// § 7.1 requires; the projection reads the principal's facts back out so
  /// the handle is genuinely derived *through* the kernel primitive, not
  /// assembled beside it.
  ResolvedIdentity _project(IdentityBinding binding) {
    final principal = TomPrincipal(
      user: TomUser(
        id: binding.numericId,
        username: binding.username,
        firstname: binding.displayName,
      ),
      authenticated: true,
    );
    return ResolvedIdentity(
      principalId: binding.principalId,
      displayName: principal.user.firstname,
      claims: binding.claims,
    );
  }
}
