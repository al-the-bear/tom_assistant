// TrailConfigLoader — parses the `trail:` section of the whole-process config
// into a `TrailConfig?` (`tom_brain_logging.md` §4.1 / §8; §10 step #1).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`) so no
// `YamlMap`/`YamlList` node ever leaks into a `TrailConfig`, and `${env:NAME}`
// tokens in `root` are expanded through the shared `YamlConfigReader.expandEnv`
// (the one placeholder resolver). The loader is pure and deterministic:
//
//   * No `trail:` block at all  → returns `null` (unconfigured mode). The
//     caller resolves that to `TrailMode.unconfigured`.
//   * A `trail:` block present  → `root` is REQUIRED. The loader never probes
//     hostname / workspace to synthesise a default root: §8's "shipped config
//     sets it; default value …" describes what the *shipped config file*
//     writes, not a loader default. Every cap / capture flag falls back to its
//     §8 default when omitted.
//
// Every malformed shape surfaces a located `TrailConfigException` (dotted key
// path), matching the discipline of the sibling section loaders.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show MapFieldReader, YamlConfigReader, loadYamlAsMap;

import 'trail_config.dart';

/// Parses the `trail:` section of the whole-process YAML into a [TrailConfig],
/// or `null` when no `trail:` block is present (§10 step #1).
///
/// Namespace-only class (all members static): the loader has no per-instance
/// state, mirroring the sibling section loaders.
abstract final class TrailConfigLoader {
  TrailConfigLoader._();

  /// The keys a `trail:` block may carry (§8). Any other key is a located
  /// error — the forward-only discipline the access loader applies to its own
  /// sections.
  static const Set<String> _allowedTrailKeys = <String>{
    'root',
    'compactLogCap',
    'liveTrailTurns',
    'llmPerRoleCap',
    'incomingPerChannelCap',
    'proceduresPerKindCap',
    'rawAggregateSizeMb',
    'capture',
  };

  /// The keys the `trail.capture` sub-block may carry (§8).
  static const Set<String> _allowedCaptureKeys = <String>{
    'wireBody',
    'internalRoles',
  };

  static const MapFieldReader _reader = MapFieldReader(TrailConfigException.new);

  /// Parses the `trail:` section out of the whole-process [content].
  ///
  /// Reads only `doc['trail']`, tolerating sibling sections — the same
  /// re-parse-the-whole-document contract every section loader uses. [envVars]
  /// expands `${env:NAME}` tokens inside `root` (typically
  /// `Platform.environment`).
  ///
  /// Returns `null` when there is no `trail:` block (unconfigured mode). Pure:
  /// no I/O, no clock.
  ///
  /// Throws [TrailConfigException] (located) on a malformed block.
  static TrailConfig? parse(
    String content, {
    Map<String, String> envVars = const {},
  }) {
    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      rootPath: 'root',
      errorFactory: TrailConfigException.new,
    );
    if (doc['trail'] == null) return null;

    final Map<Object?, Object?> trail =
        _reader.mapValue(doc['trail'], 'trail')!;
    _rejectUnknownKeys(trail, _allowedTrailKeys, 'trail');

    final String rawRoot = _reader.requireString(trail, 'root', 'trail.root');
    final String root = YamlConfigReader(
      env: envVars,
      errorFactory: TrailConfigException.new,
    ).expandEnv(rawRoot, 'trail.root');

    final Map<Object?, Object?> capture =
        _reader.optionalMap(trail, 'capture', 'trail.capture') ?? const {};
    _rejectUnknownKeys(capture, _allowedCaptureKeys, 'trail.capture');

    return TrailConfig(
      root: root,
      compactLogCap: _cap(trail, 'compactLogCap', 1000),
      liveTrailTurns: _cap(trail, 'liveTrailTurns', 20),
      llmPerRoleCap: _cap(trail, 'llmPerRoleCap', 300),
      incomingPerChannelCap: _cap(trail, 'incomingPerChannelCap', 300),
      proceduresPerKindCap: _cap(trail, 'proceduresPerKindCap', 300),
      rawAggregateSizeMb: _cap(trail, 'rawAggregateSizeMb', 1024),
      captureWireBody: _reader.optionalBool(
              capture, 'wireBody', 'trail.capture.wireBody') ??
          true,
      captureInternalRoles: _reader.optionalBool(
              capture, 'internalRoles', 'trail.capture.internalRoles') ??
          true,
    );
  }

  /// Reads an optional positive-integer cap at [key], falling back to [dflt]
  /// when absent. A non-numeric value, a non-integer, or a value ≤ 0 is a
  /// located error.
  static int _cap(Map<Object?, Object?> trail, String key, int dflt) {
    final String path = 'trail.$key';
    final num? value = _reader.optionalNum(trail, key, path);
    if (value == null) return dflt;
    if (value is! int || value <= 0) {
      throw TrailConfigException(
        '$path must be a positive integer (got $value).',
      );
    }
    return value;
  }

  /// Rejects any key in [map] outside [allowed], with a located error.
  static void _rejectUnknownKeys(
    Map<Object?, Object?> map,
    Set<String> allowed,
    String path,
  ) {
    for (final key in map.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw TrailConfigException(
          'Unknown key "$key" under $path; allowed keys are '
          '${allowed.toList()}.',
        );
      }
    }
  }
}
