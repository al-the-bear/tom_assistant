// TelegramChatProfileConfig + per-chat scope resolution
// (`memory_session_profiles.md` § 9.1, MSP-6) — the typed
// `access.telegram.chats[]` entry and the pure rule that turns a chat's
// configured prefixes into the effective session + memory ids its commands
// are scoped within.
//
// ── Where this sits in the flow ──────────────────────────────────────────
//
// Telegram selection is chat-keyed (MSP-6): a chat's session and memory
// commands address *selectors within its scope*, never raw global ids. Each
// configured chat declares its namespace — a `sessionPrefix` / `memoryPrefix`
// — and the MSP-4 rule
//
//     effective id = prefix + (selector ?? <chat default selector>)
//
// produces the ids the edge stamps onto `Access`. A chat with **no** entry is
// modelled as [TelegramChatProfileConfig.unconfigured]: the all-default entry whose
// effective ids are `defaultsession_default` / `defaultmemory_default`,
// byte-compatible with a brand-new chat (§ 9.1).
//
// The guiding rule (spec § 0) mirrors `ApiKeyConfig`: the channel binding
// carries the *selection*, the config carries the *namespace*. This file is
// pure: types + resolution, no I/O. The YAML parsing that produces these
// entries lives in `AccessConfigLoader` (`access_config_loader.dart`); wiring
// resolution into the live Telegram command path is plan steps 10–11.
//
// ── Why `TelegramChatProfileConfig`, not the plan's `TelegramChatConfig` ──
//
// `tom_chattools` already exports a public `TelegramChatConfig` (the chat-API
// *transport* config). The Telegram command path (steps 10–11) imports both
// barrels, so the plan's literal name would force `ambiguous_import` on every
// such consumer. This type configures a chat's session/memory **profiles**, so
// `TelegramChatProfileConfig` is both collision-free and more precise (MSPP-31).

import 'api_key_config.dart'
    show defaultMemoryPrefix, defaultProfileSelector, defaultSessionPrefix;

/// One `access.telegram.chats[]` entry (spec § 9.1): a chat id plus the
/// namespace it scopes that chat's sessions and memory into.
///
/// Immutable value object. Parsed by `AccessConfigLoader`; `/create_memory` /
/// the session commands (plan steps 10–11) resolve selectors against it. The
/// [chatId] is the Telegram chat the entry configures; [sessionPrefix] /
/// [memoryPrefix] are the namespace (defaulting to [defaultSessionPrefix] /
/// [defaultMemoryPrefix], MSP-4); [defaultSession] / [defaultMemory] are the
/// selectors the chat starts on (defaulting to [defaultProfileSelector]);
/// [principal] joins this chat to a `users[]` entry for quota/persona (equal
/// `principalId` strings share a quota bucket), defaulting to the [chatId]
/// itself when omitted (§ 9.1).
final class TelegramChatProfileConfig {
  /// The Telegram chat id this entry configures. Non-empty. Always a string —
  /// an integer YAML scalar is coerced by the loader (MSPP-29).
  final String chatId;

  /// The principal this chat resolves to. When omitted, the [chatId] itself is
  /// the principal (§ 9.1). A non-secret `users[]` id is recommended so the
  /// chat shares that user's quota/persona by `principalId` equality.
  final String? principal;

  /// The session-name prefix (MSP-4). Defaults to [defaultSessionPrefix].
  final String sessionPrefix;

  /// The memory-profile prefix (MSP-4). Defaults to [defaultMemoryPrefix].
  final String memoryPrefix;

  /// The session selector the chat starts on (§ 9.1). Defaults to
  /// [defaultProfileSelector] (`'default'`).
  final String defaultSession;

  /// The memory-profile selector the chat starts on (§ 9.1). Defaults to
  /// [defaultProfileSelector] (`'default'`).
  final String defaultMemory;

  /// Builds a per-chat config. [chatId] must be non-empty.
  TelegramChatProfileConfig({
    required this.chatId,
    this.principal,
    this.sessionPrefix = defaultSessionPrefix,
    this.memoryPrefix = defaultMemoryPrefix,
    this.defaultSession = defaultProfileSelector,
    this.defaultMemory = defaultProfileSelector,
  }) {
    if (chatId.isEmpty) {
      throw ArgumentError.value(chatId, 'chatId', 'must be non-empty');
    }
  }

  /// The all-default entry for a chat with **no** `chats[]` entry (§ 9.1).
  ///
  /// Resolves to `defaultsession_default` / `defaultmemory_default` — the same
  /// ids a brand-new chat sees. The edge's resolution idiom (steps 10–11) is
  /// `telegramChatFor(chatId) ?? TelegramChatProfileConfig.unconfigured(chatId)`.
  factory TelegramChatProfileConfig.unconfigured(String chatId) =>
      TelegramChatProfileConfig(chatId: chatId);

  /// The effective principal id this chat binds to: [principal] when set, else
  /// the [chatId] itself (§ 9.1).
  String get effectivePrincipalId => principal ?? chatId;

  /// The effective session id the chat starts on:
  /// `sessionPrefix + defaultSession` (MSP-4). Equal to `resolveSessionId(null)`.
  String get effectiveDefaultSessionId => sessionPrefix + defaultSession;

  /// The effective memory profile the chat starts on:
  /// `memoryPrefix + defaultMemory` (MSP-4). Equal to
  /// `resolveMemoryProfile(null)`.
  String get effectiveDefaultMemoryProfile => memoryPrefix + defaultMemory;

  /// Resolves an explicit session [selector] (a command argument) within this
  /// chat's scope: `sessionPrefix + (selector ?? defaultSession)` (MSP-6).
  ///
  /// Pure. An absent selector falls back to the chat's [defaultSession]. The
  /// selector is concatenated verbatim — a command can never address a session
  /// outside the chat's prefix (MSP-6).
  String resolveSessionId(String? selector) =>
      sessionPrefix + (selector ?? defaultSession);

  /// Resolves an explicit memory [selector] (a command argument) within this
  /// chat's scope: `memoryPrefix + (selector ?? defaultMemory)` (MSP-6).
  ///
  /// Pure; same scoping guarantee as [resolveSessionId].
  String resolveMemoryProfile(String? selector) =>
      memoryPrefix + (selector ?? defaultMemory);
}
