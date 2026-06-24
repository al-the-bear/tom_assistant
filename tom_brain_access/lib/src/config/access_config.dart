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
// `tom_brain_procedure`, and the access package is forbidden to
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

import 'package:tom_brain_shared/tom_brain_shared.dart' show HistorySizing;

import '../adapters/openai_http_sse/openai_http_sse_adapter.dart'
    show OpenAiHttpSseAdapter;
import '../edge_security/anchor_precheck.dart';
import '../edge_security/quota.dart';
import '../edge_security/rate_limiter.dart';
import '../identity/identity_resolver.dart';
import 'api_key_config.dart';
import 'telegram_chat_profile_config.dart';

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

  /// The Telegram user ids that identify this user (E.22/E.24). Each becomes
  /// a key in `AccessConfig.telegramUserIdBindings` — and thus a member of
  /// the Telegram whitelist. Non-empty: a declared user is a Telegram
  /// identity (OpenAI credentials are declared as first-class
  /// `access.apiKeys[]` entries, MSPP-61 / G-3).
  final List<String> telegramUserIds;

  /// Builds an immutable user. [id] must be non-empty and the user must
  /// declare at least one Telegram user id (its credential). OpenAI bearer
  /// credentials are no longer carried here — they are `access.apiKeys[]`
  /// entries (MSPP-61 / G-3).
  AccessUser({
    required this.id,
    String? username,
    this.numericId = -1,
    this.displayName,
    Map<String, Object?> claims = const {},
    List<String> telegramUserIds = const [],
  })  : username = username ?? id,
        claims = Map.unmodifiable(claims),
        telegramUserIds = List.unmodifiable(telegramUserIds) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must be non-empty');
    }
    if (telegramUserIds.isEmpty) {
      throw ArgumentError.value(
        id,
        'id',
        'user "$id" must declare at least one Telegram user id',
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

  /// The TCP port the Ollama HTTP adapter (plan-2 #27) listens on, or `null`
  /// when no Ollama channel is configured. `> 0` when present. The bearer
  /// tokens / persona vocabulary it accepts are the shared ones — only the
  /// listening port (and [ollamaBasePath]) are Ollama-specific.
  final int? ollamaPort;

  /// The base path the Ollama routes mount under (`/api/chat`, `/api/generate`).
  /// Defaults to `/api`. Only meaningful when [ollamaPort] is set.
  final String ollamaBasePath;

  /// The TCP port the Anthropic Messages HTTP adapter (plan-2 #28) listens on,
  /// or `null` when no Anthropic channel is configured. `> 0` when present.
  final int? anthropicPort;

  /// The base path the Anthropic route mounts under (`/v1/messages`). Defaults
  /// to `/v1`. Only meaningful when [anthropicPort] is set.
  final String anthropicBasePath;

  /// The Telegram bot token (E.19), or `null` when no Telegram channel is
  /// configured. `${ENV}`-expanded at load.
  final String? telegramBotToken;

  /// The declared humans (Q-E.24.2) — the *declarative* Telegram identity
  /// source. One entry per person, each owning its Telegram credentials.
  /// Empty when a deployment configures no users (or builds the binding maps
  /// directly). [telegramUserIdBindings] is the projection of this list (see
  /// [bindingsForUsers]). OpenAI credentials are declared as [apiKeys]
  /// (MSPP-61 / G-3), not here.
  final List<AccessUser> users;

  /// OpenAI bearer token → identity binding (E.24/E.28). One entry per
  /// accepted shared secret; the key is the (possibly `${ENV}`-expanded)
  /// token, the value the non-secret principal binding. The loader derives
  /// this from [apiKeys] (MSPP-61 / G-3); tests / boot may set it directly.
  final Map<String, IdentityBinding> bearerTokenBindings;

  /// Telegram user id → identity binding (E.24). One entry per whitelisted
  /// sender; the key set *is* the whitelist (one source of truth, exposed
  /// via [telegramWhitelist]). The loader derives this from [users]; tests /
  /// boot may set it directly.
  final Map<String, IdentityBinding> telegramUserIdBindings;

  /// The per-key session/memory namespacing entries
  /// (`memory_session_profiles.md` § 5.1, MSP-4). One [ApiKeyConfig] per
  /// declared API key; the entry carries the credential the residual token is
  /// matched against plus the `sessionPrefix` / `memoryPrefix` namespace that
  /// turns a request's selectors into effective ids. Empty when no `apiKeys:`
  /// block is configured.
  ///
  /// Each entry's [ApiKeyConfig.key] is also folded into [bearerTokenBindings]
  /// by the loader, so an API key authenticates exactly like a user bearer
  /// token; this list is the *namespace* side, looked up after authentication
  /// via [apiKeyFor] to resolve the request's session + memory scope.
  final List<ApiKeyConfig> apiKeys;

  /// Index of [apiKeys] by [ApiKeyConfig.key], built once at construction so
  /// the edge can resolve a freshly-authenticated residual key to its prefixes
  /// in O(1) (step 5). Rejects a duplicate key (the same credential declared
  /// twice is a configuration error, never a silent last-wins).
  final Map<String, ApiKeyConfig> _apiKeysByKey;

  /// The per-chat Telegram session/memory namespacing entries
  /// (`memory_session_profiles.md` § 9.1, MSP-6). One [TelegramChatProfileConfig] per
  /// configured chat; the entry carries the `sessionPrefix` / `memoryPrefix`
  /// namespace that scopes that chat's session + memory commands. Empty when no
  /// `access.telegram.chats:` block is configured.
  ///
  /// Looked up by chat id via [telegramChatFor]; a chat with no entry uses
  /// [TelegramChatProfileConfig.unconfigured] (the built-in `defaultsession_` /
  /// `defaultmemory_` prefixes).
  final List<TelegramChatProfileConfig> telegramChats;

  /// Index of [telegramChats] by [TelegramChatProfileConfig.chatId], built once at
  /// construction so the edge resolves a chat to its prefixes in O(1)
  /// (steps 10–11). Rejects a duplicate chat id (the same chat configured
  /// twice is a configuration error, never a silent last-wins).
  final Map<String, TelegramChatProfileConfig> _telegramChatsByChatId;

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

  /// The history sizing for the foreground answer lane (history-compaction
  /// quest, todo #7; hub § 22.6b). The loader resolves it from the
  /// whole-process document's top-level `history:` block —
  /// `HistoryConfig.sizingFor(foregroundAnswerLaneId)` — so a
  /// `history.lanes.foreground` override (or the `history.defaults`) sizes the
  /// conversation histories the `SessionManager` creates. Defaults to
  /// [HistorySizing.standard] when no `history:` block is present, replacing the
  /// formerly hardcoded `SessionManager` default (HP1).
  final HistorySizing answerLaneSizing;

  /// The embedding-cache TTL (E.34). Strictly positive.
  final Duration embeddingCacheTtl;

  /// Directory the edge limiters persist their per-principal state under
  /// (E.29 rate-limit buckets, E.30 daily-quota counters; P1.4), or `null`
  /// to keep that state in process only. When set, boot (E.45) places one
  /// JSON file per limiter inside it, so a restart — including one near the
  /// day boundary — cannot reset the daily cap. A relative path is resolved
  /// against the process working directory by boot.
  final String? edgeStateDirectory;

  /// Directory the session manager persists its conversation histories under
  /// (persistence of history; umbrella Hard principle 6 — "nothing is ever
  /// lost"; access spec § 21.10), or `null` to keep histories in process only.
  /// When set, boot (E.45) places one JSON file inside it holding the whole
  /// session-histories snapshot, so a restart resumes every conversation
  /// mid-stream (the "doesn't remember after restart" defect this fixes). A
  /// relative path is resolved against the process working directory by boot.
  final String? historyDirectory;

  /// Builds an access config. Callers normally go through
  /// [AccessConfigLoader]; tests construct one directly.
  AccessConfig({
    required this.openAiPort,
    required this.rateLimitPolicy,
    required this.dailyQuotaPolicy,
    required this.anchorPolicy,
    this.openAiBasePath = OpenAiHttpSseAdapter.basePath,
    this.ollamaPort,
    this.ollamaBasePath = '/api',
    this.anthropicPort,
    this.anthropicBasePath = '/v1',
    this.telegramBotToken,
    List<AccessUser> users = const [],
    Map<String, IdentityBinding> bearerTokenBindings = const {},
    Map<String, IdentityBinding> telegramUserIdBindings = const {},
    List<ApiKeyConfig> apiKeys = const [],
    List<TelegramChatProfileConfig> telegramChats = const [],
    this.personaVocabulary,
    this.answerLaneSizing = const HistorySizing.standard(),
    this.embeddingCacheTtl = const Duration(minutes: 5),
    this.edgeStateDirectory,
    this.historyDirectory,
  })  : users = List.unmodifiable(users),
        bearerTokenBindings = Map.unmodifiable(bearerTokenBindings),
        telegramUserIdBindings = Map.unmodifiable(telegramUserIdBindings),
        apiKeys = List.unmodifiable(apiKeys),
        _apiKeysByKey = _indexApiKeys(apiKeys),
        telegramChats = List.unmodifiable(telegramChats),
        _telegramChatsByChatId = _indexTelegramChats(telegramChats) {
    if (openAiPort <= 0) {
      throw ArgumentError.value(openAiPort, 'openAiPort', 'must be > 0');
    }
    if (ollamaPort != null && ollamaPort! <= 0) {
      throw ArgumentError.value(ollamaPort, 'ollamaPort', 'must be > 0');
    }
    if (anthropicPort != null && anthropicPort! <= 0) {
      throw ArgumentError.value(anthropicPort, 'anthropicPort', 'must be > 0');
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

  /// Whether an Ollama channel is configured (a listening port is present).
  bool get hasOllama => ollamaPort != null;

  /// Whether an Anthropic channel is configured (a listening port is present).
  bool get hasAnthropic => anthropicPort != null;

  /// The [ApiKeyConfig] whose [ApiKeyConfig.key] is [residualKey], or `null`
  /// when no `apiKeys:` entry declares that credential
  /// (`memory_session_profiles.md` § 3.2).
  ///
  /// The edge calls this *after* the residual token authenticates against
  /// [bearerTokenBindings] (step 5): a hit supplies the session/memory
  /// prefixes; a miss means the credential authenticated as a plain user
  /// bearer token (no per-key namespacing) and the default prefixes apply.
  ApiKeyConfig? apiKeyFor(String residualKey) => _apiKeysByKey[residualKey];

  /// The [TelegramChatProfileConfig] whose [TelegramChatProfileConfig.chatId] is [chatId], or
  /// `null` when no `access.telegram.chats:` entry configures that chat
  /// (`memory_session_profiles.md` § 9.1).
  ///
  /// An unconfigured chat (a `null` return) uses
  /// [TelegramChatProfileConfig.unconfigured] — the built-in `defaultsession_` /
  /// `defaultmemory_` prefixes (MSP-4), byte-compatible with a brand-new chat.
  TelegramChatProfileConfig? telegramChatFor(String chatId) =>
      _telegramChatsByChatId[chatId];

  /// Builds the immutable [ApiKeyConfig.key] → entry index, rejecting (with
  /// [ArgumentError]) a key declared by two entries — a credential is declared
  /// exactly once.
  static Map<String, ApiKeyConfig> _indexApiKeys(Iterable<ApiKeyConfig> keys) {
    final byKey = <String, ApiKeyConfig>{};
    for (final cfg in keys) {
      if (byKey.containsKey(cfg.key)) {
        throw ArgumentError.value(
          cfg.key,
          'apiKeys',
          'duplicate API key — each credential is declared once',
        );
      }
      byKey[cfg.key] = cfg;
    }
    return Map.unmodifiable(byKey);
  }

  /// Builds the immutable [TelegramChatProfileConfig.chatId] → entry index, rejecting
  /// (with [ArgumentError]) a chat id configured by two entries — a chat is
  /// configured exactly once (never a silent last-wins).
  static Map<String, TelegramChatProfileConfig> _indexTelegramChats(
    Iterable<TelegramChatProfileConfig> chats,
  ) {
    final byChatId = <String, TelegramChatProfileConfig>{};
    for (final cfg in chats) {
      if (byChatId.containsKey(cfg.chatId)) {
        throw ArgumentError.value(
          cfg.chatId,
          'telegram.chats',
          'duplicate chat id — each chat is configured once',
        );
      }
      byChatId[cfg.chatId] = cfg;
    }
    return Map.unmodifiable(byChatId);
  }

  /// Projects [apiKeys] onto the bearer-token binding contributions the loader
  /// folds into [bearerTokenBindings] (`memory_session_profiles.md` § 5.1) —
  /// the API-key analogue of [bindingsForUsers].
  ///
  /// Each entry's [ApiKeyConfig.key] maps to its [ApiKeyConfig.toBinding] (the
  /// `principalId` is the entry's [ApiKeyConfig.effectivePrincipalId]), so an
  /// API key authenticates exactly like a user bearer token. A key declared by
  /// two entries is rejected (with [ArgumentError]) — a credential identifies
  /// exactly one principal, never a silent last-wins.
  static Map<String, IdentityBinding> bindingsForApiKeys(
    Iterable<ApiKeyConfig> apiKeys,
  ) {
    final bearer = <String, IdentityBinding>{};
    for (final cfg in apiKeys) {
      if (bearer.containsKey(cfg.key)) {
        throw ArgumentError.value(
          cfg.key,
          'apiKeys',
          'duplicate API key — each credential is declared once',
        );
      }
      bearer[cfg.key] = cfg.toBinding();
    }
    return bearer;
  }

  /// Projects a list of declared [users] onto the Telegram runtime binding
  /// map `telegramUserIdBindings` (Q-E.24.2).
  ///
  /// Each user yields one binding carrying *that user's* facts; every Telegram
  /// user id it declares maps to that binding, so one human maps to one
  /// `principalId`. The projection is the single source of truth for the
  /// accepted Telegram credential set; the loader calls it after parsing
  /// `access.users`. (OpenAI bearer credentials are projected separately from
  /// `access.apiKeys[]` via [bindingsForApiKeys], MSPP-61 / G-3.)
  ///
  /// A credential may identify exactly one human, so the projection rejects
  /// (with [ArgumentError]) a [user id] or a Telegram user id shared by two
  /// users — an ambiguous mapping is a configuration error, never a silent
  /// last-wins.
  static Map<String, IdentityBinding> bindingsForUsers(
    Iterable<AccessUser> users,
  ) {
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
    return telegram;
  }
}
