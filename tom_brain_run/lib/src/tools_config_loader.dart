// ToolsConfigLoader — parses the `tools:` section of the whole-process config
// into a `ToolsConfig?` (§ 21.4; the file-scope roots).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node ever leaks into a `ToolsConfig`, and `${ENV}`
// tokens in each root are expanded through the canonical `expandEnvVars`. The
// loader is pure and deterministic, mirroring `TrailConfigLoader`:
//
//   * No `tools:` block at all      → returns `null`. The caller resolves that
//     to the engine's neutral placeholder root.
//   * A `tools:` block present      → `fileScope` is REQUIRED and must be a
//     non-empty list of strings. An empty list is a located error (a sandbox
//     with no roots cannot host a `file.*` call).
//
// Every malformed shape surfaces a located `ToolsConfigException` (dotted key
// path), matching the discipline of the sibling section loaders.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, expandEnvVars, loadYamlAsMap;

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
  static const Set<String> _allowedToolsKeys = <String>{'fileScope'};

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

    final List<Object?>? rawScope =
        _reader.optionalList(tools, 'fileScope', 'tools.fileScope');
    if (rawScope == null) {
      throw const ToolsConfigException(
        'tools.fileScope is required when a `tools:` block is present; list at '
        'least one file-scope root directory.',
      );
    }
    if (rawScope.isEmpty) {
      throw const ToolsConfigException(
        'tools.fileScope must list at least one root; an empty sandbox cannot '
        'host a file.* call.',
      );
    }

    final List<String> fileScope = <String>[];
    for (var i = 0; i < rawScope.length; i++) {
      final String path = 'tools.fileScope[$i]';
      final String raw = _reader.stringValue(rawScope[i], path)!;
      fileScope.add(expandEnvVars(
        raw,
        envVars,
        path: path,
        errorFactory: ToolsConfigException.new,
      ));
    }

    return ToolsConfig(fileScope: fileScope);
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
