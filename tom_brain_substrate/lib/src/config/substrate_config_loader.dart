// B.36 — `SubstrateConfigLoader`: parses a `SubstrateConfig` from
// the YAML shape in `substrate_specification.md` § 9.
//
// Modelled on `tom_brain_memory`'s `MemoryConfigLoader` (A.83):
// same `loadYaml` + `YamlMap` plumbing, same dotted-key-path
// error messages, same `${ENV}` substitution for string-valued
// fields, same "no I/O until `loadFromFile`" discipline.
//
// What the loader does:
//
//   * Parses the top-level `substrate:` block (any other root key
//     produces a clear error). All sections under `substrate:` are
//     optional except `providers`, `roleRoutes`, and `embedding`
//     (the spec's § 9 example has them all present, but the loader
//     accepts the minimum needed to construct a working router).
//   * Builds typed values for every documented field. Each section
//     parser carries the dotted YAML key path so errors point at
//     the offending location.
//   * Validates cross-section invariants:
//       - Provider ids unique across `providers`.
//       - Provider auth shape matches the kind
//         (`api_key` requires either inline `token:` or
//         `secretRef:`; mutually exclusive; never both).
//       - Every `roleRoutes` entry references a provider that
//         exists and a model that provider advertises.
//       - `embedding.providerId` exists and advertises
//         `embedding.model`.
//       - `webSearch.defaultProvider` is one of
//         `webSearch.providers`.
//       - Each MCP endpoint has the right per-transport keys
//         (stdio requires `command:`; http requires `url:`); stdio
//         with any auth other than `none` is rejected at load
//         time (matches the B.34 `McpAuthResolver` invariant).
//       - `priceTable` keys are `providerId/modelId` pairs that
//         match a configured provider + model.
//
// What the loader does NOT do:
//
//   * It does not read environment variables on its own. Callers
//     pass a `Map<String, String>` (typically `Platform.environment`);
//     the loader substitutes `${NAME}` tokens. This keeps the loader
//     deterministic for tests and explicit about its inputs (same
//     posture as `MemoryConfigLoader`).
//   * It does not read secret files. `secretRef:` strings are
//     carried verbatim into the typed model; the facade (B.40)
//     reads them at boot through a resolver. Mirrors the B.34
//     `McpAuthResolver` posture.
//   * It does not embed any default file location. Callers pass
//     an absolute path to `loadFromFile`, or hand pre-loaded YAML
//     content to `parse`.
//   * It does not validate "every registered role has a route".
//     That symmetric check is intentionally not enforced (see
//     `SubstrateConfig.validateRoleRegistry`).
//
// Folder location (Q-B.9.5): same as `substrate_config.dart` —
// `lib/src/config/`. Mirrors memory's `MemoryConfigLoader` placement.

import 'dart:io';

import 'package:yaml/yaml.dart';

import '../mcp_client/mcp_auth.dart' show McpAuthConfig;
import 'substrate_config.dart';

/// Parses + materialises [SubstrateConfig] from YAML.
///
/// Namespace-only class (all members static): the loader has no
/// per-instance state.
abstract final class SubstrateConfigLoader {
  SubstrateConfigLoader._();

