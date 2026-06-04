// AccessConfig + AccessConfigLoader — the access section of the
// whole-process YAML, and the loader that materialises it (E.44; proto
// spec § 11.4 / § 13.1; AC-11 / AC-12 / AC-13).
//
// Plan step E.44 (verbatim): "Implement configuration loader for the full
// process: substrate, memory, engine, dispatcher, access — one YAML file
// via `tom_build_base`."
//
// ── What "one YAML file for the full process" means here ─────────────
//
// Proto spec § 11.4 spells out the shape: one document carries five
// top-level sections — `substrate:`, `memory:`, `engine:` (the
// dispatcher's knobs live under `dispatcher:` too), and `access:` — and
// "each component's config section is its own already-defined loader".
// Substrate's `SubstrateConfigLoader`, memory's `MemoryConfigLoader`, and
// the procedure prototype's `EngineConfig` / `DispatcherConfig` each read
// *only their own top-level key* from the document and ignore the rest
// (verified against `SubstrateConfigLoader.parse`, which does
// `loadYaml(content)['substrate']`). So the single file can be handed
// verbatim to all five loaders with no duplication — the "one file"
// guarantee is structural, not a god-loader.
//
// This file owns the **access section's** loader. The other four sections
// are parsed by their own loaders from the same file. Crucially, those
// four loaders live in `tom_brain_substrate` / `tom_brain_memory` /
// `tom_brain_procedure_prototype`, and the access package is forbidden to
// import substrate / memory directly (pubspec § "Explicitly NOT here";
// `dependency_surface_test.dart`). So the four sibling sections are loaded
// at boot wiring (E.45) from the side that may legally import them — never
// from this package. The decision is logged in the questions doc
// (Q-E.44.1). Within that boundary, [AccessConfigLoader] is the complete,
// testable access contribution: it validates the document's top-level
// shape (rejecting unknown root keys — AC-12 forward-only) and parses the
// `access:` block into a typed [AccessConfig].
//
// ── What AccessConfig carries (proto spec § 13.1) ────────────────────
//
//   * OpenAI adapter port + base path (E.11).
//   * Telegram bot token (E.19).
//   * The declared [AccessUser] list (Q-E.24.2) — one entry per human, each
//     owning its credentials across the OpenAI + Telegram channels. This is
//     the *declarative* source of identity: a deployment unifies a person's
//     OpenAI and Telegram access by listing both credentials under one user,
//     instead of hand-matching a `principalId` string on two separate
//     credential maps.
//   * The OpenAI bearer-token → identity bindings and the Telegram user-id →
//     identity bindings (E.24/E.28) — the *runtime* maps the resolvers
//     consume. The loader derives both from [users], so one human maps to one
//     `principalId` across both channels; the Telegram whitelist is the
//     Telegram binding key set (one source of truth). Tests / boot may set
//     these maps directly without a user list when they exercise the resolver
//     contract below the config-declaration layer.
//   * The per-principal rate-limit policy (E.29).
//   * The per-principal daily quota cap (E.30).
//   * The anchor pre-check disallowed-signature list (E.31).
//   * The persona-as-model vocabulary (E.26), or `null` for the default.
//   * The session sliding-window capacity (E.25).
//   * The embedding-cache TTL (E.34).
//
// AccessConfig is a pure data holder — it builds no runtime collaborator
// and imports nothing from `boot/`. The boot root (E.45) maps it onto the
// `BrainAccessConfig` composition input, injecting the runtime seams
// (clock, bearer authenticator, classifier embed/classify) that are *not*
// config. Keeping the mapping out of here preserves the one-directional
// `config → {edge_security, identity}` import shape.
//
// ── `${ENV}` substitution ────────────────────────────────────────────
//
// String-valued secrets (bearer-token keys, the Telegram bot token) accept
// `${NAME}` tokens expanded from a caller-supplied env map — the same
// posture (and the same scanner) as `SubstrateConfigLoader` /
// `MemoryConfigLoader`: the loader never reads `Platform.environment`
// itself, so it stays deterministic for tests.

