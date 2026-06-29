// AccessConfigLoader — parses the `access:` section of the whole-process
// YAML into a typed [AccessConfig] (E.44; proto spec § 11.4 / § 13.1).
//
// Modelled on `SubstrateConfigLoader` (B.36) / `MemoryConfigLoader` (A.83):
// the same `loadYaml` + `YamlMap` plumbing, dotted-key-path error messages,
// and "no I/O until `loadFromFile`" discipline (so [parse] stays
// deterministic for tests). The type-coercion field accessors and the
// `${ENV}` substitution are shared with those loaders through
// tom_core_agentic's `YamlConfigReader` (this loader delegates to it rather
// than carrying its own copy).
//
// What the loader does:
//
//   * Validates the document's top-level shape. The whole-process file
//     carries sibling sections — `substrate:`, `memory:`, `engine:`,
//     `dispatcher:`, `trail:`, `tools:`, `access:`. This loader owns `access:`
//     and leaves the others for their own loaders (each reads only its own
//     key — the run package's `TrailConfigLoader` owns `trail:`, its
//     `ToolsConfigLoader` owns `tools:`). Any *other* top-level key is rejected
//     (AC-12 forward-only) so a typo'd section name never silently no-ops.
//   * Requires the `access:` block and parses every documented field.
//     Within `access:`, unknown keys are rejected at every level (AC-12).
//   * Builds the concrete edge-security policies (`RateLimitPolicy`,
//     `DailyQuotaPolicy`, `AnchorPolicy`). Identity is declared once per
//     human under `access.users` (Q-E.24.2): each `AccessUser` owns its
//     OpenAI + Telegram credentials, and the loader projects them onto the
//     two runtime binding maps the resolvers consume (so one person maps to
//     one `principalId` across both channels) — `AccessConfig` is
//     ready-to-wire, not a raw map.
//   * Expands `${NAME}` tokens in string secrets (each user's OpenAI
//     bearer-token entries, the Telegram bot token) from the caller-supplied
//     env map. Telegram user ids are public and used verbatim.
//
// What the loader does NOT do:
//
//   * It does not read `Platform.environment`. Callers pass the env map
//     (typically `Platform.environment`) so the loader is deterministic.
//   * It does not parse the substrate / memory / engine / dispatcher
//     sections (Q-E.44.1) — those loaders live in packages the access
//     layer must not import; the boot root (E.45) parses them from the same
//     file on the side that may legally import them.
//   * It does not construct any runtime collaborator (the limiters, the
//     resolvers, the adapters). That is boot (E.45). It produces typed
//     config only.

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show HistoryConfig, HistoryConfigError, HistorySizing, foregroundAnswerLaneId;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show YamlConfigReader, loadYamlAsMap;
import 'package:yaml/yaml.dart';

import '../edge_security/anchor_precheck.dart';
import '../edge_security/quota.dart';
import '../edge_security/rate_limiter.dart';
import '../identity/identity_resolver.dart';
import 'access_config.dart';
import 'api_key_config.dart';
import 'telegram_chat_profile_config.dart';

/// Parses + materialises [AccessConfig] from the whole-process YAML.
///
/// Namespace-only class (all members static): the loader has no
/// per-instance state, mirroring `SubstrateConfigLoader`.
abstract final class AccessConfigLoader {
  AccessConfigLoader._();

  /// The top-level sections the whole-process document may carry. This
  /// loader owns [_accessKey]; the others are owned by their own loaders
  /// (substrate / memory / engine / dispatcher, the run package's
  /// `TrailConfigLoader` for `trail:` — `tom_brain_logging.md` §8 — its
  /// `ToolsConfigLoader` for `tools:` — the file-scope roots — its
  /// `ScriptsConfigLoader` for `scripts:` — the disk procedure directories
  /// (CLI plan step 3) — its
  /// `DreamConfigLoader` for `dream:` (memory-spec § 9.7), its cognition
  /// loader for `cognition:` — `prompt_configuration.md` §7.4, the prompt /
  /// route resolver root — and the procedure package's `McpServersConfig`
  /// for `mcpServers:` / `mcpServersDir:` (the outbound MCP servers merged into
  /// the tool loop, inline or directory-sourced,
  /// `tom_brain_procedure_specification.md` § 21.6), and the run package's
  /// `ProfileRegistry` for `profiles:` — the Profile selection-axis registry,
  /// `session_configuration.md` § 3, SC-5) and are tolerated here so the single
  /// file feeds every section loader. Any other root key is rejected (AC-12).
  static const Set<String> _allowedTopLevelKeys = <String>{
    'substrate',
    'memory',
    'engine',
    'dispatcher',
    'trail',
    'tools',
    'scripts',
    'dream',
    'cognition',
    'mcpServers',
    'mcpServersDir',
    'profiles',
    'profilesDir',
    _historyKey,
    _accessKey,
  };

  static const String _accessKey = 'access';

