// CognitionConfigLoader — parses the cognition config root (`registry.yaml` plus
// the main-procedure config files it references) into a `CognitionConfig`
// (`prompt_configuration.md` §4 / §5 / §5.5; §12 step 3).
//
// It mirrors the discipline of the sibling section loaders (`trail_config_loader`
// et al.): every load goes through the canonical plain-map loader
// (`loadYamlAsMap`) so no `YamlMap`/`YamlList` node leaks into a value type;
// every string field is expanded through the shared `YamlConfigReader.expandEnv`
// (the one `${env:NAME}` resolver); every malformed shape surfaces a located
// `CognitionConfigException` (dotted key path). A duplicate YAML mapping key — a
// duplicate sub-procedure or prompt name — surfaces from `loadYaml` as a
// `FormatException` (`YamlException`), rewrapped here as a located
// `CognitionConfigException`.
//
// Inheritance is resolved at load time, bottom-up: prompt → sub-procedure →
// main-procedure, with the `llm` route falling back to the registry's
// `llm.default`. Consumers read a single flat `ResolvedPrompt`, never a chain.

import 'dart:io';

import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show RoleRouteEntryConfig, RouteConditionsConfig;
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, YamlConfigReader, loadYamlAsMap;

import 'cognition_config.dart';
import 'llm_route_config.dart';

/// Parses the cognition config root into a [CognitionConfig] (§12 step 3).
///
/// Namespace-only class (all members static): the loader holds no per-instance
/// state, mirroring the sibling section loaders.
abstract final class CognitionConfigLoader {
  CognitionConfigLoader._();

  static const MapFieldReader _reader =
      MapFieldReader(CognitionConfigException.new);

  /// The per-prompt / per-level setting keys (§5.4). Present at the main,
  /// sub-procedure, and prompt levels; merged bottom-up.
  static const Set<String> _settingKeys = <String>{
    'temperature',
    'max_tool_loops',
    'tools',
    'llm',
    'role',
    'response_format',
    'stop_sequences',
  };

  /// Keys a sub-procedure block may carry: the settings plus `prompts`.
  static const Set<String> _subAllowedKeys = <String>{
    'temperature',
    'max_tool_loops',
    'tools',
    'llm',
    'role',
    'response_format',
    'stop_sequences',
    'prompts',
  };

  /// Keys a prompt block may carry: the settings plus `template` and `kind`.
  static const Set<String> _promptAllowedKeys = <String>{
    'temperature',
    'max_tool_loops',
    'tools',
    'llm',
    'role',
    'response_format',
    'stop_sequences',
    'template',
    'kind',
  };

  /// Parses [registryYaml] plus the [procedureConfigs] it references (keyed by
  /// the registry's `config:` filename) into a [CognitionConfig].
  ///
  /// Pure: no I/O, no clock. [env] expands `${env:NAME}` tokens in string
  /// values. Throws [CognitionConfigException] (located) on any malformed shape,
  /// a missing `template`, a duplicate mapping key, an unknown setting key, or a
  /// referenced config that is absent from [procedureConfigs].
  static CognitionConfig parse({
    required String registryYaml,
    required Map<String, String> procedureConfigs,
    Map<String, String> llmRouteConfigs = const {},
    Map<String, String> env = const {},
  }) {
    final YamlConfigReader envReader =
        YamlConfigReader(env: env, errorFactory: CognitionConfigException.new);
    final CognitionRegistry registry = _parseRegistry(registryYaml, envReader);

    final Map<String, ResolvedPrompt> prompts = <String, ResolvedPrompt>{};
    for (final proc in registry.procedures.values) {
      final String? content = procedureConfigs[proc.configFile];
      if (content == null) {
        throw CognitionConfigException(
          'procedures.${proc.name}.config: referenced config '
          '"${proc.configFile}" was not provided.',
        );
      }
      _parseProcedure(proc, content, registry, envReader, prompts);
    }

    final Map<String, LlmRouteConfig> llmRoutes = <String, LlmRouteConfig>{};
    for (final entry in llmRouteConfigs.entries) {
      llmRoutes[entry.key] = _parseRoute(entry.key, entry.value, envReader);
    }
    _validateRoutes(registry, prompts, llmRoutes);

    return CognitionConfig(
      registry: registry,
      prompts: prompts,
      llmRoutes: llmRoutes,
    );
  }

