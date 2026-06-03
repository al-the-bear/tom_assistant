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
//     carries up to five sibling sections — `substrate:`, `memory:`,
//     `engine:`, `dispatcher:`, `access:`. This loader owns `access:` and
//     leaves the other four for their own loaders (each reads only its own
//     key). Any *other* top-level key is rejected (AC-12 forward-only) so a
//     typo'd section name never silently no-ops.
//   * Requires the `access:` block and parses every documented field.
//     Within `access:`, unknown keys are rejected at every level (AC-12).
//   * Builds the concrete edge-security policies (`RateLimitPolicy`,
//     `DailyQuotaPolicy`, `AnchorPolicy`) and the identity bindings the
//     resolvers consume — `AccessConfig` is ready-to-wire, not a raw map.
//   * Expands `${NAME}` tokens in string secrets (bearer-token keys, the
//     Telegram bot token) from the caller-supplied env map.
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

import 'package:tom_core_agentic/tom_core_agentic.dart' show YamlConfigReader;
import 'package:yaml/yaml.dart';

import '../edge_security/anchor_precheck.dart';
import '../edge_security/quota.dart';
import '../edge_security/rate_limiter.dart';
import '../identity/identity_resolver.dart';
import '../identity/session_manager.dart' show defaultMaxWindowTurns;
import 'access_config.dart';

/// Parses + materialises [AccessConfig] from the whole-process YAML.
///
/// Namespace-only class (all members static): the loader has no
/// per-instance state, mirroring `SubstrateConfigLoader`.
abstract final class AccessConfigLoader {
  AccessConfigLoader._();

  /// The top-level sections the whole-process document may carry. This
  /// loader owns [_accessKey]; the other four are owned by their own
  /// loaders (substrate / memory / engine / dispatcher) and are tolerated
  /// here so the single file feeds all five. Any other root key is
  /// rejected (AC-12).
  static const Set<String> _allowedTopLevelKeys = <String>{
    'substrate',
    'memory',
    'engine',
    'dispatcher',
    _accessKey,
  };

  static const String _accessKey = 'access';

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
    return _parseAccess(node, envVars);
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

  static AccessConfig _parseAccess(YamlMap node, Map<String, String> env) {
    _rejectUnknownKeys(
      node,
      const <String>{
        'openai',
        'telegram',
        'rateLimit',
        'quota',
        'anchor',
        'personas',
        'session',
        'classifier',
      },
      'access',
    );

    final openAi = _requireMap(node, 'openai', 'access.openai');
    final (port, basePath, bearerBindings) = _parseOpenAi(openAi, env);

    final (telegramToken, telegramBindings) = _parseTelegram(
      _optionalMap(node, 'telegram', 'access.telegram'),
      env,
    );

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
    final sessionWindow = _parseSession(
      _optionalMap(node, 'session', 'access.session'),
    );
    final cacheTtl = _parseClassifier(
      _optionalMap(node, 'classifier', 'access.classifier'),
    );

    return AccessConfig(
      openAiPort: port,
      openAiBasePath: basePath,
      telegramBotToken: telegramToken,
      bearerTokenBindings: bearerBindings,
      telegramUserIdBindings: telegramBindings,
      rateLimitPolicy: rateLimit,
      dailyQuotaPolicy: quota,
      anchorPolicy: anchor,
      personaVocabulary: personas,
      sessionMaxWindowTurns: sessionWindow,
      embeddingCacheTtl: cacheTtl,
    );
  }

  /// Parses `access.openai` → (port, basePath, bearer bindings).
  static (int, String, Map<String, IdentityBinding>) _parseOpenAi(
    YamlMap node,
    Map<String, String> env,
  ) {
    _rejectUnknownKeys(
      node,
      const <String>{'port', 'basePath', 'bearerTokens'},
      'access.openai',
    );
    final port = _requireInt(node, 'port', 'access.openai.port');
    if (port <= 0) {
      throw const AccessConfigException(
        'access.openai.port must be > 0.',
      );
    }
    final basePath = _optionalString(
          node,
          'basePath',
          'access.openai.basePath',
        ) ??
        '/v1';
    if (basePath.isEmpty || !basePath.startsWith('/')) {
      throw AccessConfigException(
        'access.openai.basePath must be a non-empty path starting with "/" '
        '(got "$basePath").',
      );
    }
    final bearer = _parseBindings(
      _optionalMap(node, 'bearerTokens', 'access.openai.bearerTokens'),
      env,
      'access.openai.bearerTokens',
      expandKey: true,
    );
    return (port, basePath, bearer);
  }

