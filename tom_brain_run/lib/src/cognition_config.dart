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

  /// The editable catalogue (`prompt_configuration.md` §13.4 / plan step 13):
  /// every registered template with its resolved file path(s) + per-half
  /// present/empty flags, the role prose files, and the config-file inventory.
  /// This is the data the observatory catalogue route (plan step 14) serves —
  /// derived purely from this config, no I/O.
  ///
  /// Templates are listed in ID order; their present/empty flags are the ones
  /// the loader already resolved (§8 step 8). Roles are the distinct `role:`
  /// values across every prompt plus the foundational `assistant_to_user`
  /// default (so the anchor-bearing role is always editable), in name order;
  /// their persona/objective files are listed by path under the registry roles
  /// folder — present/empty is resolved by the observatory file route when the
  /// file is read (an absent half is offered as an empty document, step 15).
  /// The config inventory lists `registry.yaml`, each registered procedure
  /// config, each loaded `llm/<name>.yaml` route config, and the `substrate:`
  /// block (located by [substrateConfigFile], default `brain_run.yaml`, and its
  /// within-file `substrate` key).
  CognitionCatalogue catalogue({String substrateConfigFile = 'brain_run.yaml'}) {
    final List<String> ids = prompts.keys.toList()..sort();
    final List<CatalogueTemplate> templates = <CatalogueTemplate>[
      for (final id in ids)
        CatalogueTemplate(
          id: id,
          kind: prompts[id]!.kind,
          files: _catalogueFilesOf(prompts[id]!.template),
        ),
    ];

    final Set<String> roleNames = <String>{
      'assistant_to_user',
      for (final prompt in prompts.values) prompt.settings.role,
    };
    final List<CatalogueRole> roles = <CatalogueRole>[
      for (final name in roleNames.toList()..sort())
        CatalogueRole(
          name: name,
          personaPath: '${registry.rolesFolder}/$name.persona.md',
          objectivePath: '${registry.rolesFolder}/$name.objective.md',
        ),
    ];

    final List<String> procNames = registry.procedures.keys.toList()..sort();
    final List<String> routeNames = llmRoutes.keys.toList()..sort();
    final List<CatalogueConfigFile> configFiles = <CatalogueConfigFile>[
      const CatalogueConfigFile(
        kind: CatalogueConfigKind.registry,
        name: 'registry',
        path: 'registry.yaml',
      ),
      for (final name in procNames)
        CatalogueConfigFile(
          kind: CatalogueConfigKind.procedure,
          name: name,
          path: registry.procedures[name]!.configFile,
        ),
      for (final name in routeNames)
        CatalogueConfigFile(
          kind: CatalogueConfigKind.llm,
          name: name,
          path: '${registry.llmFolder}/$name.yaml',
        ),
      CatalogueConfigFile(
        kind: CatalogueConfigKind.substrate,
        name: 'substrate',
        path: substrateConfigFile,
        location: 'substrate',
      ),
    ];

    return CognitionCatalogue(
      templates: templates,
      roles: roles,
      configFiles: configFiles,
    );
  }

  static List<CatalogueTemplateFile> _catalogueFilesOf(TemplateResolution t) {
    switch (t) {
      case PromptTemplateFiles(:final system, :final user):
        return <CatalogueTemplateFile>[
          CatalogueTemplateFile(
            path: system.path,
            part: CataloguePart.system,
            present: system.present,
          ),
          CatalogueTemplateFile(
            path: user.path,
            part: CataloguePart.user,
            present: user.present,
          ),
        ];
      case FragmentTemplateFiles(:final file):
        return <CatalogueTemplateFile>[
          CatalogueTemplateFile(
            path: file.path,
            part: CataloguePart.fragment,
            present: file.present,
          ),
        ];
    }
  }
}

/// Which editable slot a catalogue template file plays (§13.4 / plan step 13).
/// Mirrors the template half of the observatory `/api/templates?part=` alphabet
/// (plan step 15); the `persona`/`objective` parts of that alphabet are role
/// files, carried by [CatalogueRole] rather than this enum.
enum CataloguePart {
  /// The standing-framing half of a `kind: prompt` pair (`<stem>.system.md`).
  system,

  /// The call-specific half of a `kind: prompt` pair (`<stem>.user.md`).
  user,

  /// The single file of a `kind: fragment` template (`<stem>.md`).
  fragment,
}

/// What kind of config file a [CatalogueConfigFile] points at (§13.4).
enum CatalogueConfigKind {
  /// `registry.yaml`.
  registry,

