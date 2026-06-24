// ApiKeyConfig + prefix resolution (memory_session_profiles.md § 5 / § 3.2) —
// the typed `access.apiKeys[]` entry and the pure rule that turns a token's
// markers into the effective session + memory ids.
//
// ── Where this sits in the flow ──────────────────────────────────────────
//
// The edge parses a Bearer token into `ApiKeyMarkers` (the §3.1 tokeniser,
// `api_key_markers.dart`, plan step 2): a residual key plus optional session /
// memory selectors. The residual key is authenticated; the matched key's
// [ApiKeyConfig] then supplies the *namespace* — its `sessionPrefix` /
// `memoryPrefix` — and [ApiKeyConfig.resolveScope] applies the MSP-4 rule
//
//     effective id = prefix + (selector ?? 'default')
//
// to produce the [ResolvedProfileScope] the edge stamps onto `Access` (the
// live edge wiring is plan step 5; the `no-key` substitution is step 4). The
// guiding rule (spec § 0): the credential carries the *selection*, the config
// carries the *namespace*. Two keys with the same prefix deliberately share a
// scope; distinct prefixes can never collide.
//
// This file is pure: types + one resolution method, no I/O. The YAML parsing
// that produces [ApiKeyConfig]s and folds their keys into the identity
// registry lives in `AccessConfigLoader` (`access_config_loader.dart`).

import '../edge_security/api_key_markers.dart';
import '../identity/identity_resolver.dart';

/// The built-in session prefix (MSP-4) applied when an [ApiKeyConfig] declares
/// no `sessionPrefix`. Trailing `_` included, so an unconfigured key with no
/// session marker resolves to `defaultsession_default`.
const String defaultSessionPrefix = 'defaultsession_';

/// The built-in memory prefix (MSP-4) applied when an [ApiKeyConfig] declares
/// no `memoryPrefix`. Trailing `_` included, so an unconfigured key with no
/// memory marker resolves to `defaultmemory_default`.
const String defaultMemoryPrefix = 'defaultmemory_';

/// The selector used when a token carries no `session-`/`memory-` marker
/// (§ 3.2). Joined onto the prefix verbatim (`<prefix>default`).
const String defaultProfileSelector = 'default';

/// Applies the prefix-resolution rule to [markers] under the given
/// [sessionPrefix] / [memoryPrefix], with the profile's cross-axis defaults as
/// the no-marker fallback.
///
/// Selector precedence (SC-1 / SC-Q14, plan step 5): an **explicit marker
/// wins**, then the profile's [defaultSession] / [defaultMemory] (when the
/// resolved profile declares one, § 3.7), then the built-in
/// [defaultProfileSelector]:
///
///     effective id = prefix + (marker ?? profileDefault ?? 'default')
///
/// The profile default still passes through the per-tenant prefix, so a default
/// can never escape the key's namespace. [defaultSession] / [defaultMemory]
/// default to `null` (no profile default), keeping the original
/// `marker ?? 'default'` behaviour for every pre-profile call site.
///
/// The single home of the prefix-resolution rule (D-2): both
/// [ApiKeyConfig.resolveScope] (a configured key's own prefixes) and
/// [resolveDefaultScope] (the built-in default prefixes) route through it, so
/// the precedence lives in exactly one place. Pure.
ResolvedProfileScope _scopeFor(
  ApiKeyMarkers markers, {
  required String sessionPrefix,
  required String memoryPrefix,
  String? defaultSession,
  String? defaultMemory,
}) =>
    ResolvedProfileScope(
      sessionId: sessionPrefix +
          (markers.sessionSelector ?? defaultSession ?? defaultProfileSelector),
      memoryProfile: memoryPrefix +
          (markers.memorySelector ?? defaultMemory ?? defaultProfileSelector),
    );

/// Resolves [markers] under the **built-in default** prefixes
/// ([defaultSessionPrefix] / [defaultMemoryPrefix], MSP-4) — the scope a token
/// with no matching [ApiKeyConfig] resolves to (follow-up item 8 / MSPP-62).
///
/// Universalizes the default prefixes to *every* authenticated API-key token so
/// no request runs bare-root (§ 8.1's "bare root is retired"): a token with no
/// markers resolves to `defaultsession_default` / `defaultmemory_default`, and
/// a token carrying `session-`/`memory-` markers resolves to
/// `defaultsession_<sel>` / `defaultmemory_<sel>`. Pure — the same shape as
/// [ApiKeyConfig.resolveScope], differing only in that the prefixes are the
/// built-in defaults rather than a configured key's. The edge applies this only
/// on the token-keyed path; the JWT/authenticator carve-out keeps a null scope
/// (MSP-3), since a shared default session would collapse distinct upstream
/// principals into one history.
///
/// [defaultSession] / [defaultMemory] are the resolved profile's cross-axis
/// defaults (§ 3.7) — the no-marker fallback applied between an explicit marker
/// and the built-in `'default'` (plan step 5). `null` keeps the original
/// `marker ?? 'default'` behaviour.
ResolvedProfileScope resolveDefaultScope(
  ApiKeyMarkers markers, {
  String? defaultSession,
  String? defaultMemory,
}) =>
    _scopeFor(
      markers,
      sessionPrefix: defaultSessionPrefix,
      memoryPrefix: defaultMemoryPrefix,
      defaultSession: defaultSession,
      defaultMemory: defaultMemory,
    );

