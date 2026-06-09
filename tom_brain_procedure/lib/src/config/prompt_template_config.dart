// PromptTemplateConfig + PromptTemplateStore — layer 3 of the three-layer
// model configuration (Extension F, step 3;
// `tom_brain_procedure_specification.md` § 21.5, § 21.6, Q-F.2).
//
// One YAML per **prompt type** in `prompt_template/`. A prompt type maps
// to a **role** (resolving a `RoleTemplate` in `tom_brain_substrate`, so
// the anchor (PE-7) is reachable as `${role.anchor}`) and carries:
//
//   id          the prompt type id (also the `<type>.yaml` filename stem).
//   role        the role this prompt type assumes.
//   models      ordered list of `{config, provider}` pairs — the
//               routing/fallback chain (§ 21.6 layer 3). First reachable
//               pair wins.
//   tools       default tool allow-set for this prompt type.
//   mcpServers  default MCP servers for this prompt type.
//   toolPolicy  one of all | read_only | groups | explicit (§ 21.8).
//   setup       optional d4rt setup script the placeholder resolver runs
//               before evaluating `${{ … }}` expressions (§ 21.7).
//   system      the system scaffold (kept verbatim, placeholder-bearing).
//   user        the user scaffold (kept verbatim, placeholder-bearing).
//
// The `system` / `user` scaffolds are stored **unresolved**: their
// `${role.anchor}` / `${citations}` / `${{ … }}` / `${prompt}` markers
// survive into the loaded object untouched — `call_llm_v1` (later steps)
// runs them through the placeholder resolver, not the loader.
//
// Binding to a concrete call is `resolve(ProviderRegistry,
// ModelConfigStore)`: it walks the `models` chain and binds the first
// reachable pair to a provider connection (layer 1) + provider-specific
// model name (layer-2 `providerNames`) + sampling (layer 2). A pair whose
// model is simply **not offered** on its provider is a *soft* fallback to
// the next pair; a pair naming an id that **does not exist** (unknown
// provider, unknown config) is a *hard*, located `llm.config.invalid` —
// so a typo'd id surfaces loudly rather than silently falling through.
//
// The whole unit lives in `lib/src/config/` (beside the layer-1/2 configs
// it binds): the dependency arrows point `config → prompts` only — see the
// § 21.5 step-3 concretization. Loading goes through the canonical
// plain-map loader (`loadYamlAsMap`), so no `YamlMap`/`YamlList` node ever
// leaks into a `PromptTemplateConfig`.

library;

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'history_policy.dart';
import 'llm_config_errors.dart';
import 'model_config.dart';
import 'provider_config.dart';

/// One `{config, provider}` routing pair in a template's `models` chain —
/// an immutable value object naming a layer-2 model config id and a
/// layer-1 provider id (resolved by [PromptTemplateConfig.resolve]).
final class PromptModelRef {
  /// Builds a routing pair binding model config [config] to provider
  /// [provider].
  const PromptModelRef({required this.config, required this.provider});

  /// The layer-2 model config id (`models/<config>.yaml` stem).
  final String config;

  /// The layer-1 provider id (a key in the [ProviderRegistry]).
  final String provider;

  @override
  bool operator ==(Object other) =>
      other is PromptModelRef &&
      other.config == config &&
      other.provider == provider;

  @override
  int get hashCode => Object.hash(config, provider);

  @override
  String toString() => 'PromptModelRef(config: $config, provider: $provider)';
}

/// The tool-permission profile a prompt type selects (§ 21.8). The on-wire
/// `read_only` token maps to [ToolPolicyProfile.readOnly].
enum ToolPolicyProfile {
  /// Every tool (the deny list is still honoured, step 5).
  all('all'),

  /// Every `readOnly` tool (the deny list is still honoured).
  readOnly('read_only'),

  /// Every tool whose `group` is in the enabled-groups set.
  groups('groups'),

  /// Only the allow-listed tool names.
  explicit('explicit');

  const ToolPolicyProfile(this.wire);

  /// The token as written in YAML.
  final String wire;

  /// Parses a YAML `toolPolicy` token, rejecting an unknown value through
  /// [LlmConfigInvalid] with [path].
  static ToolPolicyProfile parse(String raw, String path) {
    for (final value in ToolPolicyProfile.values) {
      if (value.wire == raw) return value;
    }
    throw LlmConfigInvalid(
      'unknown toolPolicy "$raw" (expected one of '
      '${ToolPolicyProfile.values.map((v) => v.wire).join(", ")})',
      path: path,
    );
  }
}