import '../adapters/openai_http_sse/openai_http_sse_adapter.dart'
    show OpenAiHttpSseAdapter;
import '../edge_security/anchor_precheck.dart';
import '../edge_security/quota.dart';
import '../edge_security/rate_limiter.dart';
import '../identity/identity_resolver.dart';
import '../identity/session_manager.dart' show defaultMaxWindowTurns;

/// Raised when the whole-process YAML's `access:` section (or the
/// document's top-level shape) is malformed (E.44).
///
/// The [message] is a dotted key path identifying the offending field, or
/// a human-readable description when the failure straddles several keys —
/// the same shape as `SubstrateConfigException` / `MemoryConfigException`.
class AccessConfigException implements Exception {
  /// Dotted key path identifying the offending field, or a human-readable
  /// description.
  final String message;

  /// Builds the exception over [message].
  const AccessConfigException(this.message);

  @override
  String toString() => 'AccessConfigException: $message';
}

/// A declared human and the credentials that identify them across channels
/// (Q-E.24.2).
///
/// One [AccessUser] is the first-class "user" the deployment configures
/// once: a stable [id] (which becomes the `principalId` flowing into the
/// memory scope), the human facts ([username] / [numericId] / [displayName]
/// / [claims]), and the credentials that prove the person on each channel —
/// [openAiBearerTokens] (OpenAI) and [telegramUserIds] (Telegram). The
/// loader projects every credential to an [IdentityBinding] carrying *this
/// user's* facts, so the same person's OpenAI and Telegram credentials
/// resolve to one `principalId` (the channel distinction lives only in the
/// session key, E.25). Memory therefore accrues to the person, not the
/// transport.
///
/// Immutable value object. A user must declare at least one credential —
/// a user with no credentials could never be admitted and is a
/// configuration mistake, surfaced loudly.
final class AccessUser {
  /// The stable, non-secret principal identifier for this human. Non-empty.
  /// Becomes [IdentityBinding.principalId] on every credential's binding.
  final String id;

  /// The principal's login username (the kernel `TomUser.username`), the
  /// join key the bearer authenticator's validated principal is matched on
  /// (Q-E.51.4). Defaults to [id] when a deployment has no separate username.
  final String username;

  /// The principal's numeric kernel id (`TomUser.id`). Defaults to `-1`
  /// (the kernel's "unset" sentinel) — identity is keyed on [id], not this.
  final int numericId;

  /// Optional human-readable display name (the kernel `TomUser.firstname`),
  /// surfaced on `ResolvedIdentity.displayName`. Never load-bearing for
  /// authorization.
  final String? displayName;

  /// Opaque, config-sourced claims (roles, scopes, quota refs) carried onto
  /// every binding's `ResolvedIdentity.claims`. The dispatcher does not
  /// interpret them.
  final Map<String, Object?> claims;

  /// The OpenAI bearer-token secrets that identify this user (E.28). Each
  /// becomes a key in `AccessConfig.bearerTokenBindings`. May be empty when
  /// the user has no OpenAI access.
  final List<String> openAiBearerTokens;

  /// The Telegram user ids that identify this user (E.22/E.24). Each becomes
  /// a key in `AccessConfig.telegramUserIdBindings` — and thus a member of
  /// the Telegram whitelist. May be empty when the user has no Telegram
  /// access.
  final List<String> telegramUserIds;