  /// Reads `registry.yaml` plus every referenced main-procedure config off disk
  /// at [cognitionRootDir] and parses them via [parse].
  ///
  /// Production callers use this entry point; tests use [parse] with inline
  /// content. The registry is read first to learn which config files to load.
  static CognitionConfig loadFromDir(
    String cognitionRootDir, {
    Map<String, String> env = const {},
  }) {
    final File registryFile = File('$cognitionRootDir/registry.yaml');
    if (!registryFile.existsSync()) {
      throw CognitionConfigException(
        'registry.yaml not found in cognition root: $cognitionRootDir',
      );
    }
    final String registryYaml = registryFile.readAsStringSync();
    final YamlConfigReader envReader =
        YamlConfigReader(env: env, errorFactory: CognitionConfigException.new);
    final CognitionRegistry registry = _parseRegistry(registryYaml, envReader);

    final Map<String, String> configs = <String, String>{};
    for (final proc in registry.procedures.values) {
      final File file = File('$cognitionRootDir/${proc.configFile}');
      if (!file.existsSync()) {
        throw CognitionConfigException(
          'procedures.${proc.name}.config: file "${proc.configFile}" not found '
          'in cognition root: $cognitionRootDir',
        );
      }
      configs[proc.configFile] = file.readAsStringSync();
    }

    // The `llm/` folder: every `<name>.yaml` becomes a route config keyed by its
    // filename stem (the name a prompt's `llm:` references). An absent folder
    // yields no routes (route resolution then throws on demand).
    final Map<String, String> routeConfigs = <String, String>{};
    final Directory llmDir =
        Directory('$cognitionRootDir/${registry.llmFolder}');
    if (llmDir.existsSync()) {
      for (final entity in llmDir.listSync()) {
        if (entity is File && entity.path.endsWith('.yaml')) {
          routeConfigs[_stemOf(entity.path)] = entity.readAsStringSync();
        }
      }
    }

    return parse(
      registryYaml: registryYaml,
      procedureConfigs: configs,
      llmRouteConfigs: routeConfigs,
      env: env,
    );
  }

  // ── registry.yaml ───────────────────────────────────────────────────

  static CognitionRegistry _parseRegistry(
    String registryYaml,
    YamlConfigReader envReader,
  ) {
    final Map<String, Object?> doc = _loadMap(registryYaml, 'registry');
    _rejectUnknownKeys(
      doc,
      const <String>{'procedures', 'roles', 'llm'},
      'registry',
    );

    final Map<Object?, Object?> procsMap =
        _reader.optionalMap(doc, 'procedures', 'registry.procedures') ??
            const {};
    final Map<String, RegisteredProcedure> procedures =
        <String, RegisteredProcedure>{};
    for (final entry in procsMap.entries) {
      final String name = _reader.stringValue(entry.key, 'registry.procedures')!;
      final String path = 'registry.procedures.$name';
      final Map<Object?, Object?> proc = _reader.mapValue(entry.value, path)!;
      procedures[name] = RegisteredProcedure(
        name: name,
        configFile: envReader.expandEnv(
          _reader.requireString(proc, 'config', '$path.config'),
          '$path.config',
        ),
        folder: envReader.expandEnv(
          _reader.requireString(proc, 'folder', '$path.folder'),
          '$path.folder',
        ),
      );
    }

    final Map<Object?, Object?> roles =
        _reader.mapValue(doc['roles'], 'registry.roles')!;
    final Map<Object?, Object?> llm =
        _reader.mapValue(doc['llm'], 'registry.llm')!;

    return CognitionRegistry(
      procedures: procedures,
      rolesFolder: envReader.expandEnv(
        _reader.requireString(roles, 'folder', 'registry.roles.folder'),
        'registry.roles.folder',
      ),
      llmFolder: envReader.expandEnv(
        _reader.requireString(llm, 'folder', 'registry.llm.folder'),
        'registry.llm.folder',
      ),
      llmDefault: envReader.expandEnv(
        _reader.requireString(llm, 'default', 'registry.llm.default'),
        'registry.llm.default',
      ),
    );
  }

