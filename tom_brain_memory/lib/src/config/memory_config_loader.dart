// MemoryConfigLoader — parses a `MemoryConfig` from the YAML shape
// in `memory_specification.md` § 14.
//
// Plan step A.83:
//   "Implement `MemoryConfig` YAML loader against the schema in
//    `memory_specification.md` § 14."
//
// The typed `MemoryConfig` (and its sub-records) live next door in
// `memory_config.dart` and were laid down at A.24. This file owns
// the *loader*: it converts a YAML document — usually the
// `memory:` block of a host's master config file — into a
// `MemoryConfig` the runtime can hand to `TomBrainMemory.open()`.
//
// Why a loader lives inside `tom_brain_memory` (vs. upstream):
//
//   - The spec is owned by this package. Keeping the parser next to
//     the typed model means the YAML → object contract changes in
//     one commit, not two.
//   - The same loader is reused by the test harness, the procedure
//     engine, and Tom Assistant. Three call sites is past the
//     extract-now threshold.
//   - Plan step A.83 names this package explicitly.
//
// What this file does NOT do:
//
//   - It does not read environment variables itself. Callers pass a
//     `Map<String, String>` (typically `Platform.environment`); the
//     loader substitutes `${NAME}` tokens. This keeps the loader
//     deterministic for tests and explicit about its inputs.
//   - It does not validate that paths exist on disk. That is the
//     responsibility of `TomBrainMemory.open()`, which has to handle
//     bootstrap (creating the root directory) anyway.
//   - It does not parse the `mcpServer.bearerAuthRealm` value beyond
//     a non-empty-string check; the realm is opaque to memory.
//   - It does not embed any default file location. Callers pass an
//     absolute path or pre-loaded string content.

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:yaml/yaml.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        BudgetsConfig,
        ClassificationConfig,
        DefaultWriteBudgetConfig,
        McpServerConfig,
        MemoryConfig,
        ReplicationConfig,
        ReplicationRole,
        RetrievalConfig,
        SqliteVecConfig,
        TrailsConfig;

/// Thrown when the YAML document does not match the schema in
/// `memory_specification.md` § 14.
///
/// Messages always identify the offending key path (e.g.
/// `memory.retrieval.rrf.k`) so the YAML location is obvious to an
/// engineer reading the error.
class MemoryConfigException implements Exception {
  /// Human-readable explanation, prefixed with the dotted YAML key
  /// path when the failure is field-local.
  final String message;

  const MemoryConfigException(this.message);

  @override
  String toString() => 'MemoryConfigException: $message';
}

/// Parses + materialises `MemoryConfig` from YAML.
///
/// Namespace-only class (all members static): the loader has no
/// per-instance state.
abstract final class MemoryConfigLoader {
  MemoryConfigLoader._();

