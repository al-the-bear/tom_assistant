// ModelConfig + ModelConfigStore — layer 2 of the three-layer model
// configuration (Extension F, step 2;
// `tom_brain_procedure_specification.md` § 21.6, Q-F.2).
//
// One YAML per logical model in `llm_configuration/models/`, carrying the
// provider-independent sampling settings plus a per-provider name map (the
// same model is named differently per provider):
//
//   id             the logical model id (also the filename stem).
//   temperature    optional sampling controls — pure identity, no I/O.
//   maxTokens
//   topP
//   providerNames  { <providerId>: <model name on that provider> }.
//
// A model config names **no** provider and holds **no** endpoint or key —
// it is pure identity + sampling and cannot open an HTTP path on its own.
// The prompt template's `(modelConfig, provider)` chain (layer 3, § 21.5)
// is what binds a model config to a provider.
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`),
// so no `YamlMap`/`YamlList` node leaks into a `ModelConfig`.

library;

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart' show HistorySizing;
import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'llm_config_errors.dart';

/// One logical model's identity + sampling — an immutable value object.
final class ModelConfig {
  /// Builds a model config. The sampling fields are optional (a provider
  /// applies its own defaults when one is absent); the [history] sizing
  /// defaults to the standard window (§ 22.6b).
  const ModelConfig({
    required this.id,
    required this.providerNames,
    this.temperature,
    this.maxTokens,
    this.topP,
    this.history = const HistorySizing.standard(),
  });

  /// The logical model id (also the `models/<id>.yaml` filename stem).
  final String id;

  /// The logical-model → provider-specific name map.
  final Map<String, String> providerNames;

  /// Sampling temperature, or `null` to use the provider default.
  final double? temperature;

  /// Maximum completion tokens, or `null` to use the provider default.
  final int? maxTokens;

  /// Nucleus-sampling top-p, or `null` to use the provider default.
  final double? topP;

  /// The conversation-history sizing knobs — scaled with the model's context
  /// budget (§ 22.6b). A missing `history:` block defaults to the standard
  /// sizing (raw 10 / threshold 40 / 1024 tokens / 6000 chars), not an error.
  final HistorySizing history;

  /// The name this model is known by on provider [providerId], or `null`
  /// when the model is not offered there.
  String? nameFor(String providerId) => providerNames[providerId];

  /// Reads and parses a model config at [file].
  ///
  /// An absent file throws [ModelConfigMissing] keyed by the filename
  /// stem. Structural problems throw [LlmConfigInvalid].
  static Future<ModelConfig> loadFromFile(File file) async {
    if (!await file.exists()) {
      final stem = _stemOf(file.path);
      throw ModelConfigMissing(stem, file.path);
    }
    return fromYamlString(await file.readAsString());
  }

  /// Parses a model config from [yamlText].
  ///
  /// A missing `id`, a non-map `providerNames`, or a non-string entry in
  /// it each throw [LlmConfigInvalid].
  static ModelConfig fromYamlString(String yamlText) {
    final doc = loadYamlAsMap(
      yamlText,
      rootPath: 'model',
      errorFactory: LlmConfigInvalid.new,
    );
    const reader = YamlConfigReader(
      env: <String, String>{},
      errorFactory: LlmConfigInvalid.new,
    );

    final id = reader.requireString(doc, 'id', 'model.id');
    final temperature = reader.optionalDouble(doc, 'temperature', 'model.temperature');
    final maxTokens = reader.optionalInt(doc, 'maxTokens', 'model.maxTokens');
    final topP = reader.optionalDouble(doc, 'topP', 'model.topP');

    final rawNames = reader.optionalMap(doc, 'providerNames');
    final providerNames = <String, String>{};
    if (rawNames != null) {
      for (final entry in rawNames.entries) {
        final providerId = entry.key;
        if (providerId is! String) {
          throw LlmConfigInvalid(
            'provider id key must be a string (got ${providerId.runtimeType})',
            path: 'model.providerNames',
          );
        }
        final name = entry.value;
        if (name is! String) {
          throw LlmConfigInvalid(
            'model name must be a string (got ${name.runtimeType})',
            path: 'model.providerNames.$providerId',
          );
        }
        providerNames[providerId] = name;
      }
    }

    final history = _parseHistorySizing(reader.optionalMap(doc, 'history'), reader);

    return ModelConfig(
      id: id,
      providerNames: Map.unmodifiable(providerNames),
      temperature: temperature,
      maxTokens: maxTokens,
      topP: topP,
      history: history,
    );
  }

  /// Parses the optional `history:` sizing [block] (§ 22.6b).
  ///
  /// An absent block defaults to [HistorySizing.standard]; an absent knob
  /// keeps its default; a present knob must be a strictly-positive integer
  /// (a non-positive or non-integer value is a located [LlmConfigInvalid]).
  static HistorySizing _parseHistorySizing(
    Map<Object?, Object?>? block,
    YamlConfigReader reader,
  ) {
    if (block == null) return const HistorySizing.standard();
    return HistorySizing(
      rawCount: _positiveOr(reader, block, 'rawCount', 'model.history.rawCount', 10),
      compactionThreshold: _positiveOr(
          reader, block, 'compactionThreshold', 'model.history.compactionThreshold', 40),
      maxCompactedTokens: _positiveOr(
          reader, block, 'maxCompactedTokens', 'model.history.maxCompactedTokens', 1024),
      maxCompactedChars: _positiveOr(
          reader, block, 'maxCompactedChars', 'model.history.maxCompactedChars', 6000),
    );
  }

  /// Reads a strictly-positive integer at [key] (located by [path]), or
  /// [fallback] when absent. A non-positive value throws [LlmConfigInvalid].
  static int _positiveOr(
    YamlConfigReader reader,
    Map<Object?, Object?> block,
    String key,
    String path,
    int fallback,
  ) {
    final value = reader.optionalInt(block, key, path);
    if (value == null) return fallback;
    if (value <= 0) {
      throw LlmConfigInvalid('must be strictly positive', path: path);
    }
    return value;
  }

  /// The filename stem (`gemma_4_26b` for `…/gemma_4_26b.yaml`).
  static String _stemOf(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  @override
  bool operator ==(Object other) =>
      other is ModelConfig &&
      other.id == id &&
      other.temperature == temperature &&
      other.maxTokens == maxTokens &&
      other.topP == topP &&
      other.history == history &&
      _sameNames(other.providerNames, providerNames);

  @override
  int get hashCode => Object.hash(
        id,
        temperature,
        maxTokens,
        topP,
        history,
        Object.hashAllUnordered(
          providerNames.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );

  static bool _sameNames(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  String toString() => 'ModelConfig(id: $id, temperature: $temperature, '
      'maxTokens: $maxTokens, topP: $topP, providerNames: $providerNames, '
      'history: $history)';
}

/// Loads per-model configs from a `models/` directory by logical id.
///
/// The directory convention is `llm_configuration/models/<id>.yaml`
/// (§ 21.6). [load] resolves an id to that file and parses it; an absent
/// file is [ModelConfigMissing].
final class ModelConfigStore {
  /// Wraps the directory holding the `<id>.yaml` model configs.
  const ModelConfigStore(this.directory);

  /// The directory holding `<id>.yaml` model configs.
  final Directory directory;

  /// Loads the model config named [id] (`<directory>/<id>.yaml`).
  ///
  /// Throws [ModelConfigMissing] when the file is absent, or
  /// [LlmConfigInvalid] when it is malformed.
  Future<ModelConfig> load(String id) {
    final file =
        File('${directory.path}${Platform.pathSeparator}$id.yaml');
    return ModelConfig.loadFromFile(file);
  }
}