  // ── <main_procedure>.yaml ───────────────────────────────────────────

  static void _parseProcedure(
    RegisteredProcedure proc,
    String content,
    CognitionRegistry registry,
    YamlConfigReader envReader,
    Map<String, ResolvedPrompt> out,
  ) {
    final Map<String, Object?> doc = _loadMap(content, proc.name);
    final _SettingsLayer mainLayer = _readSettings(doc, proc.name, envReader);

    for (final entry in doc.entries) {
      final String key = entry.key;
      if (_settingKeys.contains(key)) continue; // a main-level setting
      // Otherwise a sub-procedure block.
      final String subPath = '${proc.name}.$key';
      final Map<Object?, Object?> sub = _reader.mapValue(entry.value, subPath)!;
      _rejectUnknownKeys(sub, _subAllowedKeys, subPath);
      final _SettingsLayer subLayer = _readSettings(sub, subPath, envReader);

      final Map<Object?, Object?> promptsMap =
          _reader.optionalMap(sub, 'prompts', '$subPath.prompts') ?? const {};
      for (final pe in promptsMap.entries) {
        final String promptName =
            _reader.stringValue(pe.key, '$subPath.prompts')!;
        final String promptPath = '$subPath.prompts.$promptName';
        final Map<Object?, Object?> pm =
            _reader.mapValue(pe.value, promptPath)!;
        _rejectUnknownKeys(pm, _promptAllowedKeys, promptPath);

        final String template = envReader.expandEnv(
          _reader.requireString(pm, 'template', '$promptPath.template'),
          '$promptPath.template',
        );
        final _SettingsLayer promptLayer =
            _readSettings(pm, promptPath, envReader);

        final _SettingsLayer merged =
            _merge(_merge(mainLayer, subLayer), promptLayer);
        final String id = '${proc.name}.$key.$promptName';
        out[id] = ResolvedPrompt(
          id: id,
          mainProcedure: proc.name,
          subProcedure: key,
          promptName: promptName,
          templatePath: '${proc.folder}/$template',
          kind: _parseKind(pm['kind'], '$promptPath.kind'),
          settings: PromptSettings(
            temperature: merged.temperature,
            maxToolLoops: merged.maxToolLoops,
            tools: merged.tools,
            llm: merged.llm ?? registry.llmDefault,
            role: merged.role ?? 'assistant_to_user',
            responseFormat: merged.responseFormat,
            stopSequences: merged.stopSequences,
          ),
        );
      }
    }
  }

  // ── settings layer ──────────────────────────────────────────────────

  static _SettingsLayer _readSettings(
    Map<Object?, Object?> map,
    String path,
    YamlConfigReader envReader,
  ) =>
      _SettingsLayer(
        temperature: _readDouble(map, 'temperature', '$path.temperature'),
        maxToolLoops: _readInt(map, 'max_tool_loops', '$path.max_tool_loops'),
        tools: _parseTools(map['tools'], '$path.tools', envReader),
        llm: _readString(map, 'llm', '$path.llm', envReader),
        role: _readString(map, 'role', '$path.role', envReader),
        responseFormat: _readResponseFormat(map, '$path.response_format'),
        stopSequences:
            _readStringList(map, 'stop_sequences', '$path.stop_sequences',
                envReader),
      );

  static _SettingsLayer _merge(_SettingsLayer base, _SettingsLayer override) =>
      _SettingsLayer(
        temperature: override.temperature ?? base.temperature,
        maxToolLoops: override.maxToolLoops ?? base.maxToolLoops,
        tools: override.tools ?? base.tools,
        llm: override.llm ?? base.llm,
        role: override.role ?? base.role,
        responseFormat: override.responseFormat ?? base.responseFormat,
        stopSequences: override.stopSequences ?? base.stopSequences,
      );

  static double? _readDouble(
      Map<Object?, Object?> map, String key, String path) {
    final num? value = _reader.optionalNum(map, key, path);
    return value?.toDouble();
  }

