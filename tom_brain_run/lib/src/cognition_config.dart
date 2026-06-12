// Cognition config value types — increment 3 of `prompt_configuration.md`
// (§4 *The registry*, §5 *Main-procedure config & hierarchical IDs* + §5.5
// *Realisation*).
//
// These are the typed result of parsing the cognition config root: the
// `CognitionRegistry` (the `registry.yaml` index of procedures + role/llm
// folders) and a `CognitionConfig` holding a flat map of `ResolvedPrompt`s keyed
// by the full `<main>.<sub>.<prompt>` ID. Each `ResolvedPrompt` carries a
// fully-inherited `PromptSettings` — inheritance (prompt → sub-procedure →
// main-procedure → registry llm default) is resolved at load time by
// `CognitionConfigLoader`, so consumers read a single flat record, never a chain.
//
// Pure data: no I/O, no YAML node types. `CognitionConfigLoader` owns the parse.

/// Whether a registered template is a full prompt (sent on its own) or a
/// reusable fragment (rendered and injected via a placeholder).
enum PromptKind {
  /// A full prompt — assembled and sent to the LLM (the default).
  prompt,

  /// A reusable fragment — rendered into another prompt, never sent alone.
  fragment,
}

/// The resolved tool set for a prompt (§5.4 `tools`).
///
/// A sealed alphabet of four forms: [ToolsAll] / [ToolsReadonly] / [ToolsNone]
/// (the three keyword forms) and [ToolsExplicit] (a named list). The three
/// keyword forms are const value-equal singletons; [ToolsExplicit] carries its
/// list and compares by identity (consumers match it with `is`).
sealed class ToolsSetting {
  const ToolsSetting();
}

/// `tools: all` — the full catalogue.
final class ToolsAll extends ToolsSetting {
  /// The single const form.
  const ToolsAll();

  @override
  bool operator ==(Object other) => other is ToolsAll;

  @override
  int get hashCode => (ToolsAll).hashCode;

  @override
  String toString() => 'ToolsAll()';
}

/// `tools: readonly` — read-only tools only.
final class ToolsReadonly extends ToolsSetting {
  /// The single const form.
  const ToolsReadonly();

  @override
  bool operator ==(Object other) => other is ToolsReadonly;

  @override
  int get hashCode => (ToolsReadonly).hashCode;

  @override
  String toString() => 'ToolsReadonly()';
}

/// `tools: none` — an empty catalogue (no tool access).
final class ToolsNone extends ToolsSetting {
  /// The single const form.
  const ToolsNone();

  @override
  bool operator ==(Object other) => other is ToolsNone;

  @override
  int get hashCode => (ToolsNone).hashCode;

  @override
  String toString() => 'ToolsNone()';
}

/// `tools: [a, b, …]` — an explicit list of tool names.
final class ToolsExplicit extends ToolsSetting {
  /// The named tools, in declaration order.
  final List<String> names;

  /// Binds the explicit [names].
  const ToolsExplicit(this.names);

  @override
  String toString() => 'ToolsExplicit($names)';
}

/// A main procedure as registered in `registry.yaml`: its config file and its
/// config/template folder (§4).
final class RegisteredProcedure {
  /// The procedure name (the `procedures` map key, = the ID's first segment).
  final String name;

  /// The settings file, relative to the cognition root (e.g. `assist_user.yaml`).
  final String configFile;

  /// The config/template folder, relative to the cognition root.
  final String folder;

  /// Binds the three registry fields.
  const RegisteredProcedure({
    required this.name,
    required this.configFile,
    required this.folder,
  });
}

/// The parsed `registry.yaml` — the index of everything in the cognition root
/// (§4).
final class CognitionRegistry {
  /// Registered main procedures, keyed by name.
  final Map<String, RegisteredProcedure> procedures;

  /// The role persona/objective template folder, relative to the cognition root.
  final String rolesFolder;

  /// The cross-procedure LLM route-config folder, relative to the cognition root.
  final String llmFolder;

  /// The route-config name used when a prompt/procedure sets no `llm:`.
  final String llmDefault;

