// CognitionRunConfigLoader — parses the `cognition:` section of the
// whole-process config into a `CognitionRunConfig?` (`prompt_configuration.md`
// §7.4).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node ever leaks into a `CognitionRunConfig`. The loader
// is pure and deterministic, mirroring the sibling section loaders
// (`DreamConfigLoader` / `ToolsConfigLoader` / `TrailConfigLoader`):
//
//   * No `cognition:` block at all → returns `null`. The run assembly wires no
//     prompt / route resolvers (any `sub.run` then raises
//     `UnregisteredPromptException`).
//   * A `cognition:` block present  → a required `root` directory string.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, loadYamlAsMap;

import 'cognition_run_config.dart';

/// Parses the `cognition:` section of the whole-process YAML into a
/// [CognitionRunConfig], or `null` when no `cognition:` block is present.
///
/// Namespace-only class (all members static): the loader has no per-instance
/// state, mirroring the sibling section loaders.
abstract final class CognitionRunConfigLoader {
  CognitionRunConfigLoader._();

  /// The keys a `cognition:` block may carry. Any other key is a located error.
  static const Set<String> _allowedKeys = <String>{'root'};

  static const MapFieldReader _reader =
      MapFieldReader(CognitionRunConfigException.new);

  /// Parses the `cognition:` section out of the whole-process [content].
  ///
  /// Reads only `doc['cognition']`, tolerating sibling sections — the same
  /// re-parse-the-whole-document contract every section loader uses.
  ///
  /// Returns `null` when there is no `cognition:` block. Pure: no I/O, no clock.
  ///
  /// Throws [CognitionRunConfigException] (located) on a malformed block.
  /// [envVars] is accepted for signature parity with the sibling loaders; the
  /// `cognition:` section carries no `${ENV}`-expandable values today.
  static CognitionRunConfig? parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      rootPath: 'root',
      errorFactory: CognitionRunConfigException.new,
    );
    if (doc['cognition'] == null) return null;

    final Map<Object?, Object?> cognition =
        _reader.mapValue(doc['cognition'], 'cognition')!;
    _rejectUnknownKeys(cognition, _allowedKeys, 'cognition');

    final String root =
        _reader.requireString(cognition, 'root', 'cognition.root');

    return CognitionRunConfig(root: root);
  }

  /// Rejects any key in [map] outside [allowed], with a located error.
  static void _rejectUnknownKeys(
    Map<Object?, Object?> map,
    Set<String> allowed,
    String path,
  ) {
    for (final key in map.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw CognitionRunConfigException(
          'Unknown key "$key" under $path; allowed keys are '
          '${allowed.toList()}.',
        );
      }
    }
  }
}