  /// A per-main-procedure config (`<proc>.yaml`).
  procedure,

  /// A per-route LLM config (`llm/<name>.yaml`).
  llm,

  /// The `substrate:` block in the run config file.
  substrate,
}

/// One template file in the editable catalogue: its cognition-root-relative
/// [path], the [part] it plays, and whether it is [present] on disk (§13.4).
///
/// An absent half of a prompt pair (`present == false`) is offered to the
/// observatory editor as an empty document the operator can fill in (plan
/// step 15).
final class CatalogueTemplateFile {
  /// The path relative to the cognition root.
  final String path;

  /// The editable slot this file plays.
  final CataloguePart part;

  /// Whether the file exists on disk.
  final bool present;

  /// Binds the catalogue template file.
  const CatalogueTemplateFile({
    required this.path,
    required this.part,
    required this.present,
  });

  @override
  bool operator ==(Object other) =>
      other is CatalogueTemplateFile &&
      other.path == path &&
      other.part == part &&
      other.present == present;

  @override
  int get hashCode => Object.hash(path, part, present);

  @override
  String toString() =>
      'CatalogueTemplateFile(path: $path, part: ${part.name}, '
      'present: $present)';
}

/// One registered template, flattened for the catalogue (§13.4): its full [id],
/// [kind], and resolved [files] — a `system` + `user` pair for a
/// [PromptKind.prompt], a single `fragment` file for a [PromptKind.fragment],
/// each with its present/empty flag.
final class CatalogueTemplate {
  /// The full `<main>.<sub>.<prompt>` ID.
  final String id;

  /// Whether this is a full prompt or a reusable fragment.
  final PromptKind kind;

  /// The resolved files (one for a fragment, two for a prompt pair).
  final List<CatalogueTemplateFile> files;

  /// Binds the catalogue template.
  const CatalogueTemplate({
    required this.id,
    required this.kind,
    required this.files,
  });

  @override
  String toString() =>
      'CatalogueTemplate(id: $id, kind: ${kind.name}, files: $files)';
}

/// A role's externalised prose files (§13.4 / increment 8): the cognition-root-
/// relative persona/objective paths under the registry roles folder. Listed by
/// path only — present/empty is resolved by the observatory file route when the
/// file is read (an absent half falls back per increment 8; plan step 15).
final class CatalogueRole {
  /// The role name (e.g. `assistant_to_user`).
  final String name;

  /// The persona prose path (`<rolesFolder>/<name>.persona.md`).
  final String personaPath;

  /// The objective prose path (`<rolesFolder>/<name>.objective.md`).
  final String objectivePath;

  /// Binds the catalogue role.
  const CatalogueRole({
    required this.name,
    required this.personaPath,
    required this.objectivePath,
  });

  @override
  String toString() =>
      'CatalogueRole(name: $name, persona: $personaPath, '
      'objective: $objectivePath)';
}

/// One config-file inventory entry (§13.4): the registry, a per-procedure
/// config, a per-route llm config, or the `substrate:` block.
final class CatalogueConfigFile {
  /// What kind of config this entry points at.
  final CatalogueConfigKind kind;

  /// The entry name: `registry` / the procedure name / the route name /
  /// `substrate`.
  final String name;

  /// The file path. Cognition-root-relative for registry/procedure/llm; the run
  /// config file (default `brain_run.yaml`) for the substrate block.
  final String path;

  /// A within-file key for entries that are a *block* of a larger file rather
  /// than a whole file — `substrate` for the substrate block; `null` otherwise.
  final String? location;

  /// Binds the catalogue config entry.
  const CatalogueConfigFile({
    required this.kind,
    required this.name,
    required this.path,
    this.location,
  });

  @override
  String toString() => 'CatalogueConfigFile(kind: ${kind.name}, name: $name, '
      'path: $path, location: $location)';
}

/// The editable catalogue exposed from [CognitionConfig.catalogue] (§13.4 / plan
/// step 13): every registered [templates] with its resolved files + present
/// flags, the [roles] prose files, and the [configFiles] inventory. This is the
/// data the observatory catalogue route (plan step 14) serves.
final class CognitionCatalogue {
  /// Every registered template, in ID order.
  final List<CatalogueTemplate> templates;

  /// Every referenced role's prose files, in name order.
  final List<CatalogueRole> roles;

  /// The config-file inventory.
  final List<CatalogueConfigFile> configFiles;

  /// Binds the catalogue.
  const CognitionCatalogue({
    required this.templates,
    required this.roles,
    required this.configFiles,
  });
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