  /// Parses the YAML [content] and returns the typed config.
  ///
  /// The YAML document must have a top-level `memory:` key whose
  /// value is the configuration map (matching § 14 of the spec).
  /// [envVars] is consulted to expand `${NAME}` tokens inside any
  /// string value; unknown tokens raise [MemoryConfigException].
  ///
  /// Pure: no I/O, no clock. Tests reach it directly with hand-rolled
  /// YAML strings.
  static MemoryConfig parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final dynamic doc;
    try {
      doc = loadYaml(content);
    } on YamlException catch (e) {
      throw MemoryConfigException('YAML parse failed: ${e.message}');
    }
    if (doc is! YamlMap) {
      throw const MemoryConfigException(
        'Config root must be a YAML map (got a non-map document).',
      );
    }
    final dynamic memoryNode = doc['memory'];
    if (memoryNode is! YamlMap) {
      throw const MemoryConfigException(
        'Missing top-level `memory:` map.',
      );
    }
    return _parseMemory(memoryNode, envVars);
  }

  /// Loads the YAML file at [path] and parses it via [parse].
  ///
  /// Convenience wrapper. Production callers usually go through this
  /// entry point; the test suite uses [parse] with inline content.
  static MemoryConfig loadFromFile(
    String path, {
    Map<String, String> envVars = const {},
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      throw MemoryConfigException(
        'Config file not found: $path',
      );
    }
    final content = file.readAsStringSync();
    return parse(content, envVars: envVars);
  }

  // ---------------------------------------------------------------
  // Section parsers. Each one consumes its YAML map fragment and
  // returns the typed record. Missing optional sections fall back to
  // the typed record's own defaults — the loader does not embed a
  // second source of truth.
  // ---------------------------------------------------------------

  static MemoryConfig _parseMemory(
    YamlMap node,
    Map<String, String> env,
  ) {
    final rootRaw = _requireString(node, 'root', 'memory.root');
    final root = _expandEnv(rootRaw, env, 'memory.root');

    final sqliteVecNode = _requireMap(
      node,
      'sqliteVec',
      'memory.sqliteVec',
    );
    final sqliteVec = _parseSqliteVec(sqliteVecNode, env);

    final retrieval = _parseRetrieval(
      _optionalMap(node, 'retrieval'),
    );
    final trails = _parseTrails(_optionalMap(node, 'trails'));
    final classification = _parseClassification(
      _optionalMap(node, 'classification'),
    );
    final budgets = _parseBudgets(_optionalMap(node, 'budgets'));
    final mcpServer = _parseMcpServer(
      _optionalMap(node, 'mcpServer'),
      env,
    );
    final replication = _parseReplication(
      _optionalMap(node, 'replication'),
      env,
    );

    return MemoryConfig(
      root: root,
      sqliteVec: sqliteVec,
      retrieval: retrieval,
      trails: trails,
      classification: classification,
      budgets: budgets,
      mcpServer: mcpServer,
      replication: replication,
    );
  }

  static SqliteVecConfig _parseSqliteVec(
    YamlMap node,
    Map<String, String> env,
  ) {
    // Either `extensionPath` (explicit binary) or `binariesRoot`
    // (the in-quest `tom_binaries/sqlite_vec/` tree, resolved per
    // platform by the loader) may be given; at least one is required so
    // the brain can boot vector mode (Q-A.6.1 — no BM25-only fallback).
    final extRaw = _optionalString(
      node,
      'extensionPath',
      'memory.sqliteVec.extensionPath',
    );
    final ext = extRaw == null
        ? ''
        : _expandEnv(extRaw, env, 'memory.sqliteVec.extensionPath');

    final rootRaw = _optionalString(
      node,
      'binariesRoot',
      'memory.sqliteVec.binariesRoot',
    );
    final binariesRoot = rootRaw == null
        ? ''
        : _expandEnv(rootRaw, env, 'memory.sqliteVec.binariesRoot');

    if (ext.isEmpty && binariesRoot.isEmpty) {
      throw const MemoryConfigException(
        'memory.sqliteVec requires `extensionPath` or `binariesRoot` '
        '(vector search is mandatory; there is no BM25-only fallback).',
      );
    }
    return SqliteVecConfig(extensionPath: ext, binariesRoot: binariesRoot);
  }

  static RetrievalConfig _parseRetrieval(YamlMap? node) {
    if (node == null) return const RetrievalConfig();
    var rrfK = 60;
    var mmrLambda = 0.7;
    final rrf = _optionalMap(node, 'rrf');
    if (rrf != null) {
      rrfK = _optionalInt(
            rrf,
            'k',
            'memory.retrieval.rrf.k',
          ) ??
          rrfK;
      if (rrfK <= 0) {
        throw const MemoryConfigException(
          'memory.retrieval.rrf.k must be > 0.',
        );
      }
    }
    final mmr = _optionalMap(node, 'mmr');
    if (mmr != null) {
      mmrLambda = _optionalDouble(
            mmr,
            'lambda',
            'memory.retrieval.mmr.lambda',
          ) ??
          mmrLambda;
      if (mmrLambda < 0.0 || mmrLambda > 1.0) {
        throw const MemoryConfigException(
          'memory.retrieval.mmr.lambda must be in [0, 1].',
        );
      }
    }
    return RetrievalConfig(rrfK: rrfK, mmrLambda: mmrLambda);
  }

  static TrailsConfig _parseTrails(YamlMap? node) {
    if (node == null) return const TrailsConfig();
    final fsync = _optionalBool(
          node,
          'fsyncEveryAppend',
          'memory.trails.fsyncEveryAppend',
        ) ??
        true;
    final compressDays = _optionalInt(
          node,
          'compressAfterDays',
          'memory.trails.compressAfterDays',
        ) ??
        7;
    if (compressDays < 0) {
      throw const MemoryConfigException(
        'memory.trails.compressAfterDays must be >= 0.',
      );
    }
    final coldDays = _optionalInt(
          node,
          'coldStorageAfterDays',
          'memory.trails.coldStorageAfterDays',
        ) ??
        90;
    if (coldDays < 0) {
      throw const MemoryConfigException(
        'memory.trails.coldStorageAfterDays must be >= 0.',
      );
    }
    if (coldDays < compressDays) {
      throw const MemoryConfigException(
        'memory.trails.coldStorageAfterDays must be >= '
        'compressAfterDays.',
      );
    }
    return TrailsConfig(
      fsyncEveryAppend: fsync,
      compressAfter: Duration(days: compressDays),
      coldStorageAfter: Duration(days: coldDays),
    );
  }

  static ClassificationConfig _parseClassification(YamlMap? node) {
    if (node == null) return const ClassificationConfig();
    final minConf = _optionalDouble(
          node,
          'minConfidence',
          'memory.classification.minConfidence',
        ) ??
        0.55;
    if (minConf < 0.0 || minConf > 1.0) {
      throw const MemoryConfigException(
        'memory.classification.minConfidence must be in [0, 1].',
      );
    }
    final minMargin = _optionalDouble(
          node,
          'minMargin',
          'memory.classification.minMargin',
        ) ??
        0.05;
    if (minMargin < 0.0 || minMargin > 1.0) {
      throw const MemoryConfigException(
        'memory.classification.minMargin must be in [0, 1].',
      );
    }
    final coldStart = _optionalInt(
          node,
          'coldStartMinExamples',
          'memory.classification.coldStartMinExamples',
        ) ??
        8;
    if (coldStart < 0) {
      throw const MemoryConfigException(
        'memory.classification.coldStartMinExamples must be >= 0.',
      );
    }
    return ClassificationConfig(
      minConfidence: minConf,
      minMargin: minMargin,
      coldStartMinExamples: coldStart,
    );
  }

  static BudgetsConfig _parseBudgets(YamlMap? node) {
    if (node == null) return const BudgetsConfig();
    final dwbNode = _optionalMap(node, 'defaultWriteBudget');
    if (dwbNode == null) return const BudgetsConfig();
    final maxNodes = _optionalInt(
          dwbNode,
          'maxNodes',
          'memory.budgets.defaultWriteBudget.maxNodes',
        ) ??
        5000;
    final maxEdges = _optionalInt(
          dwbNode,
          'maxEdges',
          'memory.budgets.defaultWriteBudget.maxEdges',
        ) ??
        20000;
    final maxStack = _optionalInt(
          dwbNode,
          'maxStackEntries',
          'memory.budgets.defaultWriteBudget.maxStackEntries',
        ) ??
        1000;
    for (final pair in [
      ('maxNodes', maxNodes),
      ('maxEdges', maxEdges),
      ('maxStackEntries', maxStack),
    ]) {
      if (pair.$2 < 0) {
        throw MemoryConfigException(
          'memory.budgets.defaultWriteBudget.${pair.$1} must be >= 0.',
        );
      }
    }
    return BudgetsConfig(
      defaultWriteBudget: DefaultWriteBudgetConfig(
        maxNodes: maxNodes,
        maxEdges: maxEdges,
        maxStackEntries: maxStack,
      ),
    );
  }

  static McpServerConfig _parseMcpServer(
    YamlMap? node,
    Map<String, String> env,
  ) {
    if (node == null) return const McpServerConfig();
    final enabled = _optionalBool(
          node,
          'enabled',
          'memory.mcpServer.enabled',
        ) ??
        false;
    String? bindAddress;
    int? bindPort;
    final bindRaw = _optionalString(
      node,
      'bind',
      'memory.mcpServer.bind',
    );
    if (bindRaw != null) {
      final bind = _expandEnv(bindRaw, env, 'memory.mcpServer.bind');
      final parts = _splitBind(bind);
      bindAddress = parts.$1;
      bindPort = parts.$2;
    }
    final realm = _optionalString(
      node,
      'bearerAuthRealm',
      'memory.mcpServer.bearerAuthRealm',
    );
    if (realm != null && realm.isEmpty) {
      throw const MemoryConfigException(
        'memory.mcpServer.bearerAuthRealm must be non-empty when set.',
      );
    }
    if (enabled && (bindAddress == null || bindPort == null)) {
      throw const MemoryConfigException(
        'memory.mcpServer.bind is required when '
        'memory.mcpServer.enabled is true.',
      );
    }
    return McpServerConfig(
      enabled: enabled,
      bindAddress: bindAddress,
      bindPort: bindPort,
      bearerAuthRealm: realm,
    );
  }

  static ReplicationConfig _parseReplication(
    YamlMap? node,
    Map<String, String> env,
  ) {
    if (node == null) return const ReplicationConfig();
    final roleRaw = _optionalString(
      node,
      'role',
      'memory.replication.role',
    );
    final role = roleRaw == null
        ? ReplicationRole.authority
        : _parseRole(roleRaw);
    final writeLogRaw = _optionalString(
      node,
      'writeLogDir',
      'memory.replication.writeLogDir',
    );
    final writeLog = writeLogRaw == null
        ? null
        : _expandEnv(
            writeLogRaw,
            env,
            'memory.replication.writeLogDir',
          );
    final endpointRaw = _optionalString(
      node,
      'authorityEndpoint',
      'memory.replication.authorityEndpoint',
    );
    final endpoint = endpointRaw == null
        ? null
        : _expandEnv(
            endpointRaw,
            env,
            'memory.replication.authorityEndpoint',
          );

    // Topology consistency: authority needs writeLogDir; worker /
    // mirror need authorityEndpoint. The spec is explicit at § 10.
    switch (role) {
      case ReplicationRole.authority:
        if (writeLog == null) {
          throw const MemoryConfigException(
            'memory.replication.writeLogDir is required when '
            'role is `authority`.',
          );
        }
        if (endpoint != null) {
          throw const MemoryConfigException(
            'memory.replication.authorityEndpoint must be unset '
            'when role is `authority`.',
          );
        }
      case ReplicationRole.worker:
      case ReplicationRole.mirror:
        if (endpoint == null) {
          throw MemoryConfigException(
            'memory.replication.authorityEndpoint is required when '
            'role is `${role.name}`.',
          );
        }
        if (writeLog != null) {
          throw MemoryConfigException(
            'memory.replication.writeLogDir must be unset when '
            'role is `${role.name}`.',
          );
        }
    }
    return ReplicationConfig(
      role: role,
      writeLogDir: writeLog,
      authorityEndpoint: endpoint,
    );
  }

  static ReplicationRole _parseRole(String raw) {
    switch (raw) {
      case 'authority':
        return ReplicationRole.authority;
      case 'worker':
        return ReplicationRole.worker;
      case 'mirror':
        return ReplicationRole.mirror;
      default:
        throw MemoryConfigException(
          'memory.replication.role must be one of '
          '`authority`, `worker`, `mirror` (got `$raw`).',
        );
    }
  }

  // ---------------------------------------------------------------
  // Type-safe field helpers + `${NAME}` substitution now live in
  // tom_core_agentic's `YamlConfigReader`. These thin wrappers keep
  // the loader's private vocabulary and bind the
  // `MemoryConfigException` factory, so every existing call site is
  // unchanged. The shared reader is the consolidation of the
  // behaviourally-identical helper block this loader and the substrate
  // loader grew independently.
  //
  // `_types` carries an empty env because the type-coercion helpers
  // never expand `${NAME}`; `_expandEnv` builds a per-call reader with
  // the caller's env, matching the original signature that threads
  // `env` through the parse tree.
  // ---------------------------------------------------------------

  static final YamlConfigReader _types = YamlConfigReader(
    env: const {},
    errorFactory: MemoryConfigException.new,
  );

  static String _requireString(YamlMap node, String key, String path) =>
      _types.requireString(node, key, path);

  static String? _optionalString(YamlMap node, String key, String path) =>
      _types.optionalString(node, key, path);

  static int? _optionalInt(YamlMap node, String key, String path) =>
      _types.optionalInt(node, key, path);

  static double? _optionalDouble(YamlMap node, String key, String path) =>
      _types.optionalDouble(node, key, path);

  static bool? _optionalBool(YamlMap node, String key, String path) =>
      _types.optionalBool(node, key, path);

  static YamlMap _requireMap(YamlMap node, String key, String path) =>
      _types.requireMap(node, key, path);

  static YamlMap? _optionalMap(YamlMap node, String key) =>
      _types.optionalMap(node, key);

  static String _expandEnv(String input, Map<String, String> env, String path) =>
      YamlConfigReader(env: env, errorFactory: MemoryConfigException.new)
          .expandEnv(input, path);

  // ---------------------------------------------------------------
  // `host:port` splitter. Accepts IPv4 / hostname forms. IPv6 is
  // not supported by the prototype gateway — A.83 stays consistent
  // with the spec's example (`127.0.0.1:8841`).
  // ---------------------------------------------------------------

  static (String, int) _splitBind(String raw) {
    final idx = raw.lastIndexOf(':');
    if (idx <= 0 || idx == raw.length - 1) {
      throw MemoryConfigException(
        'memory.mcpServer.bind must be `host:port` (got `$raw`).',
      );
    }
    final host = raw.substring(0, idx);
    final portStr = raw.substring(idx + 1);
    final port = int.tryParse(portStr);
    if (port == null || port <= 0 || port > 65535) {
      throw MemoryConfigException(
        'memory.mcpServer.bind has invalid port `$portStr`.',
      );
    }
    return (host, port);
  }
}