  /// The top-level history-sizing block (history-compaction quest, todo #7;
  /// hub § 22.6b). Distinct from `access.history` (which carries the durable
  /// `directory`): this block carries the per-lane [HistorySizing] knobs. This
  /// loader owns it because the access layer is the lane's sizing consumer (it
  /// resolves `foreground` into [AccessConfig.answerLaneSizing]); dream-lane
  /// consumers read the same block independently as they ship (todos #13-15).
  static const String _historyKey = 'history';

  /// Parses the YAML [content] and returns the typed [AccessConfig].
  ///
  /// The document must be a map whose top-level keys are within the
  /// whole-process section set and which contains an `access:` map.
  /// [envVars] expands `${NAME}` tokens inside string secrets; an unknown
  /// token raises [AccessConfigException].
  ///
  /// Pure: no I/O, no clock. Tests reach it directly with inline YAML.
  static AccessConfig parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final dynamic doc;
    try {
      doc = loadYaml(content);
    } on YamlException catch (e) {
      throw AccessConfigException('YAML parse failed: ${e.message}');
    }
    if (doc is! YamlMap) {
      throw const AccessConfigException(
        'Config root must be a YAML map (got a non-map document).',
      );
    }
    _rejectUnknownTopLevelKeys(doc);
    final dynamic node = doc[_accessKey];
    if (node is! YamlMap) {
      throw const AccessConfigException(
        'Missing top-level `access:` map.',
      );
    }
    // Resolve the foreground answer lane's history sizing from the top-level
    // `history:` block (todo #7). The block's lane namespace is shared with the
    // dreaming lanes (decision HC-3); the access layer reads only the
    // `foreground` lane here. Reuses the canonical YAML→plain-map entry point
    // (the `history:` value is already a plain `Map<String, Object?>`).
    final answerLaneSizing = _resolveAnswerLaneSizing(content);
    return _parseAccess(node, envVars, answerLaneSizing);
  }

  /// Resolves the foreground answer lane's [HistorySizing] from the document's
  /// top-level `history:` block (todo #7). An absent block yields
  /// [HistorySizing.standard] (via [HistoryConfig.fromConfigMap]'s null arm); a
  /// below-floor value surfaces as an [AccessConfigException] carrying the
  /// [HistoryConfigError]'s located message.
  static HistorySizing _resolveAnswerLaneSizing(String content) {
    final plain = loadYamlAsMap(
      content,
      errorFactory: AccessConfigException.new,
    );
    final block = plain[_historyKey];
    if (block != null && block is! Map<String, Object?>) {
      throw const AccessConfigException(
        'Top-level `history:` must be a map when present.',
      );
    }
    try {
      final config = HistoryConfig.fromConfigMap(
        block as Map<String, Object?>?,
      );
      return config.sizingFor(foregroundAnswerLaneId);
    } on HistoryConfigError catch (e) {
      throw AccessConfigException(e.toString());
    }
  }

  /// Loads the YAML file at [path] and parses it via [parse].
  ///
  /// Production callers go through this entry point; the test suite uses
  /// [parse] with inline content.
  static AccessConfig loadFromFile(
    String path, {
    Map<String, String> envVars = const {},
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      throw AccessConfigException('Config file not found: $path');
    }
    return parse(file.readAsStringSync(), envVars: envVars);
  }

  // ---------------------------------------------------------------
  // Section parsers.
  // ---------------------------------------------------------------

  static void _rejectUnknownTopLevelKeys(YamlMap doc) {
    for (final keyDyn in doc.keys) {
      if (keyDyn is! String || !_allowedTopLevelKeys.contains(keyDyn)) {
        throw AccessConfigException(
          'Unknown top-level config section "$keyDyn"; the whole-process '
          'document may only contain ${_allowedTopLevelKeys.toList()}.',
        );
      }
    }
  }

  static AccessConfig _parseAccess(
    YamlMap node,
    Map<String, String> env,
    HistorySizing answerLaneSizing,
  ) {
    _rejectUnknownKeys(
      node,
      const <String>{
        'openai',
        'ollama',
        'anthropic',
        'telegram',
        'users',
        'apiKeys',
        'rateLimit',
        'quota',
        'anchor',
        'personas',
        'classifier',
        'edgeState',
        'history',
      },
      'access',
    );

    // OpenAI is the always-present channel (its port is required); Ollama (#27)
    // and Anthropic (#28) are optional bearer HTTP channels with the same
    // port + basePath shape, so all three share `_parsePortAndBasePath`.
    final (port, basePath) = _parsePortAndBasePath(
      _requireMap(node, 'openai', 'access.openai'),
      'access.openai',
      '/v1',
    );
    final (ollamaPort, ollamaBasePath) = _parseOptionalChannel(
      _optionalMap(node, 'ollama', 'access.ollama'),
      'access.ollama',
      '/api',
    );
    final (anthropicPort, anthropicBasePath) = _parseOptionalChannel(
      _optionalMap(node, 'anthropic', 'access.anthropic'),
      'access.anthropic',
      '/v1',
    );

    final (telegramToken, telegramChats) = _parseTelegram(
      _optionalMap(node, 'telegram', 'access.telegram'),
      env,
    );

    // The declared humans are the single declarative *Telegram* identity
    // source; the Telegram binding map is their projection (Q-E.24.2).
    // Telegram user ids are verbatim. OpenAI bearer credentials are declared
    // as `access.apiKeys[]` (MSPP-61 / G-3), not on users.
    final users = _parseUsers(
      _optionalList(node, 'users', 'access.users'),
      env,
    );
    final telegramBindings = _projectUserBindings(users);

    // The per-key namespacing entries (memory_session_profiles.md § 5.1). Each
    // entry's secret `key` is the bearer-token map (so an API key
    // authenticates the request); the entries themselves carry the
    // session/memory prefixes the edge resolves after authentication.
    final apiKeys = _parseApiKeys(
      _optionalList(node, 'apiKeys', 'access.apiKeys'),
      env,
    );
    final bearerBindings = _projectApiKeyBindings(apiKeys);

    final rateLimit = _parseRateLimit(
      _requireMap(node, 'rateLimit', 'access.rateLimit'),
    );
    final quota = _parseQuota(_requireMap(node, 'quota', 'access.quota'));
    final anchor = _parseAnchor(
      _optionalMap(node, 'anchor', 'access.anchor'),
    );
    final personas = _parsePersonas(
      _optionalList(node, 'personas', 'access.personas'),
    );
    final cacheTtl = _parseClassifier(
      _optionalMap(node, 'classifier', 'access.classifier'),
    );
    final edgeStateDir = _parseEdgeState(
      _optionalMap(node, 'edgeState', 'access.edgeState'),
      env,
    );
    final historyDir = _parseHistory(
      _optionalMap(node, 'history', 'access.history'),
      env,
    );

    return AccessConfig(
      openAiPort: port,
      openAiBasePath: basePath,
      ollamaPort: ollamaPort,
      ollamaBasePath: ollamaBasePath,
      anthropicPort: anthropicPort,
      anthropicBasePath: anthropicBasePath,
      telegramBotToken: telegramToken,
      users: users,
      bearerTokenBindings: bearerBindings,
      telegramUserIdBindings: telegramBindings,
      apiKeys: apiKeys,
      telegramChats: telegramChats,
      rateLimitPolicy: rateLimit,
      dailyQuotaPolicy: quota,
      anchorPolicy: anchor,
      personaVocabulary: personas,
      answerLaneSizing: answerLaneSizing,
      embeddingCacheTtl: cacheTtl,
      edgeStateDirectory: edgeStateDir,
      historyDirectory: historyDir,
    );
  }

  /// Parses one bearer HTTP channel's transport block → (port, basePath).
  ///
  /// The shared shape of the `access.openai` (E.11), `access.ollama` (#27),
  /// and `access.anthropic` (#28) sections: a required `port` (`> 0`) and an
  /// optional `basePath` (defaulting to [defaultBasePath], and required to be a
  /// non-empty `/`-rooted path when present). Identity lives under
  /// `access.users` (Q-E.24.2), so a channel block carries transport config
  /// only. [path] is the dotted key path for error messages.
  static (int, String) _parsePortAndBasePath(
    YamlMap node,
    String path,
    String defaultBasePath,
  ) {
    _rejectUnknownKeys(node, const <String>{'port', 'basePath'}, path);
    final port = _requireInt(node, 'port', '$path.port');
    if (port <= 0) {
      throw AccessConfigException('$path.port must be > 0.');
    }
    final basePath =
        _optionalString(node, 'basePath', '$path.basePath') ?? defaultBasePath;
    if (basePath.isEmpty || !basePath.startsWith('/')) {
      throw AccessConfigException(
        '$path.basePath must be a non-empty path starting with "/" '
        '(got "$basePath").',
      );
    }
    return (port, basePath);
  }

  /// Parses an *optional* bearer HTTP channel block → (port?, basePath).
  ///
  /// The Ollama (#27) and Anthropic (#28) channels are only configured when
  /// their section is present. Absent → `(null, defaultBasePath)` (the channel
  /// is off); present → delegates to [_parsePortAndBasePath] (the same
  /// required-port / optional-basePath contract as OpenAI). The non-null base
  /// path is harmless when the port is null — `AccessConfig` only consults it
  /// when the channel is on.
  static (int?, String) _parseOptionalChannel(
    YamlMap? node,
    String path,
    String defaultBasePath,
  ) {
    if (node == null) return (null, defaultBasePath);
    return _parsePortAndBasePath(node, path, defaultBasePath);
  }

  /// Parses `access.telegram` → (bot token, per-chat configs).
  ///
  /// The whitelist now lives under `access.users` (Q-E.24.2), so this section
  /// carries the bot token plus the per-chat session/memory namespacing
  /// `chats[]` block (`memory_session_profiles.md` § 9.1, MSP-6). A chat with
  /// no entry uses the default prefixes; the typed entries are resolved by the
  /// edge after the chat is identified (steps 10–11).
  static (String?, List<TelegramChatProfileConfig>) _parseTelegram(
    YamlMap? node,
    Map<String, String> env,
  ) {
    if (node == null) return (null, const <TelegramChatProfileConfig>[]);
    _rejectUnknownKeys(
      node,
      const <String>{'botToken', 'chats'},
      'access.telegram',
    );
    String? token = _optionalString(
      node,
      'botToken',
      'access.telegram.botToken',
    );
    if (token != null) {
      token = _expandEnv(token, env, 'access.telegram.botToken');
      if (token.isEmpty) {
        throw const AccessConfigException(
          'access.telegram.botToken must be non-empty when present.',
        );
      }
    }
    final chats = _parseTelegramChats(
      _optionalList(node, 'chats', 'access.telegram.chats'),
      env,
    );
    return (token, chats);
  }

  /// Parses `access.telegram.chats` → the per-chat session/memory namespacing
  /// entries (`memory_session_profiles.md` § 9.1).
  ///
  /// Each list entry is one [TelegramChatProfileConfig]: a required `chatId` (the
  /// Telegram chat the entry configures), an optional `principal`, the optional
  /// `sessionPrefix` / `memoryPrefix` namespace (defaulting to
  /// [defaultSessionPrefix] / [defaultMemoryPrefix], MSP-4), and the optional
  /// `defaultSession` / `defaultMemory` selectors the chat starts on
  /// (defaulting to [defaultProfileSelector]).
  static List<TelegramChatProfileConfig> _parseTelegramChats(
    YamlList? node,
    Map<String, String> env,
  ) {
    if (node == null) return const <TelegramChatProfileConfig>[];
    final chats = <TelegramChatProfileConfig>[];
    final seenChatIds = <String>{};
    for (var i = 0; i < node.length; i++) {
      final entry = node[i];
      if (entry is! YamlMap) {
        throw AccessConfigException(
          'access.telegram.chats[$i] must be a map (got ${entry.runtimeType}).',
        );
      }
      final chat = _parseTelegramChat(entry, env, 'access.telegram.chats[$i]');
      // A chat is configured exactly once; a duplicate id is a config error,
      // not a silent last-wins (mirrors `_indexTelegramChats`, but surfaced
      // here with a dotted path before `AccessConfig` is constructed).
      if (!seenChatIds.add(chat.chatId)) {
        throw AccessConfigException(
          'access.telegram.chats[$i].chatId "${chat.chatId}" is configured by '
          'more than one entry — each chat is configured once.',
        );
      }
      chats.add(chat);
    }
    return chats;
  }

  static TelegramChatProfileConfig _parseTelegramChat(
    YamlMap node,
    Map<String, String> env,
    String path,
  ) {
    _rejectUnknownKeys(
      node,
      const <String>{
        'chatId',
        'principal',
        'sessionPrefix',
        'memoryPrefix',
        'defaultSession',
        'defaultMemory',
        'defaultProfile',
      },
      path,
    );
    // The chat id is a public Telegram id: an integer scalar is coerced to its
    // decimal string, a string scalar `${ENV}`-expands like the user Telegram
    // ids (MSPP-29). The prefixes / selectors / principal are non-secret
    // namespace labels and are taken verbatim.
    final chatId = _parseChatId(node, '$path.chatId', env);
    final principal = _optionalString(node, 'principal', '$path.principal');
    final sessionPrefix =
        _optionalString(node, 'sessionPrefix', '$path.sessionPrefix') ??
            defaultSessionPrefix;
    final memoryPrefix =
        _optionalString(node, 'memoryPrefix', '$path.memoryPrefix') ??
            defaultMemoryPrefix;
    final defaultSession =
        _optionalString(node, 'defaultSession', '$path.defaultSession') ??
            defaultProfileSelector;
    final defaultMemory =
        _optionalString(node, 'defaultMemory', '$path.defaultMemory') ??
            defaultProfileSelector;
    final defaultProfile =
        _optionalString(node, 'defaultProfile', '$path.defaultProfile') ??
            defaultProfileSelector;
    try {
      return TelegramChatProfileConfig(
        chatId: chatId,
        principal: principal,
        sessionPrefix: sessionPrefix,
        memoryPrefix: memoryPrefix,
        defaultSession: defaultSession,
        defaultMemory: defaultMemory,
        defaultProfile: defaultProfile,
      );
    } on ArgumentError catch (e) {
      throw AccessConfigException('$path: ${e.message ?? e.toString()}');
    }
  }

  /// Reads a `chatId` tolerantly (schema: `["string", "integer"]`): an integer
  /// scalar is coerced to its decimal string; a string scalar `${ENV}`-expands.
  /// The resolved value is the string the registry/edge keys a chat on; an
  /// empty expanded value is rejected.
  static String _parseChatId(
    YamlMap node,
    String path,
    Map<String, String> env,
  ) {
    final raw = node['chatId'];
    if (raw == null) {
      throw AccessConfigException('$path is required.');
    }
    if (raw is int) return raw.toString();
    if (raw is! String) {
      throw AccessConfigException(
        '$path must be a string or integer (got ${raw.runtimeType}).',
      );
    }
    final expanded = _expandEnv(raw, env, path);
    if (expanded.isEmpty) {
      throw AccessConfigException('$path must be non-empty.');
    }
    return expanded;
  }

  /// Parses `access.users` → the declared humans (Q-E.24.2).
  ///
  /// Each list entry is one [AccessUser]: a stable `id` (the `principalId`),
  /// the human facts, and the per-channel credentials. The list is the
  /// single declarative identity source; [_projectUserBindings] turns it into
  /// the two runtime binding maps the resolvers consume.
  static List<AccessUser> _parseUsers(
    YamlList? node,
    Map<String, String> env,
  ) {
    if (node == null) return const <AccessUser>[];
    final users = <AccessUser>[];
    for (var i = 0; i < node.length; i++) {
      final entry = node[i];
      if (entry is! YamlMap) {
        throw AccessConfigException(
          'access.users[$i] must be a map (got ${entry.runtimeType}).',
        );
      }
      users.add(_parseUser(entry, env, 'access.users[$i]'));
    }
    return users;
  }

  static AccessUser _parseUser(
    YamlMap node,
    Map<String, String> env,
    String path,
  ) {
    _rejectUnknownKeys(
      node,
      const <String>{
        'id',
        'username',
        'numericId',
        'displayName',
        'claims',
        'telegramUserIds',
      },
      path,
    );
    final id = _requireString(node, 'id', '$path.id');
    if (id.isEmpty) {
      throw AccessConfigException('$path.id must be non-empty.');
    }
    final username = _optionalString(node, 'username', '$path.username');
    final numericId =
        _optionalInt(node, 'numericId', '$path.numericId') ?? -1;
    final displayName = _optionalString(
      node,
      'displayName',
      '$path.displayName',
    );
    final claims = _parseClaims(
      _optionalMap(node, 'claims', '$path.claims'),
      '$path.claims',
    );
    // Telegram user ids `${ENV}`-expand: the ids are public, but sourcing the
    // owner whitelist from the environment (e.g. `${TELEGRAM_TOM_BRAIN_USER}`
    // out of the shell profile) is the deployment workflow, and a literal
    // numeric id carries no `${}` so expansion is a no-op for it (Q-E.49.2:
    // the expanded value is the identity binding key).
    final telegramIds = _parseStringList(
      _optionalList(node, 'telegramUserIds', '$path.telegramUserIds'),
      '$path.telegramUserIds',
      env: env,
      expandEntries: true,
    );
    try {
      return AccessUser(
        id: id,
        username: username,
        numericId: numericId,
        displayName: displayName,
        claims: claims,
        telegramUserIds: telegramIds,
      );
    } on ArgumentError catch (e) {
      throw AccessConfigException('$path: ${e.message ?? e.toString()}');
    }
  }

  /// Projects the declared [users] onto the Telegram runtime binding map,
  /// translating the projection's [ArgumentError] (a shared user id / shared
  /// Telegram credential) into a path-prefixed [AccessConfigException].
  static Map<String, IdentityBinding> _projectUserBindings(
    List<AccessUser> users,
  ) {
    try {
      return AccessConfig.bindingsForUsers(users);
    } on ArgumentError catch (e) {
      throw AccessConfigException('access.users: ${e.message ?? e.toString()}');
    }
  }

  /// Parses `access.apiKeys` → the per-key namespacing entries
  /// (`memory_session_profiles.md` § 5.1).
  ///
  /// Each list entry is one [ApiKeyConfig]: a required secret `key` (the
  /// credential the residual token authenticates against, `${ENV}`-expanded
  /// like every other secret), an optional `principal`, the optional
  /// `sessionPrefix` / `memoryPrefix` namespace (defaulting to
  /// [defaultSessionPrefix] / [defaultMemoryPrefix], MSP-4), and an optional
  /// `displayName`. The well-known `no-key` entry (§ 6) is an ordinary entry
  /// whose key happens to be `no-key`.
  static List<ApiKeyConfig> _parseApiKeys(
    YamlList? node,
    Map<String, String> env,
  ) {
    if (node == null) return const <ApiKeyConfig>[];
    final keys = <ApiKeyConfig>[];
    for (var i = 0; i < node.length; i++) {
      final entry = node[i];
      if (entry is! YamlMap) {
        throw AccessConfigException(
          'access.apiKeys[$i] must be a map (got ${entry.runtimeType}).',
        );
      }
      keys.add(_parseApiKey(entry, env, 'access.apiKeys[$i]'));
    }
    return keys;
  }

  static ApiKeyConfig _parseApiKey(
    YamlMap node,
    Map<String, String> env,
    String path,
  ) {
    _rejectUnknownKeys(
      node,
      const <String>{
        'key',
        'principal',
        'sessionPrefix',
        'memoryPrefix',
        'displayName',
        'allowedProfiles',
        'defaultProfile',
      },
      path,
    );
    // The credential is a secret, so it `${ENV}`-expands like the user bearer
    // tokens; a literal value (e.g. `no-key`) carries no `${}` and expands to
    // itself. The principal / prefixes / displayName are non-secret namespace
    // labels and are taken verbatim (matching `AccessUser.id`).
    final key = _expandEnv(
      _requireString(node, 'key', '$path.key'),
      env,
      '$path.key',
    );
    if (key.isEmpty) {
      throw AccessConfigException('$path.key must be non-empty.');
    }
    final principal = _optionalString(node, 'principal', '$path.principal');
    final sessionPrefix =
        _optionalString(node, 'sessionPrefix', '$path.sessionPrefix') ??
            defaultSessionPrefix;
    final memoryPrefix =
        _optionalString(node, 'memoryPrefix', '$path.memoryPrefix') ??
            defaultMemoryPrefix;
    final displayName = _optionalString(node, 'displayName', '$path.displayName');
    final allowedProfiles = _parseAllowedProfiles(
      _optionalList(node, 'allowedProfiles', '$path.allowedProfiles'),
      '$path.allowedProfiles',
    );
    final defaultProfile =
        _optionalString(node, 'defaultProfile', '$path.defaultProfile');
    if (defaultProfile != null && defaultProfile.isEmpty) {
      throw AccessConfigException('$path.defaultProfile must be non-empty.');
    }
    // I-7 cross-check: a pinned `defaultProfile` must itself be permitted by a
    // declared `allowedProfiles` allowlist — otherwise a bare request on this
    // key (no explicit marker) would resolve to the pinned default and then be
    // rejected by its own allowlist, so the key could never serve a bare
    // request. Caught at load time rather than surfacing per-request.
    if (defaultProfile != null &&
        allowedProfiles != null &&
        !allowedProfiles.contains(defaultProfile)) {
      throw AccessConfigException(
        '$path.defaultProfile ("$defaultProfile") is not in this key\'s '
        'allowedProfiles allowlist; a pinned default profile must be permitted '
        'by the allowlist or the key could never serve a bare request.',
      );
    }
    try {
      return ApiKeyConfig(
        key: key,
        principal: principal,
        sessionPrefix: sessionPrefix,
        memoryPrefix: memoryPrefix,
        displayName: displayName,
        allowedProfiles: allowedProfiles,
        defaultProfile: defaultProfile,
      );
    } on ArgumentError catch (e) {
      throw AccessConfigException('$path: ${e.message ?? e.toString()}');
    }
  }

  /// Parses an optional `allowedProfiles:` list (access § 7.6, I-5) into a list
  /// of non-empty profile-id strings. An absent key yields `null`
  /// (unrestricted); a present-but-empty list yields an empty list (deny-all).
  /// A non-string or empty-string entry is a load-time config error.
  static List<String>? _parseAllowedProfiles(YamlList? node, String path) {
    if (node == null) return null;
    final result = <String>[];
    for (var i = 0; i < node.length; i++) {
      final v = node[i];
      if (v is! String) {
        throw AccessConfigException(
          '$path[$i] must be a string (got ${v.runtimeType}).',
        );
      }
      if (v.isEmpty) {
        throw AccessConfigException('$path[$i] must be non-empty.');
      }
      result.add(v);
    }
    return result;
  }

  /// Projects the [apiKeys] credentials onto the bearer-token binding map the
  /// resolver consumes (`memory_session_profiles.md` § 5.1; MSPP-61 / G-3 —
  /// `access.apiKeys[]` is now the sole source of OpenAI bearer credentials).
  ///
  /// A credential identifies exactly one principal, so a duplicate key is
  /// rejected as an [AccessConfigException] — never a silent last-wins.
  static Map<String, IdentityBinding> _projectApiKeyBindings(
    List<ApiKeyConfig> apiKeys,
  ) {
    try {
      return AccessConfig.bindingsForApiKeys(apiKeys);
    } on ArgumentError catch (e) {
      throw AccessConfigException('access.apiKeys: ${e.message ?? e.toString()}');
    }
  }

  /// Parses a list of strings, optionally `${ENV}`-expanding each entry.
  static List<String> _parseStringList(
    YamlList? node,
    String path, {
    Map<String, String> env = const {},
    bool expandEntries = false,
  }) {
    if (node == null) return const <String>[];
    final result = <String>[];
    for (var i = 0; i < node.length; i++) {
      final v = node[i];
      if (v is! String) {
        throw AccessConfigException(
          '$path[$i] must be a string (got ${v.runtimeType}).',
        );
      }
      final entry = expandEntries ? _expandEnv(v, env, '$path[$i]') : v;
      if (entry.isEmpty) {
        throw AccessConfigException('$path[$i] must be non-empty.');
      }
      result.add(entry);
    }
    return result;
  }

  /// Parses an opaque, flat-scalar claims map.
  static Map<String, Object?> _parseClaims(YamlMap? node, String path) {
    final claims = <String, Object?>{};
    if (node == null) return claims;
    for (final ck in node.keys) {
      if (ck is! String) {
        throw AccessConfigException(
          '$path keys must be strings (got ${ck.runtimeType}).',
        );
      }
      claims[ck] = _unwrapScalar(node[ck]);
    }
    return claims;
  }

  static RateLimitPolicy _parseRateLimit(YamlMap node) {
    _rejectUnknownKeys(
      node,
      const <String>{'capacity', 'refillTokens', 'refillPeriodSeconds'},
      'access.rateLimit',
    );
    final capacity = _requireInt(
      node,
      'capacity',
      'access.rateLimit.capacity',
    );
    final refillTokens = _requireDouble(
      node,
      'refillTokens',
      'access.rateLimit.refillTokens',
    );
    final refillSeconds = _requireDouble(
      node,
      'refillPeriodSeconds',
      'access.rateLimit.refillPeriodSeconds',
    );
    if (refillSeconds <= 0) {
      throw const AccessConfigException(
        'access.rateLimit.refillPeriodSeconds must be > 0.',
      );
    }
    final refillPeriod = Duration(
      microseconds: (refillSeconds * Duration.microsecondsPerSecond).round(),
    );
    try {
      return RateLimitPolicy(
        capacity: capacity,
        refillTokens: refillTokens,
        refillPeriod: refillPeriod,
      );
    } on ArgumentError catch (e) {
      throw AccessConfigException(
        'access.rateLimit: ${e.message ?? e.toString()}',
      );
    }
  }

  static DailyQuotaPolicy _parseQuota(YamlMap node) {
    _rejectUnknownKeys(node, const <String>{'dailyCap'}, 'access.quota');
    final dailyCap = _requireInt(node, 'dailyCap', 'access.quota.dailyCap');
    try {
      return DailyQuotaPolicy(dailyCap: dailyCap);
    } on ArgumentError catch (e) {
      throw AccessConfigException(
        'access.quota: ${e.message ?? e.toString()}',
      );
    }
  }

  static AnchorPolicy _parseAnchor(YamlMap? node) {
    if (node == null) {
      return AnchorPolicy(disallowedSignatures: const <String>[]);
    }
    _rejectUnknownKeys(
      node,
      const <String>{'disallowedSignatures'},
      'access.anchor',
    );
    final listNode = _optionalList(
      node,
      'disallowedSignatures',
      'access.anchor.disallowedSignatures',
    );
    final signatures = <String>[];
    if (listNode != null) {
      for (var i = 0; i < listNode.length; i++) {
        final v = listNode[i];
        if (v is! String) {
          throw AccessConfigException(
            'access.anchor.disallowedSignatures[$i] must be a string '
            '(got ${v.runtimeType}).',
          );
        }
        signatures.add(v);
      }
    }
    try {
      return AnchorPolicy(disallowedSignatures: signatures);
    } on ArgumentError catch (e) {
      throw AccessConfigException(
        'access.anchor: ${e.message ?? e.toString()}',
      );
    }
  }

  static List<String>? _parsePersonas(YamlList? node) {
    if (node == null) return null;
    final result = <String>[];
    for (var i = 0; i < node.length; i++) {
      final v = node[i];
      if (v is! String) {
        throw AccessConfigException(
          'access.personas[$i] must be a string (got ${v.runtimeType}).',
        );
      }
      if (v.isEmpty) {
        throw AccessConfigException('access.personas[$i] must be non-empty.');
      }
      result.add(v);
    }
    if (result.isEmpty) {
      throw const AccessConfigException(
        'access.personas must contain at least one persona when present '
        '(omit the key entirely for the default vocabulary).',
      );
    }
    return result;
  }

  static Duration _parseClassifier(YamlMap? node) {
    if (node == null) return const Duration(minutes: 5);
    _rejectUnknownKeys(
      node,
      const <String>{'embeddingCacheTtlSeconds'},
      'access.classifier',
    );
    final seconds = _optionalDouble(
      node,
      'embeddingCacheTtlSeconds',
      'access.classifier.embeddingCacheTtlSeconds',
    );
    if (seconds == null) return const Duration(minutes: 5);
    if (seconds <= 0) {
      throw const AccessConfigException(
        'access.classifier.embeddingCacheTtlSeconds must be > 0.',
      );
    }
    return Duration(
      microseconds: (seconds * Duration.microsecondsPerSecond).round(),
    );
  }

  /// Parses `access.edgeState` → the directory the edge limiters persist their
  /// per-principal state under (P1.4), or `null` when the section is absent
  /// (state stays in process only). The single `directory` key is a
  /// `${ENV}`-expandable string and must be non-empty when present.
  static String? _parseEdgeState(YamlMap? node, Map<String, String> env) {
    if (node == null) return null;
    _rejectUnknownKeys(node, const <String>{'directory'}, 'access.edgeState');
    final dir = _optionalString(
      node,
      'directory',
      'access.edgeState.directory',
    );
    if (dir == null) return null;
    final expanded = _expandEnv(dir, env, 'access.edgeState.directory');
    if (expanded.isEmpty) {
      throw const AccessConfigException(
        'access.edgeState.directory must be non-empty when present.',
      );
    }
    return expanded;
  }

  /// Parses `access.history` → the directory the session manager persists its
  /// conversation histories under (persistence of history, umbrella Hard
  /// principle 6), or `null` when the section is absent (histories stay in
  /// process only). The single `directory` key is a `${ENV}`-expandable string
  /// and must be non-empty when present — mirrors [_parseEdgeState].
  static String? _parseHistory(YamlMap? node, Map<String, String> env) {
    if (node == null) return null;
    _rejectUnknownKeys(node, const <String>{'directory'}, 'access.history');
    final dir = _optionalString(
      node,
      'directory',
      'access.history.directory',
    );
    if (dir == null) return null;
    final expanded = _expandEnv(dir, env, 'access.history.directory');
    if (expanded.isEmpty) {
      throw const AccessConfigException(
        'access.history.directory must be non-empty when present.',
      );
    }
    return expanded;
  }

  // ---------------------------------------------------------------
  // Field helpers. The type-coercion + `${ENV}` accessors delegate to
  // tom_core_agentic's shared `YamlConfigReader` (see `_types` below); the
  // forward-only key check and the claims-scalar unwrap are access-local
  // (they have no shared equivalent yet).
  // ---------------------------------------------------------------

  static void _rejectUnknownKeys(
    YamlMap node,
    Set<String> allowed,
    String path,
  ) {
    for (final keyDyn in node.keys) {
      if (keyDyn is! String || !allowed.contains(keyDyn)) {
        throw AccessConfigException(
          '$path has unknown key "$keyDyn"; allowed keys are '
          '${allowed.toList()}.',
        );
      }
    }
  }

  /// The type-coercion accessors now live in tom_core_agentic's
  /// [YamlConfigReader] — the consolidation of the behaviourally-identical
  /// helper block this loader, `SubstrateConfigLoader`, and
  /// `MemoryConfigLoader` each grew independently. These thin wrappers keep
  /// the loader's private vocabulary and bind the [AccessConfigException]
  /// factory so every existing call site is unchanged.
  ///
  /// `_types` carries an empty env because the coercion helpers never expand
  /// `${NAME}`; [_expandEnv] builds a per-call reader with the caller's env,
  /// matching the original signature that threads `env` through the parse
  /// tree.
  static final YamlConfigReader _types = YamlConfigReader(
    env: const {},
    errorFactory: AccessConfigException.new,
  );

  static String _requireString(YamlMap node, String key, String path) =>
      _types.requireString(node, key, path);

  static String? _optionalString(YamlMap node, String key, String path) =>
      _types.optionalString(node, key, path);

  static int _requireInt(YamlMap node, String key, String path) =>
      _types.requireInt(node, key, path);

  static int? _optionalInt(YamlMap node, String key, String path) =>
      _types.optionalInt(node, key, path);

  static double _requireDouble(YamlMap node, String key, String path) =>
      _types.requireDouble(node, key, path);

  static double? _optionalDouble(YamlMap node, String key, String path) =>
      _types.optionalDouble(node, key, path);

  // Why: the shared reader widened its return type to `Map<Object?, Object?>`
  // (so it accepts any decoded map), but indexing a `YamlMap` still yields a
  // `YamlMap`, which every caller here is typed against — the cast restores the
  // node-typed contract without re-typing the call chain.
  static YamlMap _requireMap(YamlMap node, String key, String path) =>
      _types.requireMap(node, key, path) as YamlMap;

  /// Optional map — kept local rather than delegated. The shared
  /// [YamlConfigReader.optionalMap] reports by *key* (`Field \`x\` must be a
  /// map …`); this loader's conformance contract (the "errors carry dotted
  /// key paths" suite) is that every access error names the dotted *path*, so
  /// the path-shaped message is preserved here.
  static YamlMap? _optionalMap(YamlMap node, String key, String path) {
    final v = node[key];
    if (v == null) return null;
    if (v is! YamlMap) {
      throw AccessConfigException(
        '$path must be a map (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static YamlList? _optionalList(YamlMap node, String key, String path) =>
      _types.optionalList(node, key, path) as YamlList?;

  /// Unwraps a YAML scalar into a plain Dart value for the opaque claims
  /// map. Nested maps / lists are rejected — claims are flat scalars.
  static Object? _unwrapScalar(dynamic v) {
    if (v == null || v is String || v is num || v is bool) return v;
    throw AccessConfigException(
      'claim values must be scalars (string / number / bool); got '
      '${v.runtimeType}.',
    );
  }

  // ---------------------------------------------------------------
  // `${NAME}` substitution — delegated to the shared scanner in
  // tom_core_agentic's `YamlConfigReader`. A per-call reader binds the
  // caller's env (the type-coercion `_types` reader carries an empty env),
  // matching the original signature that threads `env` through the parse
  // tree.
  // ---------------------------------------------------------------

  static String _expandEnv(
    String input,
    Map<String, String> env,
    String path,
  ) =>
      YamlConfigReader(env: env, errorFactory: AccessConfigException.new)
          .expandEnv(input, path);
}