/// A resolved binding: the provider connection (layer 1), the
/// provider-specific model name (layer-2 `providerNames`), and the model's
/// sampling settings (layer 2). The output of
/// [PromptTemplateConfig.resolve].
final class ResolvedPromptModel {
  /// Binds [provider] + the provider-specific [modelName] + the layer-2
  /// [model] (for its sampling).
  const ResolvedPromptModel({
    required this.provider,
    required this.modelName,
    required this.model,
  });

  /// The resolved provider connection (layer 1).
  final ProviderConfig provider;

  /// The name this model is known by on [provider] (layer-2
  /// `providerNames`).
  final String modelName;

  /// The resolved model config — its sampling is the layer-2 contribution.
  final ModelConfig model;

  @override
  bool operator ==(Object other) =>
      other is ResolvedPromptModel &&
      other.provider == provider &&
      other.modelName == modelName &&
      other.model == model;

  @override
  int get hashCode => Object.hash(provider, modelName, model);

  @override
  String toString() => 'ResolvedPromptModel(provider: ${provider.id}, '
      'modelName: $modelName, model: ${model.id})';
}

/// One prompt type's template — an immutable value object.
final class PromptTemplateConfig {
  /// Builds a prompt template. The optional sets default to empty / `null`
  /// (a prompt type need not declare tools, MCP servers, a policy, or a
  /// setup script).
  const PromptTemplateConfig({
    required this.id,
    required this.role,
    required this.models,
    required this.tools,
    required this.mcpServers,
    required this.system,
    required this.user,
    this.toolPolicy,
    this.setup,
    this.history = const HistoryPolicy.standard(),
  });

  /// The prompt type id (also the `<type>.yaml` filename stem).
  final String id;

  /// The role this prompt type assumes (resolves a substrate
  /// `RoleTemplate`; not bound at load).
  final String role;

  /// The ordered `{config, provider}` routing/fallback chain.
  final List<PromptModelRef> models;

  /// The default tool allow-set for this prompt type.
  final List<String> tools;

  /// The default MCP servers for this prompt type.
  final List<String> mcpServers;

  /// The tool-permission profile, or `null` to use the global default.
  final ToolPolicyProfile? toolPolicy;

  /// The optional d4rt setup script the placeholder resolver runs first.
  final String? setup;

  /// The system scaffold, kept verbatim (placeholder-bearing).
  final String system;

  /// The user scaffold, kept verbatim (placeholder-bearing).
  final String user;

  /// The behavioural history flags for this prompt type (§ 22.6a). A missing
  /// `history:` block defaults to [HistoryPolicy.standard] (every flag on, the
  /// default compaction template), not an error.
  final HistoryPolicy history;

  /// Reads and parses a prompt template at [file].
  ///
  /// An absent file throws [PromptTemplateMissing] keyed by the filename
  /// stem. Structural problems throw [LlmConfigInvalid].
  static Future<PromptTemplateConfig> loadFromFile(File file) async {
    if (!await file.exists()) {
      throw PromptTemplateMissing(_stemOf(file.path), file.path);
    }
    return fromYamlString(await file.readAsString());
  }

  /// Parses a prompt template from [yamlText].
  ///
  /// A missing `id` / `role` / `system` / `user`, a missing or empty
  /// `models` chain, a malformed pair, an unknown `toolPolicy`, or a
  /// non-string `tools` / `mcpServers` entry each throw [LlmConfigInvalid]
  /// with a located [LlmConfigInvalid.path].
  static PromptTemplateConfig fromYamlString(String yamlText) {
    final doc = loadYamlAsMap(
      yamlText,
      rootPath: 'prompt_template',
      errorFactory: LlmConfigInvalid.new,
    );
    const reader = YamlConfigReader(
      env: <String, String>{},
      errorFactory: LlmConfigInvalid.new,
    );

    final id = reader.requireString(doc, 'id', 'prompt_template.id');
    final role = reader.requireString(doc, 'role', 'prompt_template.role');

    final rawModels =
        reader.requireList(doc, 'models', 'prompt_template.models');
    if (rawModels.isEmpty) {
      throw const LlmConfigInvalid(
        'models chain must not be empty',
        path: 'prompt_template.models',
      );
    }
    final models = <PromptModelRef>[];
    for (var i = 0; i < rawModels.length; i++) {
      final entry = rawModels[i];
      final path = 'prompt_template.models[$i]';
      if (entry is! Map<Object?, Object?>) {
        throw LlmConfigInvalid('must be a mapping', path: path);
      }
      models.add(PromptModelRef(
        config: reader.requireString(entry, 'config', '$path.config'),
        provider: reader.requireString(entry, 'provider', '$path.provider'),
      ));
    }

    final tools =
        _stringList(reader, doc, 'tools', 'prompt_template.tools');
    final mcpServers =
        _stringList(reader, doc, 'mcpServers', 'prompt_template.mcpServers');

    final rawPolicy =
        reader.optionalString(doc, 'toolPolicy', 'prompt_template.toolPolicy');
    final toolPolicy = rawPolicy == null
        ? null
        : ToolPolicyProfile.parse(rawPolicy, 'prompt_template.toolPolicy');

    final setup = reader.optionalString(doc, 'setup', 'prompt_template.setup');
    final system = reader.requireString(doc, 'system', 'prompt_template.system');
    final user = reader.requireString(doc, 'user', 'prompt_template.user');

    final history = HistoryPolicy.fromYamlBlock(
      reader.optionalMap(doc, 'history'),
      reader,
      'prompt_template.history',
    );

    return PromptTemplateConfig(
      id: id,
      role: role,
      models: List.unmodifiable(models),
      tools: List.unmodifiable(tools),
      mcpServers: List.unmodifiable(mcpServers),
      toolPolicy: toolPolicy,
      setup: setup,
      system: system,
      user: user,
      history: history,
    );
  }