  /// Builds an immutable user. [id] must be non-empty and the user must
  /// declare at least one credential across the two channels.
  AccessUser({
    required this.id,
    String? username,
    this.numericId = -1,
    this.displayName,
    Map<String, Object?> claims = const {},
    List<String> openAiBearerTokens = const [],
    List<String> telegramUserIds = const [],
  })  : username = username ?? id,
        claims = Map.unmodifiable(claims),
        openAiBearerTokens = List.unmodifiable(openAiBearerTokens),
        telegramUserIds = List.unmodifiable(telegramUserIds) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must be non-empty');
    }
    if (openAiBearerTokens.isEmpty && telegramUserIds.isEmpty) {
      throw ArgumentError.value(
        id,
        'id',
        'user "$id" must declare at least one credential '
            '(an OpenAI bearer token or a Telegram user id)',
      );
    }
  }

  /// The [IdentityBinding] every one of this user's credentials resolves to.
  ///
  /// All of a user's credentials share one binding (one `principalId`, one
  /// set of human facts), which is exactly what unifies the person across
  /// channels.
  IdentityBinding toBinding() => IdentityBinding(
        principalId: id,
        username: username,
        numericId: numericId,
        displayName: displayName,
        claims: claims,
      );
}

/// The typed `access:` section of the whole-process configuration (E.44;
/// proto spec § 13.1).
///
/// Loaded from the single whole-process YAML file by [AccessConfigLoader];
/// a test constructs one directly. Every field is ready-to-use: the
/// edge-security policies are the concrete policy objects the limiters
/// take, and the whitelist / bindings are the maps the resolvers take. The
/// boot root (E.45) maps this onto `BrainAccessConfig`, injecting the
/// runtime seams (clock, classifier embed/classify) that are not config.
final class AccessConfig {
  /// The TCP port the OpenAI HTTP/SSE adapter (E.11) listens on. `> 0`.
  final int openAiPort;

  /// The base path the OpenAI routes mount under (E.11). Defaults to
  /// [OpenAiHttpSseAdapter.basePath] (`/v1`).
  final String openAiBasePath;

  /// The Telegram bot token (E.19), or `null` when no Telegram channel is
  /// configured. `${ENV}`-expanded at load.
  final String? telegramBotToken;

  /// The declared humans (Q-E.24.2) — the *declarative* identity source. One
  /// entry per person, each owning its credentials across both channels.
  /// Empty when a deployment configures no users (or builds the binding maps
  /// directly). [bearerTokenBindings] and [telegramUserIdBindings] are the
  /// projection of this list (see [bindingsForUsers]).
  final List<AccessUser> users;

  /// OpenAI bearer token → identity binding (E.24/E.28). One entry per
  /// accepted shared secret; the key is the (possibly `${ENV}`-expanded)
  /// token, the value the non-secret principal binding. The loader derives
  /// this from [users]; tests / boot may set it directly.
  final Map<String, IdentityBinding> bearerTokenBindings;

  /// Telegram user id → identity binding (E.24). One entry per whitelisted
  /// sender; the key set *is* the whitelist (one source of truth, exposed
  /// via [telegramWhitelist]). The loader derives this from [users]; tests /
  /// boot may set it directly.
  final Map<String, IdentityBinding> telegramUserIdBindings;

  /// The short-horizon burst-throttle policy (E.29).
  final RateLimitPolicy rateLimitPolicy;

  /// The long-horizon daily-cap policy (E.30).
  final DailyQuotaPolicy dailyQuotaPolicy;

  /// The content-screen signature policy (E.31). An empty policy admits
  /// every prompt (the screen is disabled).
  final AnchorPolicy anchorPolicy;

  /// The persona-as-model vocabulary (E.26), or `null` for the shared
  /// default (`OpenAiPersonaMapping.knownModels`).
  final List<String>? personaVocabulary;

  /// The session sliding-window capacity (E.25). `>= 1`.
  final int sessionMaxWindowTurns;

  /// The embedding-cache TTL (E.34). Strictly positive.
  final Duration embeddingCacheTtl;

  /// Directory the edge limiters persist their per-principal state under
  /// (E.29 rate-limit buckets, E.30 daily-quota counters; P1.4), or `null`
  /// to keep that state in process only. When set, boot (E.45) places one
  /// JSON file per limiter inside it, so a restart — including one near the
  /// day boundary — cannot reset the daily cap. A relative path is resolved
  /// against the process working directory by boot.
  final String? edgeStateDirectory;

