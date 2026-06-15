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

import 'llm_route_config.dart';

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

  /// The substrate role whose persona/objective wrap the prompt and whose
  /// assistant-dedication anchor is enforced on every call (§5.4). Selects
  /// persona + anchor + provenance only, *not* the LLM route (that is [llm],
  /// §8). Always resolves: falls back to `assistant_to_user` when unset anywhere
  /// in the inheritance chain (principle 5 / Postulate 3).
  final String role;

  /// Optional structured-output schema (maps to `LlmOptions.responseFormat`).
  final Map<String, Object?>? responseFormat;

  /// Optional generation stop sequences.
  final List<String>? stopSequences;

  /// Optional delivery channel (§9.2): `thinking` keeps the prompt's tokens off
  /// the user stream; `null` (the default) lets the engine route by role. A
  /// no-tool, answer-role completion turn (the DONE/CONTINUE confirmation) sets
  /// `thinking` so its verdict does not leak to the user.
  final String? channel;

  /// Binds the resolved settings. [role] defaults to `assistant_to_user` (the
  /// §5.4 chain fallback).
  const PromptSettings({
    this.temperature,
    this.maxToolLoops,
    this.tools,
    this.llm,
    this.role = 'assistant_to_user',
    this.responseFormat,
    this.stopSequences,
    this.channel,
  });
}

/// One resolved template file: its cognition-root-relative [path] and whether it
/// is [present] on disk (§8 step 8 / `prompt_configuration.md` §13.1).
///
/// An absent half of a prompt pair (`present == false`) renders to the empty
/// string at assembly time. A fragment's single file — and at least one half of
/// every prompt — is always `present` (the loader fails fast otherwise).
final class ResolvedTemplateFile {
  /// The path relative to the cognition root (`<folder>/<stem>.<suffix>`).
  final String path;

  /// Whether the file exists on disk.
  final bool present;

  /// Binds the resolved file.
  const ResolvedTemplateFile({required this.path, required this.present});

  @override
  bool operator ==(Object other) =>
      other is ResolvedTemplateFile &&
      other.path == path &&
      other.present == present;

  @override
  int get hashCode => Object.hash(path, present);

  @override
  String toString() => 'ResolvedTemplateFile(path: $path, present: $present)';
}

/// How a registered template's `template:` *stem* resolved to file(s) on disk
/// (§8 step 8). A closed alphabet of two forms mirroring [PromptKind]:
/// [PromptTemplateFiles] (a `kind: prompt` `<stem>.system.md` + `<stem>.user.md`
/// pair) and [FragmentTemplateFiles] (a `kind: fragment` single `<stem>.md`).
sealed class TemplateResolution {
  const TemplateResolution();
}

/// A `kind: prompt` template resolved to its `<stem>.system.md` +
/// `<stem>.user.md` pair. Either half may be absent (→ empty string); the loader
/// fails fast when *neither* half is present.
final class PromptTemplateFiles extends TemplateResolution {
  /// The standing-framing half (`<stem>.system.md`).
  final ResolvedTemplateFile system;

  /// The call-specific half (`<stem>.user.md`).
  final ResolvedTemplateFile user;

  /// Binds the pair.
  const PromptTemplateFiles({required this.system, required this.user});

  @override
  bool operator ==(Object other) =>
      other is PromptTemplateFiles &&
      other.system == system &&
      other.user == user;

  @override
  int get hashCode => Object.hash(system, user);

  @override
  String toString() => 'PromptTemplateFiles(system: $system, user: $user)';
}

/// A `kind: fragment` template resolved to its single `<stem>.md`.
final class FragmentTemplateFiles extends TemplateResolution {
  /// The single fragment file (`<stem>.md`).
  final ResolvedTemplateFile file;

  /// Binds the single file.
  const FragmentTemplateFiles(this.file);

  @override
  bool operator ==(Object other) =>
      other is FragmentTemplateFiles && other.file == file;

  @override
  int get hashCode => file.hashCode;

  @override
  String toString() => 'FragmentTemplateFiles(file: $file)';
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

  /// The resolved template file(s) — a `<stem>.system.md` + `<stem>.user.md`
  /// pair for a [PromptKind.prompt], a single `<stem>.md` for a
  /// [PromptKind.fragment] (§8 step 8). The `template:` config value is the stem.
  final TemplateResolution template;

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
    required this.template,
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

  /// The named LLM route configs loaded from `cognition/llm/`, keyed by route
  /// name (§8 / §8.1). Empty when no `llm/` folder was loaded.
  final Map<String, LlmRouteConfig> llmRoutes;

  /// Binds the parsed config.
  const CognitionConfig({
    required this.registry,
    required this.prompts,
    required this.llmRoutes,
  });

  /// Every registered prompt ID.
  List<String> get promptIds => prompts.keys.toList();

  /// Every loaded LLM route name.
  List<String> get llmRouteNames => llmRoutes.keys.toList();

  /// Resolves [id] to its [ResolvedPrompt].
  ///
  /// Throws [UnregisteredPromptException] when [id] is not registered — the
  /// §7.3 "unregistered prompt ID is a hard error" rule.
  ResolvedPrompt resolve(String id) {
    final prompt = prompts[id];
    if (prompt == null) throw UnregisteredPromptException(id);
    return prompt;
  }

  /// Resolves a route [name] to its [LlmRouteConfig].
  ///
  /// Throws [UnknownLlmRouteException] when [name] is not among [llmRoutes]
  /// (§8.1 — a prompt may only reference a loaded route).
  LlmRouteConfig route(String name) {
    final r = llmRoutes[name];
    if (r == null) throw UnknownLlmRouteException(name);
    return r;
  }

  /// The route a [prompt] uses — its inherited `llm:` setting (§5.4) resolved to
  /// a route config. Throws [UnknownLlmRouteException] when the prompt carries no
  /// `llm:` or references a route that was not loaded.
  LlmRouteConfig routeForPrompt(ResolvedPrompt prompt) {
    final name = prompt.settings.llm;
    if (name == null) {
      throw UnknownLlmRouteException('<unset on ${prompt.id}>');
    }
    return route(name);
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
