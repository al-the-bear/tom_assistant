// ScriptsConfigLoader — parses the `scripts:` section of the whole-process
// config into a `ScriptsConfig?` (CLI plan step 3).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node ever leaks into a `ScriptsConfig`, and `${env:NAME}`
// tokens in each directory are expanded through the shared
// `YamlConfigReader.expandEnv`. The loader is pure and deterministic, mirroring
// `ToolsConfigLoader`:
//
//   * No `scripts:` block at all → returns `null`. The boot path resolves that
//     to its package-relative fallback.
//   * A `scripts:` block present → `systemDir` is required; `userDir` is
//     optional.
//
// Every malformed shape surfaces a located `ScriptsConfigException` (dotted
// key path), matching the discipline of the sibling section loaders.

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, YamlConfigReader, loadYamlAsMap;

import 'scripts_config.dart';

/// Parses the `scripts:` section of the whole-process YAML into a
/// [ScriptsConfig], or `null` when no `scripts:` block is present.
///
/// Namespace-only class (all members static): the loader has no per-instance
/// state, mirroring the sibling section loaders.
abstract final class ScriptsConfigLoader {
  ScriptsConfigLoader._();

  /// The keys a `scripts:` block may carry. Any other key is a located error —
  /// the forward-only discipline the sibling loaders apply.
  static const Set<String> _allowedScriptsKeys = <String>{
    'systemDir',
    'userDir',
  };

  static const MapFieldReader _reader =
      MapFieldReader(ScriptsConfigException.new);

  /// Parses the `scripts:` section out of the whole-process [content].
  ///
  /// Reads only `doc['scripts']`, tolerating sibling sections — the same
  /// re-parse-the-whole-document contract every section loader uses. [envVars]
  /// expands `${NAME}` tokens inside each directory (typically
  /// `Platform.environment`).
  ///
  /// Returns `null` when there is no `scripts:` block. Pure: no I/O, no clock.
  ///
  /// Throws [ScriptsConfigException] (located) on a malformed block.
  static ScriptsConfig? parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      rootPath: 'root',
      errorFactory: ScriptsConfigException.new,
    );
    if (doc['scripts'] == null) return null;

    final Map<Object?, Object?> scripts =
        _reader.mapValue(doc['scripts'], 'scripts')!;
    _rejectUnknownKeys(scripts, _allowedScriptsKeys, 'scripts');

    final reader = YamlConfigReader(
      env: envVars,
      errorFactory: ScriptsConfigException.new,
    );

    final String? systemDir = _reader.stringValue(
      scripts['systemDir'],
      'scripts.systemDir',
      allowNull: true,
    );
    if (systemDir == null) {
      throw const ScriptsConfigException(
        'Missing required key scripts.systemDir; a present scripts: block must '
        'name the system procedures directory.',
      );
    }

    final String? rawUserDir = _reader.stringValue(
      scripts['userDir'],
      'scripts.userDir',
      allowNull: true,
    );

    return ScriptsConfig(
      systemDir: Directory(reader.expandEnv(systemDir, 'scripts.systemDir')),
      userDir: rawUserDir == null
          ? null
          : Directory(reader.expandEnv(rawUserDir, 'scripts.userDir')),
    );
  }

  /// Rejects any key in [map] outside [allowed], with a located error.
  static void _rejectUnknownKeys(
    Map<Object?, Object?> map,
    Set<String> allowed,
    String path,
  ) {
    for (final key in map.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw ScriptsConfigException(
          'Unknown key "$key" under $path; allowed keys are '
          '${allowed.toList()}.',
        );
      }
    }
  }
}
