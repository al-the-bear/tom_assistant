// ProviderConfig + ProviderRegistry — layer 1 of the three-layer model
// configuration (Extension F, step 2;
// `tom_brain_procedure_specification.md` § 21.6, Q-F.2).
//
// `providers.yaml` is the single source of "where tokens come from": one
// file listing every provider. It supersedes the ad-hoc
// `substrate.providers:` block — the substrate router consumes *this*
// registry, so there is exactly one provider list. A provider declares:
//
//   id            unique key the prompt-template chain (§ 21.5) binds to.
//   apiType       openai | ollama | anthropic — which wire dialect.
//   baseUrl       the endpoint (verbatim or `${env:NAME}`).
//   apiKey        verbatim string OR `${env:NAME}`; omit for keyless
//                 local engines (Ollama). Resolved via the step-1
//                 placeholder resolver's env form (§ 21.7), so a
//                 `${env:NAME}` is read once at load.
//   toolProtocol  openai (native tool_calls) | json_text (parsed from the
//                 completion) — what makes `call_llm_v1` protocol-agnostic.
//   free          local engines cost nothing; tracked but never debited
//                 against the binding budget dimensions (§ 5.4, Q-H.16).
//
// Loading goes through the canonical plain-map loader (`loadYamlAsMap`),
// so no `YamlMap`/`YamlList` node leaks into a `ProviderConfig`.

library;

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../prompts/placeholder_errors.dart';
import '../prompts/placeholder_resolver.dart';
import 'llm_config_errors.dart';

/// The wire dialect a provider speaks. Parsed from the `apiType` field.
enum ProviderApiType {
  /// OpenAI-compatible chat-completions (also vLLM, oMLX, OpenRouter).
  openai,

  /// Ollama's native API.
  ollama,

  /// Anthropic's Messages API.
  anthropic;

  /// Parses a YAML `apiType` token, rejecting an unknown value through
  /// [LlmConfigInvalid] with [path].
  static ProviderApiType parse(String raw, String path) {
    for (final value in ProviderApiType.values) {
      if (value.name == raw) return value;
    }
    throw LlmConfigInvalid(
      'unknown apiType "$raw" (expected one of '
      '${ProviderApiType.values.map((v) => v.name).join(", ")})',
      path: path,
    );
  }
}

/// How a provider exposes tool calls. Parsed from the `toolProtocol`
/// field; the on-wire `json_text` token maps to [ToolProtocol.jsonText].
enum ToolProtocol {
  /// Native OpenAI `tool_calls`.
  openai('openai'),

  /// Tool calls parsed from JSON embedded in the completion text — the
  /// fallback for models without a native tool-call channel.
  jsonText('json_text');

  const ToolProtocol(this.wire);

  /// The token as written in YAML.
  final String wire;

  /// Parses a YAML `toolProtocol` token, rejecting an unknown value
  /// through [LlmConfigInvalid] with [path].
  static ToolProtocol parse(String raw, String path) {
    for (final value in ToolProtocol.values) {
      if (value.wire == raw) return value;
    }
    throw LlmConfigInvalid(
      'unknown toolProtocol "$raw" (expected one of '
      '${ToolProtocol.values.map((v) => v.wire).join(", ")})',
      path: path,
    );
  }
}

/// One provider's connection settings — an immutable value object.
final class ProviderConfig {
  /// Builds a provider config. [apiKey] is `null` for keyless local
  /// engines; [free] defaults to `false` (paid remote).
  const ProviderConfig({
    required this.id,
    required this.apiType,
    required this.baseUrl,
    required this.toolProtocol,
    this.apiKey,
    this.free = false,
  });

  /// Unique key the prompt-template chain binds to.
  final String id;

  /// The wire dialect this provider speaks.
  final ProviderApiType apiType;

  /// The resolved endpoint (after `${env:NAME}` expansion).
  final Uri baseUrl;

  /// The resolved API key (after `${env:NAME}` expansion), or `null` for
  /// a keyless local engine.
  final String? apiKey;

  /// The tool-call protocol this provider exposes.
  final ToolProtocol toolProtocol;

  /// Whether this provider's tokens are free (a local engine). Never
  /// debits the binding budget dimensions.
  final bool free;

  @override
  bool operator ==(Object other) =>
      other is ProviderConfig &&
      other.id == id &&
      other.apiType == apiType &&
      other.baseUrl == baseUrl &&
      other.apiKey == apiKey &&
      other.toolProtocol == toolProtocol &&
      other.free == free;

  @override
  int get hashCode =>
      Object.hash(id, apiType, baseUrl, apiKey, toolProtocol, free);