  /// Binds the registry fields.
  const CognitionRegistry({
    required this.procedures,
    required this.rolesFolder,
    required this.llmFolder,
    required this.llmDefault,
  });
}

/// The fully-inherited LLM/tool settings for one prompt (§5.4).
///
/// Every field is the *resolved* value after the prompt → sub → main → registry
/// inheritance chain. A field is `null` only when nothing in the chain set it
/// (the engine applies its own runtime default later); `llm` is the one
/// exception — it always resolves, falling back to the registry default.
final class PromptSettings {
  /// Sampling temperature, or `null` when unset anywhere in the chain.
  final double? temperature;

  /// The engine's per-prompt tool-loop cap, or `null` when unset.
  final int? maxToolLoops;

  /// The resolved tool set, or `null` when unset.
  final ToolsSetting? tools;

  /// The resolved LLM route-config name (always set: falls back to the registry
  /// default).
  final String? llm;

  /// Optional structured-output schema (maps to `LlmOptions.responseFormat`).
  final Map<String, Object?>? responseFormat;

  /// Optional generation stop sequences.
  final List<String>? stopSequences;

  /// Binds the resolved settings.
  const PromptSettings({
    this.temperature,
    this.maxToolLoops,
    this.tools,
    this.llm,
    this.responseFormat,
    this.stopSequences,
  });
}

/// One registered prompt, flattened to its full ID plus resolved settings (§5).
final class ResolvedPrompt {
  /// The full `<main>.<sub>.<prompt>` ID.
  final String id;

  /// The main-procedure segment (the config file).
  final String mainProcedure;

  /// The sub-procedure segment (maps to a d4rt script).
  final String subProcedure;

  /// The prompt-name segment.
  final String promptName;

  /// The template path, relative to the cognition root (`<folder>/<template>`).
  final String templatePath;

  /// Whether this is a full prompt or a reusable fragment.
  final PromptKind kind;

  /// The fully-inherited settings.
  final PromptSettings settings;

  /// Binds the resolved prompt.
  const ResolvedPrompt({
    required this.id,
    required this.mainProcedure,
    required this.subProcedure,
    required this.promptName,
    required this.templatePath,
    required this.kind,
    required this.settings,
  });
}

/// The parsed cognition config: the [registry] plus every [ResolvedPrompt]
/// flattened by full ID (§5.5 *Realisation*).
final class CognitionConfig {
  /// The parsed `registry.yaml`.
  final CognitionRegistry registry;

  /// Every registered prompt, keyed by full `<main>.<sub>.<prompt>` ID.
  final Map<String, ResolvedPrompt> prompts;

  /// Binds the parsed config.
  const CognitionConfig({
    required this.registry,
    required this.prompts,
  });

  /// Every registered prompt ID.
  List<String> get promptIds => prompts.keys.toList();

  /// Resolves [id] to its [ResolvedPrompt].
  ///
  /// Throws [UnregisteredPromptException] when [id] is not registered — the
  /// §7.3 "unregistered prompt ID is a hard error" rule.
  ResolvedPrompt resolve(String id) {
    final prompt = prompts[id];
    if (prompt == null) throw UnregisteredPromptException(id);
    return prompt;
  }
}

/// Thrown when a cognition config (registry or main-procedure file) is malformed
/// — a missing `template`, a duplicate mapping key, an unknown setting key, a
/// missing referenced config, or any located shape error (§7.3 "fail fast at
/// boot").
class CognitionConfigException implements Exception {
  /// Human-readable, located explanation.
  final String message;

  /// Builds the exception with a [message].
  const CognitionConfigException(this.message);

  @override
  String toString() => 'CognitionConfigException: $message';
}

/// Thrown by [CognitionConfig.resolve] when a prompt ID is not in the registry
/// (§7.3 — fatal to the run).
class UnregisteredPromptException implements Exception {
  /// The unregistered prompt ID.
  final String promptId;

  /// Builds the exception for [promptId].
  const UnregisteredPromptException(this.promptId);

  @override
  String toString() =>
      'UnregisteredPromptException: no registered prompt "$promptId".';
}