  /// Walks the `models` chain and binds the first reachable
  /// `(config, provider)` pair.
  ///
  /// For each pair, in order:
  ///   • an unknown `provider` id (not in [providers]) is a hard, located
  ///     [LlmConfigInvalid];
  ///   • an unknown `config` id (absent from [store]) is a hard, located
  ///     [LlmConfigInvalid];
  ///   • a model that exists but is **not offered** on this provider (no
  ///     `providerNames` entry) is a *soft* fallback — try the next pair.
  /// When no pair names a model on its provider, throws a located
  /// [LlmConfigInvalid] at `prompt_template.models`.
  Future<ResolvedPromptModel> resolve(
    ProviderRegistry providers,
    ModelConfigStore store,
  ) async {
    for (var i = 0; i < models.length; i++) {
      final ref = models[i];
      final path = 'prompt_template.models[$i]';

      final provider = providers.maybeProvider(ref.provider);
      if (provider == null) {
        throw LlmConfigInvalid(
          'unknown provider id "${ref.provider}"',
          path: '$path.provider',
        );
      }

      final ModelConfig model;
      try {
        model = await store.load(ref.config);
      } on ModelConfigMissing catch (e) {
        throw LlmConfigInvalid(
          'unknown model config "${ref.config}" (${e.message})',
          path: '$path.config',
        );
      }

      final name = model.nameFor(ref.provider);
      if (name == null) {
        // Model exists but is not offered on this provider — soft fallback.
        continue;
      }
      return ResolvedPromptModel(
        provider: provider,
        modelName: name,
        model: model,
      );
    }
    throw LlmConfigInvalid(
      'no reachable (config, provider) pair: none of the ${models.length} '
      'pair(s) names a model on its provider',
      path: 'prompt_template.models',
    );
  }

  /// Reads an optional string list at [key], rejecting a non-string entry
  /// through a located [LlmConfigInvalid]. Absent ⇒ an empty list.
  static List<String> _stringList(
    YamlConfigReader reader,
    Map<Object?, Object?> node,
    String key,
    String path,
  ) {
    final raw = reader.optionalList(node, key, path);
    if (raw == null) return const <String>[];
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final value = raw[i];
      if (value is! String) {
        throw LlmConfigInvalid(
          'must be a string (got ${value.runtimeType})',
          path: '$path[$i]',
        );
      }
      out.add(value);
    }
    return out;
  }

  /// The filename stem (`assistant_to_user` for `…/assistant_to_user.yaml`).
  static String _stemOf(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }
}

/// Loads per-prompt-type templates from a `prompt_template/` directory by
/// type.
///
/// The directory convention is `prompt_template/<type>.yaml` (§ 21.5).
/// [load] resolves a type to that file and parses it; an absent file is
/// [PromptTemplateMissing].
final class PromptTemplateStore {
  /// Wraps the directory holding the `<type>.yaml` templates.
  const PromptTemplateStore(this.directory);

  /// The directory holding `<type>.yaml` prompt templates.
  final Directory directory;

  /// Loads the template named [promptType]
  /// (`<directory>/<promptType>.yaml`).
  ///
  /// Throws [PromptTemplateMissing] when the file is absent, or
  /// [LlmConfigInvalid] when it is malformed.
  Future<PromptTemplateConfig> load(String promptType) {
    final file =
        File('${directory.path}${Platform.pathSeparator}$promptType.yaml');
    return PromptTemplateConfig.loadFromFile(file);
  }
}