  static int? _readInt(Map<Object?, Object?> map, String key, String path) {
    final num? value = _reader.optionalNum(map, key, path);
    if (value == null) return null;
    if (value is! int) {
      throw CognitionConfigException('$path must be an integer (got $value).');
    }
    return value;
  }

  static String? _readString(
    Map<Object?, Object?> map,
    String key,
    String path,
    YamlConfigReader envReader,
  ) {
    final String? value = _reader.optionalString(map, key, path);
    return value == null ? null : envReader.expandEnv(value, path);
  }

  static ToolsSetting? _parseTools(
    Object? raw,
    String path,
    YamlConfigReader envReader,
  ) {
    if (raw == null) return null;
    if (raw is String) {
      switch (raw) {
        case 'all':
          return const ToolsAll();
        case 'readonly':
          return const ToolsReadonly();
        case 'none':
          return const ToolsNone();
        default:
          throw CognitionConfigException(
            '$path: unknown tools keyword "$raw" '
            '(expected all | readonly | none, or a list of names).',
          );
      }
    }
    if (raw is List) {
      final List<String> names = <String>[];
      for (var i = 0; i < raw.length; i++) {
        final String name = _reader.stringValue(raw[i], '$path[$i]')!;
        names.add(envReader.expandEnv(name, '$path[$i]'));
      }
      return ToolsExplicit(names);
    }
    throw CognitionConfigException(
      '$path: tools must be a keyword (all | readonly | none) or a list '
      'of names (got ${raw.runtimeType}).',
    );
  }

  static Map<String, Object?>? _readResponseFormat(
      Map<Object?, Object?> map, String path) {
    final Map<Object?, Object?>? value =
        _reader.optionalMap(map, 'response_format', path);
    return value == null ? null : Map<String, Object?>.from(value);
  }

  static List<String>? _readStringList(
    Map<Object?, Object?> map,
    String key,
    String path,
    YamlConfigReader envReader,
  ) {
    final List<Object?>? value = _reader.optionalList(map, key, path);
    if (value == null) return null;
    final List<String> out = <String>[];
    for (var i = 0; i < value.length; i++) {
      final String item = _reader.stringValue(value[i], '$path[$i]')!;
      out.add(envReader.expandEnv(item, '$path[$i]'));
    }
    return out;
  }

  static PromptKind _parseKind(Object? raw, String path) {
    if (raw == null) return PromptKind.prompt;
    final String value = _reader.stringValue(raw, path)!;
    switch (value) {
      case 'prompt':
        return PromptKind.prompt;
      case 'fragment':
        return PromptKind.fragment;
      default:
        throw CognitionConfigException(
          '$path: kind must be "prompt" or "fragment" (got "$value").',
        );
    }
  }

  // ── llm/<name>.yaml route configs (§8 / §8.1) ───────────────────────

  /// Parses one `cognition/llm/<name>.yaml` into an [LlmRouteConfig].
  ///
  /// The `route:` list order is the rotation order, preserved verbatim. Each row
  /// is `{provider, model, conditions?}` (the substrate [RoleRouteEntryConfig]
  /// shape). A missing `provider`/`model`, an unknown row key, or an empty list
  /// is a located [CognitionConfigException].
  static LlmRouteConfig _parseRoute(
    String name,
    String content,
    YamlConfigReader envReader,
  ) {
    final String rootPath = 'llm.$name';
    final Map<String, Object?> doc = _loadMap(content, rootPath);
    _rejectUnknownKeys(doc, const <String>{'route'}, rootPath);

    final List<Object?> rows =
        _reader.optionalList(doc, 'route', '$rootPath.route') ?? const [];
    if (rows.isEmpty) {
      throw CognitionConfigException(
        '$rootPath.route: a route config must list at least one '
        '{provider, model} entry.',
      );
    }

    final List<RoleRouteEntryConfig> entries = <RoleRouteEntryConfig>[];
    for (var i = 0; i < rows.length; i++) {
      final String path = '$rootPath.route[$i]';
      final Map<Object?, Object?> row = _reader.mapValue(rows[i], path)!;
      _rejectUnknownKeys(
        row,
        const <String>{'provider', 'model', 'conditions'},
        path,
      );
      final String provider = envReader.expandEnv(
        _reader.requireString(row, 'provider', '$path.provider'),
        '$path.provider',
      );
      final String model = envReader.expandEnv(
        _reader.requireString(row, 'model', '$path.model'),
        '$path.model',
      );

      RouteConditionsConfig? conditions;
      final Map<Object?, Object?>? cond =
          _reader.optionalMap(row, 'conditions', '$path.conditions');
      if (cond != null) {
        _rejectUnknownKeys(
            cond, const <String>{'maxInputTokens'}, '$path.conditions');
        conditions = RouteConditionsConfig(
          maxInputTokens: _readInt(
              cond, 'maxInputTokens', '$path.conditions.maxInputTokens'),
        );
      }

      entries.add(RoleRouteEntryConfig(
        providerId: provider,
        model: model,
        conditions: conditions,
      ));
    }

    return LlmRouteConfig(
      name: name,
      route: List<RoleRouteEntryConfig>.unmodifiable(entries),
    );
  }