  /// Parses `access.telegram` → (bot token, user bindings).
  static (String?, Map<String, IdentityBinding>) _parseTelegram(
    YamlMap? node,
    Map<String, String> env,
  ) {
    if (node == null) return (null, const <String, IdentityBinding>{});
    _rejectUnknownKeys(
      node,
      const <String>{'botToken', 'users'},
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
    final users = _parseBindings(
      _optionalMap(node, 'users', 'access.telegram.users'),
      env,
      'access.telegram.users',
      expandKey: false,
    );
    return (token, users);
  }

  /// Parses a `key → binding` map (bearer tokens or Telegram user ids).
  ///
  /// When [expandKey] is true the key is `${ENV}`-expanded (bearer-token
  /// secrets); otherwise it is used verbatim (Telegram user ids are not
  /// secrets).
  static Map<String, IdentityBinding> _parseBindings(
    YamlMap? node,
    Map<String, String> env,
    String path, {
    required bool expandKey,
  }) {
    if (node == null) return const <String, IdentityBinding>{};
    final result = <String, IdentityBinding>{};
    for (final keyDyn in node.keys) {
      if (keyDyn is! String) {
        throw AccessConfigException(
          '$path keys must be strings (got ${keyDyn.runtimeType}).',
        );
      }
      final rawKey = keyDyn;
      final key = expandKey ? _expandEnv(rawKey, env, '$path key') : rawKey;
      if (key.isEmpty) {
        throw AccessConfigException('$path keys must be non-empty.');
      }
      final entryDyn = node[rawKey];
      if (entryDyn is! YamlMap) {
        throw AccessConfigException(
          '$path["$rawKey"] must be a map (got ${entryDyn.runtimeType}).',
        );
      }
      if (result.containsKey(key)) {
        throw AccessConfigException(
          '$path has a duplicate binding key "$key" after `\${ENV}` '
          'expansion.',
        );
      }
      result[key] = _parseBinding(entryDyn, '$path["$rawKey"]');
    }
    return result;
  }

  static IdentityBinding _parseBinding(YamlMap node, String path) {
    _rejectUnknownKeys(
      node,
      const <String>{
        'principalId',
        'username',
        'numericId',
        'displayName',
        'claims',
      },
      path,
    );
    final principalId = _requireString(
      node,
      'principalId',
      '$path.principalId',
    );
    if (principalId.isEmpty) {
      throw AccessConfigException('$path.principalId must be non-empty.');
    }
    final username = _optionalString(node, 'username', '$path.username');
    final numericId =
        _optionalInt(node, 'numericId', '$path.numericId') ?? -1;
    final displayName = _optionalString(
      node,
      'displayName',
      '$path.displayName',
    );
    final claimsNode = _optionalMap(node, 'claims', '$path.claims');
    final claims = <String, Object?>{};
    if (claimsNode != null) {
      for (final ck in claimsNode.keys) {
        if (ck is! String) {
          throw AccessConfigException(
            '$path.claims keys must be strings (got ${ck.runtimeType}).',
          );
        }
        claims[ck] = _unwrapScalar(claimsNode[ck]);
      }
    }
    return IdentityBinding(
      principalId: principalId,
      username: username,
      numericId: numericId,
      displayName: displayName,
      claims: claims,
    );
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

  static int _parseSession(YamlMap? node) {
    if (node == null) return defaultMaxWindowTurns;
    _rejectUnknownKeys(
      node,
      const <String>{'maxWindowTurns'},
      'access.session',
    );
    final turns = _optionalInt(
          node,
          'maxWindowTurns',
          'access.session.maxWindowTurns',
        ) ??
        defaultMaxWindowTurns;
    if (turns < 1) {
      throw const AccessConfigException(
        'access.session.maxWindowTurns must be >= 1.',
      );
    }
    return turns;
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

  static YamlMap _requireMap(YamlMap node, String key, String path) =>
      _types.requireMap(node, key, path);

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
      _types.optionalList(node, key, path);

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