  @override
  String toString() => 'ProviderConfig(id: $id, apiType: ${apiType.name}, '
      'baseUrl: $baseUrl, toolProtocol: ${toolProtocol.wire}, '
      'free: $free, apiKey: ${apiKey == null ? 'none' : '***'})';
}

/// The single provider registry the substrate router consumes — the
/// loaded form of `providers.yaml`.
final class ProviderRegistry {
  ProviderRegistry._(this._byId);

  final Map<String, ProviderConfig> _byId;

  /// The provider ids, in document order.
  Iterable<String> get providerIds => _byId.keys;

  /// The providers, in document order.
  List<ProviderConfig> get providers => List.unmodifiable(_byId.values);

  /// Whether a provider with [id] is registered.
  bool contains(String id) => _byId.containsKey(id);

  /// The provider with [id], or `null` when none is registered.
  ProviderConfig? maybeProvider(String id) => _byId[id];

  /// Reads and parses the providers file at [file].
  ///
  /// An absent file throws [ProvidersMissing] — a provider registry is
  /// mandatory. [environment] (default [Platform.environment]) resolves
  /// every `${env:NAME}` in `baseUrl` / `apiKey`. Structural problems
  /// throw [LlmConfigInvalid].
  static Future<ProviderRegistry> loadFromFile(
    File file, {
    Map<String, String>? environment,
  }) async {
    if (!await file.exists()) {
      throw ProvidersMissing(file.path);
    }
    return fromYamlString(
      await file.readAsString(),
      environment: environment,
    );
  }

  /// Parses a providers registry from [yamlText].
  ///
  /// [environment] (default [Platform.environment]) resolves every
  /// `${env:NAME}` token in `baseUrl` / `apiKey`. A missing `providers`
  /// key, a non-list value, a duplicate id, an unknown enum value, a
  /// missing required field, or a failed env expansion each throw
  /// [LlmConfigInvalid].
  static Future<ProviderRegistry> fromYamlString(
    String yamlText, {
    Map<String, String>? environment,
  }) async {
    final doc = loadYamlAsMap(
      yamlText,
      rootPath: 'providers',
      errorFactory: LlmConfigInvalid.new,
    );
    const reader = YamlConfigReader(
      env: <String, String>{},
      errorFactory: LlmConfigInvalid.new,
    );
    final list = reader.requireList(doc, 'providers', 'providers');
    final resolver = PlaceholderResolver(environment: environment);

    final byId = <String, ProviderConfig>{};
    for (var i = 0; i < list.length; i++) {
      final entry = list[i];
      final path = 'providers[$i]';
      if (entry is! Map<Object?, Object?>) {
        throw LlmConfigInvalid('must be a mapping', path: path);
      }
      final id = reader.requireString(entry, 'id', '$path.id');
      if (byId.containsKey(id)) {
        throw LlmConfigInvalid('duplicate provider id "$id"', path: '$path.id');
      }
      final apiType = ProviderApiType.parse(
        reader.requireString(entry, 'apiType', '$path.apiType'),
        '$path.apiType',
      );
      final baseUrl = reader.parseUri(
        await _expandEnv(
          resolver,
          reader.requireString(entry, 'baseUrl', '$path.baseUrl'),
          '$path.baseUrl',
        ),
        '$path.baseUrl',
      );
      final toolProtocol = ToolProtocol.parse(
        reader.requireString(entry, 'toolProtocol', '$path.toolProtocol'),
        '$path.toolProtocol',
      );
      final rawApiKey = reader.optionalString(entry, 'apiKey', '$path.apiKey');
      final apiKey = rawApiKey == null
          ? null
          : await _expandEnv(resolver, rawApiKey, '$path.apiKey');
      final free = reader.optionalBool(entry, 'free', '$path.free') ?? false;

      byId[id] = ProviderConfig(
        id: id,
        apiType: apiType,
        baseUrl: baseUrl,
        apiKey: apiKey,
        toolProtocol: toolProtocol,
        free: free,
      );
    }
    return ProviderRegistry._(byId);
  }

  /// Resolves the `${env:NAME}` env form (the step-1 resolver, § 21.7) in
  /// [raw], re-typing a placeholder failure as a located [LlmConfigInvalid]
  /// so callers see one config-error family.
  static Future<String> _expandEnv(
    PlaceholderResolver resolver,
    String raw,
    String path,
  ) async {
    try {
      return await resolver.resolve(raw);
    } on PlaceholderUnresolvedException catch (e) {
      throw LlmConfigInvalid(e.message, path: path);
    } on PlaceholderRecursionException catch (e) {
      throw LlmConfigInvalid(e.message, path: path);
    } on PlaceholderExpressionException catch (e) {
      throw LlmConfigInvalid(e.message, path: path);
    }
  }
}