  /// Cross-checks the loaded [llmRoutes] against the references (§8.1).
  ///
  /// When at least one route config is loaded, fail-fast: the registry's
  /// `llm.default` must be among them, and every prompt's resolved `llm` route
  /// name must resolve. With no route configs loaded (a pure registry+procedure
  /// `parse`, or an absent `llm/` folder) there is nothing to cross-check —
  /// route resolution then throws on demand via [CognitionConfig.route].
  static void _validateRoutes(
    CognitionRegistry registry,
    Map<String, ResolvedPrompt> prompts,
    Map<String, LlmRouteConfig> llmRoutes,
  ) {
    if (llmRoutes.isEmpty) return;
    if (!llmRoutes.containsKey(registry.llmDefault)) {
      throw CognitionConfigException(
        'registry.llm.default: "${registry.llmDefault}" is not among the '
        'loaded llm/ route configs ${llmRoutes.keys.toList()}.',
      );
    }
    for (final prompt in prompts.values) {
      final String? name = prompt.settings.llm;
      if (name != null && !llmRoutes.containsKey(name)) {
        throw CognitionConfigException(
          'prompt "${prompt.id}": llm route "$name" is not among the loaded '
          'llm/ route configs ${llmRoutes.keys.toList()}.',
        );
      }
    }
  }

  // ── shared helpers ──────────────────────────────────────────────────

  /// Loads [content] as a plain map, rewrapping a `loadYaml` parse / duplicate-
  /// key failure (a [FormatException] / `YamlException`) as a located
  /// [CognitionConfigException].
  static Map<String, Object?> _loadMap(String content, String rootPath) {
    try {
      return loadYamlAsMap(
        content,
        rootPath: rootPath,
        errorFactory: CognitionConfigException.new,
      );
    } on CognitionConfigException {
      rethrow;
    } on FormatException catch (e) {
      throw CognitionConfigException(
        '$rootPath: malformed YAML (${e.message}).',
      );
    }
  }

  /// The filename stem (`default` for `…/default.yaml`).
  static String _stemOf(String path) {
    final String name = path.split(Platform.pathSeparator).last;
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  static void _rejectUnknownKeys(
    Map<Object?, Object?> map,
    Set<String> allowed,
    String path,
  ) {
    for (final key in map.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw CognitionConfigException(
          'Unknown key "$key" under $path; allowed keys are '
          '${allowed.toList()}.',
        );
      }
    }
  }
}

/// One inheritance layer of settings (main / sub / prompt), all fields nullable
/// — merged bottom-up by [CognitionConfigLoader].
final class _SettingsLayer {
  final double? temperature;
  final int? maxToolLoops;
  final ToolsSetting? tools;
  final String? llm;
  final String? role;
  final Map<String, Object?>? responseFormat;
  final List<String>? stopSequences;

  const _SettingsLayer({
    this.temperature,
    this.maxToolLoops,
    this.tools,
    this.llm,
    this.role,
    this.responseFormat,
    this.stopSequences,
  });
}