  /// Parses the YAML [content] and returns the typed config.
  ///
  /// The YAML document must have a top-level `substrate:` key
  /// whose value is the configuration map (matching § 9 of the
  /// spec). [envVars] is consulted to expand `${NAME}` tokens
  /// inside any string value; unknown tokens raise
  /// [SubstrateConfigException].
  ///
  /// Pure: no I/O, no clock. Tests reach it directly with
  /// hand-rolled YAML strings.
  static SubstrateConfig parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final dynamic doc;
    try {
      doc = loadYaml(content);
    } on YamlException catch (e) {
      throw SubstrateConfigException(
        'YAML parse failed: ${e.message}',
      );
    }
    if (doc is! YamlMap) {
      throw const SubstrateConfigException(
        'Config root must be a YAML map (got a non-map document).',
      );
    }
    final dynamic node = doc['substrate'];
    if (node is! YamlMap) {
      throw const SubstrateConfigException(
        'Missing top-level `substrate:` map.',
      );
    }
    return _parseSubstrate(node, envVars);
  }

  /// Loads the YAML file at [path] and parses it via [parse].
  ///
  /// Production callers usually go through this entry point; the
  /// test suite uses [parse] with inline content.
  static SubstrateConfig loadFromFile(
    String path, {
    Map<String, String> envVars = const {},
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      throw SubstrateConfigException('Config file not found: $path');
    }
    final content = file.readAsStringSync();
    return parse(content, envVars: envVars);
  }

  // ---------------------------------------------------------------
  // Section parsers.
  // ---------------------------------------------------------------

  static SubstrateConfig _parseSubstrate(
    YamlMap node,
    Map<String, String> env,
  ) {
    final providersNode = _requireList(
      node,
      'providers',
      'substrate.providers',
    );
    final providers = _parseProviders(providersNode, env);

    final routesNode = _requireMap(
      node,
      'roleRoutes',
      'substrate.roleRoutes',
    );
    final roleRoutes = _parseRoleRoutes(routesNode);

    final embeddingNode = _requireMap(
      node,
      'embedding',
      'substrate.embedding',
    );
    final embedding = _parseEmbedding(embeddingNode);

    final webSearch = _parseWebSearch(
      _optionalMap(node, 'webSearch'),
      env,
    );
    final webFetch = _parseWebFetch(
      _optionalMap(node, 'webFetch'),
      env,
    );
    final mcpClient = _parseMcpClient(
      _optionalMap(node, 'mcpClient'),
      env,
    );
    final priceTable = _parsePriceTable(
      _optionalMap(node, 'priceTable'),
    );

    // Cross-section validation. The individual parsers have
    // already enforced within-section invariants (e.g. inline /
    // secretRef mutual exclusion); this block enforces the
    // cross-references the loader-as-a-whole owns.
    _crossValidate(
      providers: providers,
      roleRoutes: roleRoutes,
      embedding: embedding,
      webSearch: webSearch,
      priceTable: priceTable,
    );

    return SubstrateConfig(
      providers: providers,
      roleRoutes: roleRoutes,
      embedding: embedding,
      webSearch: webSearch,
      webFetch: webFetch,
      mcpClient: mcpClient,
      priceTable: priceTable,
    );
  }

  static List<ProviderProfile> _parseProviders(
    YamlList node,
    Map<String, String> env,
  ) {
    final result = <ProviderProfile>[];
    final seenIds = <String>{};
    for (var i = 0; i < node.length; i++) {
      final entry = node[i];
      if (entry is! YamlMap) {
        throw SubstrateConfigException(
          'substrate.providers[$i] must be a map (got ${entry.runtimeType}).',
        );
      }
      final id = _requireString(
        entry,
        'id',
        'substrate.providers[$i].id',
      );
      if (id.isEmpty) {
        throw SubstrateConfigException(
          'substrate.providers[$i].id must be non-empty.',
        );
      }
      if (!seenIds.add(id)) {
        throw SubstrateConfigException(
          'substrate.providers[$i].id "$id" is a duplicate; provider '
          'ids must be unique across the providers list.',
        );
      }
      final kindRaw = _requireString(
        entry,
        'kind',
        'substrate.providers[$i].kind',
      );
      final kind = _parseProviderKind(
        kindRaw,
        'substrate.providers[$i].kind',
      );

      final baseUrlRaw = _optionalString(
        entry,
        'baseUrl',
        'substrate.providers[$i].baseUrl',
      );
      Uri? baseUrl;
      if (baseUrlRaw != null) {
        final expanded = _expandEnv(
          baseUrlRaw,
          env,
          'substrate.providers[$i].baseUrl',
        );
        baseUrl = _parseUri(
          expanded,
          'substrate.providers[$i].baseUrl',
        );
      }
      // Stub providers have no baseUrl; ollama / openai require one.
      if (kind != ProviderKind.stub && baseUrl == null) {
        throw SubstrateConfigException(
          'substrate.providers[$i] (kind=${kind.name}) requires `baseUrl`.',
        );
      }

      final auth = _parseProviderAuth(
        _optionalMap(entry, 'auth'),
        env,
        'substrate.providers[$i].auth',
      );

      // Stub providers ignore auth (always `none`); reject any
      // declared auth to keep the schema honest.
      if (kind == ProviderKind.stub && !auth.isNone) {
        throw SubstrateConfigException(
          'substrate.providers[$i] (kind=stub) must declare `auth: '
          '{method: none}` (or omit `auth:` entirely).',
        );
      }

      final modelsNode = _optionalList(
        entry,
        'models',
        'substrate.providers[$i].models',
      );
      final models = <String>[];
      if (modelsNode != null) {
        for (var j = 0; j < modelsNode.length; j++) {
          final m = modelsNode[j];
          if (m is! String) {
            throw SubstrateConfigException(
              'substrate.providers[$i].models[$j] must be a string '
              '(got ${m.runtimeType}).',
            );
          }
          if (m.isEmpty) {
            throw SubstrateConfigException(
              'substrate.providers[$i].models[$j] must be non-empty.',
            );
          }
          models.add(m);
        }
      }
      // Stub providers may legitimately have no models declared
      // (the test harness binds its own); every other kind needs
      // at least one for `roleRoutes` cross-validation to work.
      if (kind != ProviderKind.stub && models.isEmpty) {
        throw SubstrateConfigException(
          'substrate.providers[$i] (kind=${kind.name}) must declare at '
          'least one `models:` entry.',
        );
      }

      result.add(
        ProviderProfile(
          id: id,
          kind: kind,
          baseUrl: baseUrl,
          auth: auth,
          models: List<String>.unmodifiable(models),
        ),
      );
    }
    if (result.isEmpty) {
      throw const SubstrateConfigException(
        'substrate.providers must contain at least one provider.',
      );
    }
    return List<ProviderProfile>.unmodifiable(result);
  }

  static ProviderKind _parseProviderKind(String raw, String path) {
    switch (raw) {
      case 'ollama':
        return ProviderKind.ollama;
      case 'openai':
        return ProviderKind.openai;
      case 'stub':
        return ProviderKind.stub;
      default:
        throw SubstrateConfigException(
          '$path must be one of `ollama`, `openai`, `stub` '
          '(got "$raw").',
        );
    }
  }

  static ProviderAuthConfig _parseProviderAuth(
    YamlMap? node,
    Map<String, String> env,
    String path,
  ) {
    if (node == null) return ProviderAuthConfig.none;
    final method = _requireString(node, 'method', '$path.method');
    switch (method) {
      case 'none':
        // Reject stray keys under `auth: {method: none}` so a
        // typo'd `secretRef:` is not silently ignored.
        if (node.length > 1) {
          throw SubstrateConfigException(
            '$path.method=none must not declare additional keys '
            '(got: ${node.keys.toList()}).',
          );
        }
        return ProviderAuthConfig.none;
      case 'api_key':
        String? token = _optionalString(
          node,
          'token',
          '$path.token',
        );
        if (token != null) {
          token = _expandEnv(token, env, '$path.token');
        }
        String? secretRef = _optionalString(
          node,
          'secretRef',
          '$path.secretRef',
        );
        if (secretRef != null) {
          secretRef = _expandEnv(secretRef, env, '$path.secretRef');
        }
        try {
          return ProviderAuthConfig.apiKey(
            token: token,
            secretRef: secretRef,
          );
        } on ArgumentError catch (e) {
          // Re-throw with the dotted key path so loader callers
          // see a `substrate.providers[i].auth` path instead of a
          // raw `ProviderAuthConfig.apiKey ...` message.
          throw SubstrateConfigException(
            '$path: ${e.message ?? e.toString()}',
          );
        }
      default:
        throw SubstrateConfigException(
          '$path.method must be one of `none`, `api_key` '
          '(got "$method").',
        );
    }
  }

  static Map<String, List<RoleRouteEntryConfig>> _parseRoleRoutes(
    YamlMap node,
  ) {
    final result = <String, List<RoleRouteEntryConfig>>{};
    for (final keyDyn in node.keys) {
      if (keyDyn is! String) {
        throw SubstrateConfigException(
          'substrate.roleRoutes keys must be strings '
          '(got ${keyDyn.runtimeType}).',
        );
      }
      final roleId = keyDyn;
      if (roleId.isEmpty) {
        throw const SubstrateConfigException(
          'substrate.roleRoutes keys must be non-empty.',
        );
      }
      final listNode = node[roleId];
      if (listNode is! YamlList) {
        throw SubstrateConfigException(
          'substrate.roleRoutes.$roleId must be a list '
          '(got ${listNode.runtimeType}).',
        );
      }
      final entries = <RoleRouteEntryConfig>[];
      for (var i = 0; i < listNode.length; i++) {
        final raw = listNode[i];
        if (raw is! YamlMap) {
          throw SubstrateConfigException(
            'substrate.roleRoutes.$roleId[$i] must be a map '
            '(got ${raw.runtimeType}).',
          );
        }
        final providerId = _requireString(
          raw,
          'providerId',
          'substrate.roleRoutes.$roleId[$i].providerId',
        );
        if (providerId.isEmpty) {
          throw SubstrateConfigException(
            'substrate.roleRoutes.$roleId[$i].providerId must be '
            'non-empty.',
          );
        }
        final model = _requireString(
          raw,
          'model',
          'substrate.roleRoutes.$roleId[$i].model',
        );
        if (model.isEmpty) {
          throw SubstrateConfigException(
            'substrate.roleRoutes.$roleId[$i].model must be non-empty.',
          );
        }
        final conditionsNode = _optionalMap(raw, 'conditions');
        RouteConditionsConfig? conditions;
        if (conditionsNode != null) {
          final maxIn = _optionalInt(
            conditionsNode,
            'maxInputTokens',
            'substrate.roleRoutes.$roleId[$i].conditions.maxInputTokens',
          );
          if (maxIn != null && maxIn < 0) {
            throw SubstrateConfigException(
              'substrate.roleRoutes.$roleId[$i].conditions.'
              'maxInputTokens must be >= 0.',
            );
          }
          conditions = RouteConditionsConfig(maxInputTokens: maxIn);
        }
        entries.add(
          RoleRouteEntryConfig(
            providerId: providerId,
            model: model,
            conditions: conditions,
          ),
        );
      }
      // An empty list is rejected: the router would surface every
      // dispatch to this role as `NoRouteAvailable` immediately,
      // which is almost never what the operator meant.
      if (entries.isEmpty) {
        throw SubstrateConfigException(
          'substrate.roleRoutes.$roleId must contain at least one '
          'route entry (an empty chain produces immediate '
          '`NoRouteAvailable` on every dispatch).',
        );
      }
      result[roleId] = List<RoleRouteEntryConfig>.unmodifiable(entries);
    }
    if (result.isEmpty) {
      throw const SubstrateConfigException(
        'substrate.roleRoutes must contain at least one role.',
      );
    }
    return Map<String, List<RoleRouteEntryConfig>>.unmodifiable(result);
  }

  static EmbeddingChoice _parseEmbedding(YamlMap node) {
    final providerId = _requireString(
      node,
      'providerId',
      'substrate.embedding.providerId',
    );
    if (providerId.isEmpty) {
      throw const SubstrateConfigException(
        'substrate.embedding.providerId must be non-empty.',
      );
    }
    final model = _requireString(
      node,
      'model',
      'substrate.embedding.model',
    );
    if (model.isEmpty) {
      throw const SubstrateConfigException(
        'substrate.embedding.model must be non-empty.',
      );
    }
    final dims = _requireInt(
      node,
      'dims',
      'substrate.embedding.dims',
    );
    if (dims <= 0) {
      throw const SubstrateConfigException(
        'substrate.embedding.dims must be > 0.',
      );
    }
    final normalize = _optionalBool(
          node,
          'normalize',
          'substrate.embedding.normalize',
        ) ??
        true;
    return EmbeddingChoice(
      providerId: providerId,
      model: model,
      dims: dims,
      normalize: normalize,
    );
  }

  static WebSearchConfig _parseWebSearch(
    YamlMap? node,
    Map<String, String> env,
  ) {
    if (node == null) {
      // No webSearch block ⇒ DuckDuckGo HTML default (matches
      // spec § 9 example).
      return const WebSearchConfig(
        defaultProvider: 'duckduckgo',
        providers: {
          'duckduckgo': WebSearchProviderConfig(kind: 'ddg_html'),
        },
      );
    }
    final defaultProvider = _requireString(
      node,
      'defaultProvider',
      'substrate.webSearch.defaultProvider',
    );
    if (defaultProvider.isEmpty) {
      throw const SubstrateConfigException(
        'substrate.webSearch.defaultProvider must be non-empty.',
      );
    }
    final providersNode = _requireMap(
      node,
      'providers',
      'substrate.webSearch.providers',
    );
    final providers = <String, WebSearchProviderConfig>{};
    for (final keyDyn in providersNode.keys) {
      if (keyDyn is! String) {
        throw SubstrateConfigException(
          'substrate.webSearch.providers keys must be strings '
          '(got ${keyDyn.runtimeType}).',
        );
      }
      final name = keyDyn;
      final entryNode = providersNode[name];
      if (entryNode is! YamlMap) {
        throw SubstrateConfigException(
          'substrate.webSearch.providers.$name must be a map '
          '(got ${entryNode.runtimeType}).',
        );
      }
      final kind = _requireString(
        entryNode,
        'kind',
        'substrate.webSearch.providers.$name.kind',
      );
      if (kind.isEmpty) {
        throw SubstrateConfigException(
          'substrate.webSearch.providers.$name.kind must be non-empty.',
        );
      }
      final auth = _parseProviderAuth(
        _optionalMap(entryNode, 'auth'),
        env,
        'substrate.webSearch.providers.$name.auth',
      );
      providers[name] = WebSearchProviderConfig(kind: kind, auth: auth);
    }
    if (providers.isEmpty) {
      throw const SubstrateConfigException(
        'substrate.webSearch.providers must contain at least one entry.',
      );
    }
    if (!providers.containsKey(defaultProvider)) {
      throw SubstrateConfigException(
        'substrate.webSearch.defaultProvider "$defaultProvider" is not '
        'one of the configured providers (known: ${providers.keys.toList()}).',
      );
    }
    return WebSearchConfig(
      defaultProvider: defaultProvider,
      providers: Map<String, WebSearchProviderConfig>.unmodifiable(providers),
    );
  }

  static WebFetchConfig _parseWebFetch(
    YamlMap? node,
    Map<String, String> env,
  ) {
    if (node == null) return const WebFetchConfig();
    final budget = _optionalInt(
          node,
          'defaultBudgetBytes',
          'substrate.webFetch.defaultBudgetBytes',
        ) ??
        262144;
    if (budget <= 0) {
      throw const SubstrateConfigException(
        'substrate.webFetch.defaultBudgetBytes must be > 0.',
      );
    }
    final uaRaw = _optionalString(
          node,
          'userAgent',
          'substrate.webFetch.userAgent',
        ) ??
        'TomBrain/0.1 (+https://tom-brain.local)';
    final ua = _expandEnv(uaRaw, env, 'substrate.webFetch.userAgent');
    if (ua.isEmpty) {
      throw const SubstrateConfigException(
        'substrate.webFetch.userAgent must be non-empty.',
      );
    }
    return WebFetchConfig(
      defaultBudgetBytes: budget,
      userAgent: ua,
    );
  }

  static McpClientConfigBlock _parseMcpClient(
    YamlMap? node,
    Map<String, String> env,
  ) {
    if (node == null) return const McpClientConfigBlock();
    final endpointsNode = _optionalMap(node, 'endpoints');
    if (endpointsNode == null) return const McpClientConfigBlock();
    final endpoints = <String, McpEndpointConfig>{};
    for (final keyDyn in endpointsNode.keys) {
      if (keyDyn is! String) {
        throw SubstrateConfigException(
          'substrate.mcpClient.endpoints keys must be strings '
          '(got ${keyDyn.runtimeType}).',
        );
      }
      final id = keyDyn;
      if (id.isEmpty) {
        throw const SubstrateConfigException(
          'substrate.mcpClient.endpoints keys must be non-empty.',
        );
      }
      final entryNode = endpointsNode[id];
      if (entryNode is! YamlMap) {
        throw SubstrateConfigException(
          'substrate.mcpClient.endpoints.$id must be a map '
          '(got ${entryNode.runtimeType}).',
        );
      }
      endpoints[id] = _parseMcpEndpoint(entryNode, id, env);
    }
    return McpClientConfigBlock(
      endpoints: Map<String, McpEndpointConfig>.unmodifiable(endpoints),
    );
  }

  static McpEndpointConfig _parseMcpEndpoint(
    YamlMap node,
    String id,
    Map<String, String> env,
  ) {
    final transportRaw = _requireString(
      node,
      'transport',
      'substrate.mcpClient.endpoints.$id.transport',
    );
    final McpTransportKind transport;
    switch (transportRaw) {
      case 'stdio':
        transport = McpTransportKind.stdio;
      case 'http':
        transport = McpTransportKind.http;
      default:
        throw SubstrateConfigException(
          'substrate.mcpClient.endpoints.$id.transport must be one of '
          '`stdio`, `http` (got "$transportRaw").',
        );
    }

    String? command;
    Uri? url;
    if (transport == McpTransportKind.stdio) {
      final rawCmd = _requireString(
        node,
        'command',
        'substrate.mcpClient.endpoints.$id.command',
      );
      if (rawCmd.isEmpty) {
        throw SubstrateConfigException(
          'substrate.mcpClient.endpoints.$id.command must be non-empty.',
        );
      }
      command = _expandEnv(
        rawCmd,
        env,
        'substrate.mcpClient.endpoints.$id.command',
      );
      if (node['url'] != null) {
        throw SubstrateConfigException(
          'substrate.mcpClient.endpoints.$id has transport=stdio and '
          'must not declare `url:`.',
        );
      }
    } else {
      final rawUrl = _requireString(
        node,
        'url',
        'substrate.mcpClient.endpoints.$id.url',
      );
      final expanded = _expandEnv(
        rawUrl,
        env,
        'substrate.mcpClient.endpoints.$id.url',
      );
      url = _parseUri(
        expanded,
        'substrate.mcpClient.endpoints.$id.url',
      );
      if (node['command'] != null) {
        throw SubstrateConfigException(
          'substrate.mcpClient.endpoints.$id has transport=http and '
          'must not declare `command:`.',
        );
      }
    }

    final authNode = _optionalMap(node, 'auth');
    final auth = _parseMcpAuth(
      authNode,
      env,
      'substrate.mcpClient.endpoints.$id.auth',
    );
    // Stdio + auth ≠ none ⇒ rejected at load time (matches the
    // B.34 `McpAuthResolver.resolve()` invariant). `McpAuthConfig.none`
    // is a `const` singleton (see mcp_auth.dart), so identity
    // comparison is both correct and the cheapest available check
    // without reaching into the sealed type's private subclasses.
    if (transport == McpTransportKind.stdio &&
        !identical(auth, McpAuthConfig.none)) {
      throw SubstrateConfigException(
        'substrate.mcpClient.endpoints.$id has transport=stdio; '
        'auth must be omitted or declared `{mode: none}`.',
      );
    }
    return McpEndpointConfig(
      transport: transport,
      auth: auth,
      command: command,
      url: url,
    );
  }

  static McpAuthConfig _parseMcpAuth(
    YamlMap? node,
    Map<String, String> env,
    String path,
  ) {
    if (node == null) return McpAuthConfig.none;
    final mode = _requireString(node, 'mode', '$path.mode');
    switch (mode) {
      case 'none':
        if (node.length > 1) {
          throw SubstrateConfigException(
            '$path.mode=none must not declare additional keys '
            '(got: ${node.keys.toList()}).',
          );
        }
        return McpAuthConfig.none;
      case 'bearer':
        String? token = _optionalString(node, 'token', '$path.token');
        if (token != null) {
          token = _expandEnv(token, env, '$path.token');
        }
        String? secretRef = _optionalString(
          node,
          'secretRef',
          '$path.secretRef',
        );
        if (secretRef != null) {
          secretRef = _expandEnv(secretRef, env, '$path.secretRef');
        }
        try {
          return McpAuthConfig.bearer(
            token: token,
            secretRef: secretRef,
          );
        } on Object catch (e) {
          // Re-wrap with the dotted-key path so callers see a
          // substrate-config-shaped error rather than an
          // `McpAuthConfigInvalid` with `endpointId: '<unknown>'`.
          throw SubstrateConfigException(
            '$path: ${e.toString()}',
          );
        }
      default:
        throw SubstrateConfigException(
          '$path.mode must be one of `none`, `bearer` (got "$mode").',
        );
    }
  }

  static Map<String, PriceEntry> _parsePriceTable(YamlMap? node) {
    if (node == null) return const {};
    final result = <String, PriceEntry>{};
    for (final keyDyn in node.keys) {
      if (keyDyn is! String) {
        throw SubstrateConfigException(
          'substrate.priceTable keys must be strings '
          '(got ${keyDyn.runtimeType}).',
        );
      }
      final key = keyDyn;
      // Validate the `providerId/modelId` shape — we don't yet
      // know the providers, but a key without `/` is definitely
      // malformed.
      if (!key.contains('/')) {
        throw SubstrateConfigException(
          'substrate.priceTable["$key"] must use `providerId/modelId` '
          'syntax (no `/` found).',
        );
      }
      final entryNode = node[key];
      if (entryNode is! YamlMap) {
        throw SubstrateConfigException(
          'substrate.priceTable["$key"] must be a map '
          '(got ${entryNode.runtimeType}).',
        );
      }
      final inDouble = _requireDouble(
        entryNode,
        'inputPerMTokens',
        'substrate.priceTable["$key"].inputPerMTokens',
      );
      if (inDouble < 0) {
        throw SubstrateConfigException(
          'substrate.priceTable["$key"].inputPerMTokens must be >= 0.',
        );
      }
      final outDouble = _requireDouble(
        entryNode,
        'outputPerMTokens',
        'substrate.priceTable["$key"].outputPerMTokens',
      );
      if (outDouble < 0) {
        throw SubstrateConfigException(
          'substrate.priceTable["$key"].outputPerMTokens must be >= 0.',
        );
      }
      result[key] = PriceEntry(
        inputPerMTokens: inDouble,
        outputPerMTokens: outDouble,
      );
    }
    return Map<String, PriceEntry>.unmodifiable(result);
  }

  // ---------------------------------------------------------------
  // Cross-section validation.
  // ---------------------------------------------------------------

  static void _crossValidate({
    required List<ProviderProfile> providers,
    required Map<String, List<RoleRouteEntryConfig>> roleRoutes,
    required EmbeddingChoice embedding,
    required WebSearchConfig webSearch,
    required Map<String, PriceEntry> priceTable,
  }) {
    final byId = <String, ProviderProfile>{};
    for (final p in providers) {
      byId[p.id] = p;
    }
    // roleRoutes references must resolve.
    for (final entry in roleRoutes.entries) {
      final roleId = entry.key;
      for (var i = 0; i < entry.value.length; i++) {
        final r = entry.value[i];
        final provider = byId[r.providerId];
        if (provider == null) {
          throw SubstrateConfigException(
            'substrate.roleRoutes.$roleId[$i].providerId "${r.providerId}" '
            'is not a configured provider (known: ${byId.keys.toList()}).',
          );
        }
        // Stub providers may legitimately route any model id (they
        // have no `models:` list to validate against).
        if (provider.kind != ProviderKind.stub &&
            !provider.models.contains(r.model)) {
          throw SubstrateConfigException(
            'substrate.roleRoutes.$roleId[$i].model "${r.model}" is not '
            'advertised by provider "${r.providerId}" (known models: '
            '${provider.models}).',
          );
        }
      }
    }
    // embedding.providerId / embedding.model must resolve.
    final embedProvider = byId[embedding.providerId];
    if (embedProvider == null) {
      throw SubstrateConfigException(
        'substrate.embedding.providerId "${embedding.providerId}" is not '
        'a configured provider (known: ${byId.keys.toList()}).',
      );
    }
    if (embedProvider.kind != ProviderKind.stub &&
        !embedProvider.models.contains(embedding.model)) {
      throw SubstrateConfigException(
        'substrate.embedding.model "${embedding.model}" is not advertised '
        'by provider "${embedding.providerId}" (known models: '
        '${embedProvider.models}).',
      );
    }
    // priceTable keys must resolve to a known provider/model.
    for (final key in priceTable.keys) {
      final slash = key.indexOf('/');
      final pid = key.substring(0, slash);
      final mid = key.substring(slash + 1);
      final p = byId[pid];
      if (p == null) {
        throw SubstrateConfigException(
          'substrate.priceTable["$key"] references provider "$pid" which '
          'is not configured (known: ${byId.keys.toList()}).',
        );
      }
      if (p.kind != ProviderKind.stub && !p.models.contains(mid)) {
        throw SubstrateConfigException(
          'substrate.priceTable["$key"] references model "$mid" which is '
          'not advertised by provider "$pid" (known models: ${p.models}).',
        );
      }
    }
    // webSearch.defaultProvider was checked in-section; nothing
    // cross to do here without provider-side reflection on the
    // search registry (deferred to facade boot).
  }

  // ---------------------------------------------------------------
  // Field helpers (mirrors `MemoryConfigLoader`'s shape).
  // ---------------------------------------------------------------

  static String _requireString(
    YamlMap node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) {
      throw SubstrateConfigException('Missing required field: $path');
    }
    if (v is! String) {
      throw SubstrateConfigException(
        '$path must be a string (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static String? _optionalString(
    YamlMap node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) return null;
    if (v is! String) {
      throw SubstrateConfigException(
        '$path must be a string (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static int _requireInt(YamlMap node, String key, String path) {
    final v = node[key];
    if (v == null) {
      throw SubstrateConfigException('Missing required field: $path');
    }
    if (v is! int) {
      throw SubstrateConfigException(
        '$path must be an integer (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static int? _optionalInt(YamlMap node, String key, String path) {
    final v = node[key];
    if (v == null) return null;
    if (v is! int) {
      throw SubstrateConfigException(
        '$path must be an integer (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static double _requireDouble(
    YamlMap node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) {
      throw SubstrateConfigException('Missing required field: $path');
    }
    if (v is num) return v.toDouble();
    throw SubstrateConfigException(
      '$path must be a number (got ${v.runtimeType}).',
    );
  }

  static bool? _optionalBool(
    YamlMap node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) return null;
    if (v is! bool) {
      throw SubstrateConfigException(
        '$path must be a boolean (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static YamlMap _requireMap(
    YamlMap node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) {
      throw SubstrateConfigException('Missing required field: $path');
    }
    if (v is! YamlMap) {
      throw SubstrateConfigException(
        '$path must be a map (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static YamlMap? _optionalMap(YamlMap node, String key) {
    final v = node[key];
    if (v == null) return null;
    if (v is! YamlMap) {
      throw SubstrateConfigException(
        'Field `$key` must be a map (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static YamlList _requireList(
    YamlMap node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) {
      throw SubstrateConfigException('Missing required field: $path');
    }
    if (v is! YamlList) {
      throw SubstrateConfigException(
        '$path must be a list (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static YamlList? _optionalList(
    YamlMap node,
    String key,
    String path,
  ) {
    final v = node[key];
    if (v == null) return null;
    if (v is! YamlList) {
      throw SubstrateConfigException(
        '$path must be a list (got ${v.runtimeType}).',
      );
    }
    return v;
  }

  static Uri _parseUri(String raw, String path) {
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      throw SubstrateConfigException(
        '$path must be a valid URI (got "$raw").',
      );
    }
    return uri;
  }

  // ---------------------------------------------------------------
  // `${NAME}` substitution. Same scanner as `MemoryConfigLoader`'s,
  // line-for-line behaviourally identical so future loaders can be
  // factored onto a shared helper.
  // ---------------------------------------------------------------

  static String _expandEnv(
    String input,
    Map<String, String> env,
    String path,
  ) {
    if (!input.contains(r'$')) return input;
    final out = StringBuffer();
    var i = 0;
    while (i < input.length) {
      final ch = input[i];
      if (ch == r'$' && i + 1 < input.length && input[i + 1] == '{') {
        final close = input.indexOf('}', i + 2);
        if (close < 0) {
          throw SubstrateConfigException(
            '$path has unterminated `\${` token.',
          );
        }
        final name = input.substring(i + 2, close);
        if (name.isEmpty) {
          throw SubstrateConfigException(
            '$path has empty `\${}` token.',
          );
        }
        final value = env[name];
        if (value == null) {
          throw SubstrateConfigException(
            '$path references undefined env var `\${$name}`.',
          );
        }
        out.write(value);
        i = close + 1;
      } else {
        out.write(ch);
        i++;
      }
    }
    return out.toString();
  }
}