  /// Builds an access config. Callers normally go through
  /// [AccessConfigLoader]; tests construct one directly.
  AccessConfig({
    required this.openAiPort,
    required this.rateLimitPolicy,
    required this.dailyQuotaPolicy,
    required this.anchorPolicy,
    this.openAiBasePath = OpenAiHttpSseAdapter.basePath,
    this.telegramBotToken,
    List<AccessUser> users = const [],
    Map<String, IdentityBinding> bearerTokenBindings = const {},
    Map<String, IdentityBinding> telegramUserIdBindings = const {},
    this.personaVocabulary,
    this.sessionMaxWindowTurns = defaultMaxWindowTurns,
    this.embeddingCacheTtl = const Duration(minutes: 5),
    this.edgeStateDirectory,
  })  : users = List.unmodifiable(users),
        bearerTokenBindings = Map.unmodifiable(bearerTokenBindings),
        telegramUserIdBindings = Map.unmodifiable(telegramUserIdBindings) {
    if (openAiPort <= 0) {
      throw ArgumentError.value(openAiPort, 'openAiPort', 'must be > 0');
    }
    if (sessionMaxWindowTurns < 1) {
      throw ArgumentError.value(
        sessionMaxWindowTurns,
        'sessionMaxWindowTurns',
        'must be >= 1',
      );
    }
    if (embeddingCacheTtl <= Duration.zero) {
      throw ArgumentError.value(
        embeddingCacheTtl,
        'embeddingCacheTtl',
        'must be a strictly positive duration',
      );
    }
  }

  /// The Telegram user-id whitelist — the key set of
  /// [telegramUserIdBindings] (proto spec § 13.1). Empty when no Telegram
  /// users are configured.
  Set<String> get telegramWhitelist =>
      telegramUserIdBindings.keys.toSet();

  /// Whether a Telegram channel is configured (a bot token is present).
  bool get hasTelegram => telegramBotToken != null;

  /// Projects a list of declared [users] onto the two runtime binding maps
  /// `(bearerTokenBindings, telegramUserIdBindings)` (Q-E.24.2).
  ///
  /// Every credential of a user yields one binding carrying *that user's*
  /// facts, so one human maps to one `principalId` across both channels. The
  /// projection is the single source of truth for the accepted credential
  /// set; the loader calls it after parsing `access.users`.
  ///
  /// A credential may identify exactly one human, so the projection rejects
  /// (with [ArgumentError]) a [user id], a bearer token, or a Telegram user
  /// id shared by two users — an ambiguous mapping is a configuration error,
  /// never a silent last-wins.
  static (Map<String, IdentityBinding>, Map<String, IdentityBinding>)
      bindingsForUsers(Iterable<AccessUser> users) {
    final bearer = <String, IdentityBinding>{};
    final telegram = <String, IdentityBinding>{};
    final seenUserIds = <String>{};
    for (final user in users) {
      if (!seenUserIds.add(user.id)) {
        throw ArgumentError.value(
          user.id,
          'users',
          'duplicate user id — each human must be declared once',
        );
      }
      final binding = user.toBinding();
      for (final token in user.openAiBearerTokens) {
        if (bearer.containsKey(token)) {
          throw ArgumentError(
            'OpenAI bearer token is shared by two users — a credential '
            'identifies exactly one human',
          );
        }
        bearer[token] = binding;
      }
      for (final telegramUserId in user.telegramUserIds) {
        if (telegram.containsKey(telegramUserId)) {
          throw ArgumentError.value(
            telegramUserId,
            'users',
            'Telegram user id is shared by two users — a credential '
                'identifies exactly one human',
          );
        }
        telegram[telegramUserId] = binding;
      }
    }
    return (bearer, telegram);
  }
}
