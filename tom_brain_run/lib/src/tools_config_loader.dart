// ToolsConfigLoader — parses the `tools:` section of the whole-process config
// into a `ToolsConfig?` (§ 21.4; the two-tier file-scope roots).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node ever leaks into a `ToolsConfig`, and `${env:NAME}`
// tokens in each root are expanded through the shared
// `YamlConfigReader.expandEnv` (the one placeholder resolver). The loader is
// pure and deterministic, mirroring `TrailConfigLoader`:
//
//   * No `tools:` block at all      → returns `null`. The caller resolves that
//     to the engine's neutral placeholder root.
//   * A `tools:` block present      → at least one of `writeScope` /
//     `readScope` must be a non-empty list of strings. Both empty (or absent)
//     is a located error (a sandbox with no roots cannot host a `file.*` call).
//
// Every malformed shape surfaces a located `ToolsConfigException` (dotted key
// path), matching the discipline of the sibling section loaders.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, YamlConfigReader, loadYamlAsMap;

import 'tools_config.dart';

/// Parses the `tools:` section of the whole-process YAML into a [ToolsConfig],
/// or `null` when no `tools:` block is present.
///
/// Namespace-only class (all members static): the loader has no per-instance
/// state, mirroring the sibling section loaders.
abstract final class ToolsConfigLoader {
  ToolsConfigLoader._();

  /// The keys a `tools:` block may carry. Any other key is a located error —
  /// the forward-only discipline the sibling loaders apply.
  static const Set<String> _allowedToolsKeys = <String>{
    'writeScope',
    'readScope',
  };

  static const MapFieldReader _reader = MapFieldReader(ToolsConfigException.new);

  /// Parses the `tools:` section out of the whole-process [content].
  ///
  /// Reads only `doc['tools']`, tolerating sibling sections — the same
  /// re-parse-the-whole-document contract every section loader uses. [envVars]
  /// expands `${NAME}` tokens inside each file-scope root (typically
  /// `Platform.environment`).
  ///
  /// Returns `null` when there is no `tools:` block. Pure: no I/O, no clock.
  ///
  /// Throws [ToolsConfigException] (located) on a malformed block.
  static ToolsConfig? parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      rootPath: 'root',
      errorFactory: ToolsConfigException.new,
    );
    if (doc['tools'] == null) return null;

    final Map<Object?, Object?> tools = _reader.mapValue(doc['tools'], 'tools')!;
    _rejectUnknownKeys(tools, _allowedToolsKeys, 'tools');

    final List<String> writeScope =
        _readScopeList(tools, 'writeScope', envVars);
    final List<String> readScope = _readScopeList(tools, 'readScope', envVars);

    if (writeScope.isEmpty && readScope.isEmpty) {
      throw const ToolsConfigException(
        'a `tools:` block must list at least one root under writeScope or '
        'readScope; an empty sandbox cannot host a file.* call.',
      );
    }

    return ToolsConfig(writeScope: writeScope, readScope: readScope);
  }

  /// Reads an optional list of file-scope roots under [key], expanding
  /// `${env:NAME}` tokens. Returns an empty list when the key is absent; an
  /// empty list under
  /// a present key is a located error (a tier should be omitted, not empty).
  static List<String> _readScopeList(
    Map<Object?, Object?> tools,
    String key,
    Map<String, String> envVars,
  ) {
    final List<Object?>? raw =
        _reader.optionalList(tools, key, 'tools.$key');
    if (raw == null) return const <String>[];
    if (raw.isEmpty) {
      throw ToolsConfigException(
        'tools.$key, when present, must list at least one root; omit the key '
        'instead of listing an empty tier.',
      );
    }
    final reader = YamlConfigReader(
      env: envVars,
      errorFactory: ToolsConfigException.new,
    );
    final List<String> roots = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final String path = 'tools.$key[$i]';
      final String value = _reader.stringValue(raw[i], path)!;
      roots.add(reader.expandEnv(value, path));
    }
    return roots;
  }

  /// Rejects any key in [map] outside [allowed], with a located error.
  static void _rejectUnknownKeys(
    Map<Object?, Object?> map,
    Set<String> allowed,
    String path,
  ) {
    for (final key in map.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw ToolsConfigException(
          'Unknown key "$key" under $path; allowed keys are '
          '${allowed.toList()}.',
        );
      }
    }
  }
}