/// The session id + memory profile a request resolves to, after a key's
/// prefixes are applied to its markers (§ 3.2).
///
/// Both ids are the fully-resolved, namespaced handles the dispatcher sees
/// (MSP-5) — never the bare selector. The edge stamps [sessionId] onto
/// `Access.session.sessionId` and [memoryProfile] onto
/// `Access.session.memoryProfile`.
final class ResolvedProfileScope {
  /// The effective session id: `sessionPrefix + (sessionSelector ?? 'default')`.
  final String sessionId;

  /// The effective memory profile id:
  /// `memoryPrefix + (memorySelector ?? 'default')`.
  final String memoryProfile;

  /// Builds a resolved scope.
  const ResolvedProfileScope({
    required this.sessionId,
    required this.memoryProfile,
  });

  @override
  bool operator ==(Object other) =>
      other is ResolvedProfileScope &&
      other.sessionId == sessionId &&
      other.memoryProfile == memoryProfile;

  @override
  int get hashCode => Object.hash(sessionId, memoryProfile);

  @override
  String toString() =>
      'ResolvedProfileScope(session: $sessionId, memory: $memoryProfile)';
}

/// One `access.apiKeys[]` entry (spec § 5.1): a credential plus the namespace
/// it scopes sessions and memory into.
///
/// Immutable value object. Parsed by `AccessConfigLoader`; `/create_api_key`
/// (plan step 12) appends one at runtime. The [key] is the secret the edge
/// authenticates (after markers are stripped); [sessionPrefix] / [memoryPrefix]
/// are the namespace (defaulting to [defaultSessionPrefix] /
/// [defaultMemoryPrefix], MSP-4); [principal] joins this key to a `users[]`
/// entry for quota/persona (equal `principalId` strings share a quota bucket),
/// defaulting to the [key] itself when omitted (§ 5.1).
final class ApiKeyConfig {
  /// The credential secret the residual token is matched against. Non-empty.
  final String key;

  /// The principal this key resolves to. When omitted, the [key] itself is the
  /// principal (§ 5.1). A non-secret value (e.g. a `users[]` id) is recommended
  /// for a secret key so the secret does not become the logged principal id.
  final String? principal;

  /// The session-id prefix (MSP-4). Defaults to [defaultSessionPrefix].
  final String sessionPrefix;

  /// The memory-profile prefix (MSP-4). Defaults to [defaultMemoryPrefix].
  final String memoryPrefix;

  /// Optional human-readable label, carried onto the identity binding's
  /// display name. Never load-bearing.
  final String? displayName;

  /// Builds an API-key config. [key] must be non-empty.
  ApiKeyConfig({
    required this.key,
    this.principal,
    this.sessionPrefix = defaultSessionPrefix,
    this.memoryPrefix = defaultMemoryPrefix,
    this.displayName,
  }) {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'must be non-empty');
    }
  }

  /// The effective principal id this key binds to: [principal] when set, else
  /// the [key] itself (§ 5.1).
  String get effectivePrincipalId => principal ?? key;

  /// Resolves [markers] (parsed from the Bearer token) against this key's
  /// prefixes into the effective `(sessionId, memoryProfile)` (§ 3.2, MSP-4).
  ///
  /// Pure. Selector precedence (plan step 5): explicit marker → the resolved
  /// profile's [defaultSession] / [defaultMemory] (§ 3.7) → the built-in
  /// [defaultProfileSelector]; the prefix is concatenated verbatim (D-2). The
  /// residual key on [markers] is *not* consulted here — authentication of the
  /// residual is the edge's job; this step only applies the namespace.
  /// [defaultSession] / [defaultMemory] default to `null` (no profile default).
  ResolvedProfileScope resolveScope(
    ApiKeyMarkers markers, {
    String? defaultSession,
    String? defaultMemory,
  }) =>
      _scopeFor(
        markers,
        sessionPrefix: sessionPrefix,
        memoryPrefix: memoryPrefix,
        defaultSession: defaultSession,
        defaultMemory: defaultMemory,
      );

  /// The [IdentityBinding] this key folds into `bearerTokenBindings` (§ 5.1).
  ///
  /// The binding's `principalId` is [effectivePrincipalId], so a key whose
  /// `principal` matches a `users[]` id shares that user's principal — and thus
  /// its quota/persona — by `principalId` equality (the limiters key on it).
  IdentityBinding toBinding() => IdentityBinding(
        principalId: effectivePrincipalId,
        displayName: displayName,
      );
}
