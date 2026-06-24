// BrainRunConfigLoader — the whole-process config loader for the run assembly
// (Plan-2 step #31).
//
// The single YAML config file has sibling sections: `substrate:`, `memory:`,
// `engine:`, `dispatcher:`, `access:`, and the optional `trail:` block
// (`tom_brain_logging.md` §8). The access package's sub-barrel documents the
// design this loader realises:
//
//   "The other four sections are parsed by their own already-defined loaders
//    (SubstrateConfigLoader, MemoryConfigLoader, EngineConfig, DispatcherConfig)
//    at boot wiring (E.45)."
//
// This loader IS that boot wiring for the three sections the run assembly
// consumes. It owns no YAML key names of its own — it hands the *whole*
// document to each section loader, and each reads only its own top-level key:
//
//   * `substrate:` → `SubstrateConfigLoader.parse` (plain-map loader; reads
//     `doc['substrate']`, tolerates siblings).
//   * `memory:`    → `MemoryConfigLoader.parse` (reads `doc['memory']`,
//     tolerates siblings).
//   * `access:`    → `AccessConfigLoader.parse` (reads `doc['access']`;
//     additionally rejects any top-level key outside the allowed section set —
//     so a typo'd section name is caught here with a located error).
//   * `trail:`     → `TrailConfigLoader.parse` (reads `doc['trail']`; returns
//     `null` when the block is absent — unconfigured trail mode, §4.1).
//   * `tools:`     → `ToolsConfigLoader.parse` (reads `doc['tools']`; returns
//     `null` when absent — the engine's placeholder file-scope root; § 21.4).
//   * `mcpServers:` → `McpServersConfig.fromYamlString` (reads
//     `doc['mcpServers']`; an absent block yields an empty registry — the
//     cognition has no outbound MCP servers; § 21.3, § 21.6).
//   * `profiles:`  → `ProfileRegistry.fromYamlString` (reads `doc['profiles']`;
//     an absent block yields a registry with only the built-in `default`
//     profile — `session_configuration.md` § 3, SC-5).
//
// Each section loader produces a *located* error (dotted key path) on its own
// malformed or missing section, so the whole-process loader needs no error
// plumbing of its own: a bad `substrate:` surfaces as `SubstrateConfigException`,
// a bad `memory:` as `MemoryConfigException`, a bad / unknown section as
// `AccessConfigException`.
//
// Why re-parse the same content three times (rather than parse once, split):
//
//   * Each section loader owns the conversion from YAML to its typed model,
//     including `${ENV}` expansion, plain-map-vs-YamlMap discipline, and its
//     own cross-section invariants. Splitting the document here and feeding
//     fragments would fork that ownership — the run package would have to know
//     each section's key name and re-implement the "missing section" error.
//     Re-parsing keeps each loader the single authority over its own shape.
//   * The cost is three YAML parses of one small config file at process boot —
//     paid once, never on a hot path.

import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart'
    show AccessConfig, AccessConfigLoader;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, MemoryConfigLoader;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpServersConfig;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show HistoryConfig, HistoryConfigError;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig, SubstrateConfigLoader;
import 'package:tom_core_agentic/tom_core_agentic.dart' show loadYamlAsMap;

import 'brain_run_config.dart';
import 'cognition_run_config.dart';
import 'cognition_run_config_loader.dart';
import 'dream_config.dart';
import 'dream_config_loader.dart';
import 'profile/profile_registry.dart';
import 'scripts_config.dart';
import 'scripts_config_loader.dart';
import 'tools_config.dart';
import 'tools_config_loader.dart';
import 'trail_config.dart';
import 'trail_config_loader.dart';

/// Parses the whole-process YAML config into a [BrainRunConfig] by delegating
/// each section to its owning loader (Plan-2 step #31).
///
/// Namespace-only class (all members static): the loader has no per-instance
/// state.
abstract final class BrainRunConfigLoader {
  BrainRunConfigLoader._();

  /// Parses the YAML [content] into a fully-populated [BrainRunConfig].
  ///
  /// Hands the whole document to each section loader in turn; each reads its
  /// own top-level key and surfaces a located error on a malformed / missing
  /// section. [envVars] is forwarded to every section loader to expand
  /// `${NAME}` tokens (typically `Platform.environment`).
  ///
  /// [basePath] is the config file's directory, forwarded to
  /// [SubstrateConfigLoader.parse] so a relative `substrate.providersDir` /
  /// `substrate.modelsDir` resolves against it (CLI plan step 2). It is set by
  /// [loadFromFile]; tests pass it explicitly when exercising the aspect-dir
  /// split.
  ///
  /// Pure for the inline shape: no I/O, no clock. Reads the substrate aspect
  /// directories only when `providersDir` / `modelsDir` are configured.
  ///
  /// Throws `SubstrateConfigException` / `MemoryConfigException` /
  /// `AccessConfigException` (the owning loader's type) on a section that does
  /// not match its schema.
  static BrainRunConfig parse(
    String content, {
    Map<String, String> envVars = const {},
    String? basePath,
  }) {
    final SubstrateConfig substrate = SubstrateConfigLoader.parse(
      content,
      envVars: envVars,
      basePath: basePath,
    );
    final MemoryConfig memory =
        MemoryConfigLoader.parse(content, envVars: envVars);
    final AccessConfig access =
        AccessConfigLoader.parse(content, envVars: envVars);
    final TrailConfig? trail =
        TrailConfigLoader.parse(content, envVars: envVars);
    final ToolsConfig? tools =
        ToolsConfigLoader.parse(content, envVars: envVars);
    final ScriptsConfig? scripts =
        ScriptsConfigLoader.parse(content, envVars: envVars);
    final DreamConfig? dream =
        DreamConfigLoader.parse(content, envVars: envVars);
    final CognitionRunConfig? cognition =
        CognitionRunConfigLoader.parse(content, envVars: envVars);
    final McpServersConfig mcpServers =
        McpServersConfig.fromYamlString(content);
    final ProfileRegistry profiles = ProfileRegistry.fromYamlString(
      content,
      envVars: envVars,
      basePath: basePath,
    );
    final HistoryConfig history = _parseHistory(content);
    return BrainRunConfig(
      substrate: substrate,
      memory: memory,
      access: access,
      trail: trail,
      tools: tools,
      scripts: scripts,
      dream: dream,
      cognition: cognition,
      mcpServers: mcpServers,
      history: history,
      profiles: profiles,
    );
  }

  /// Parses the top-level `history:` block into a [HistoryConfig] (hub
  /// § 22.6b/c). An absent block yields [HistoryConfig.standard]; a below-floor
  /// knob surfaces the located [HistoryConfigError]'s message as a
  /// [BrainRunConfigException]. The access loader resolves the `foreground` lane
  /// from the same block independently (decision HC-3); this whole config sizes
  /// the dreaming lanes' prior-run windows (todo #14).
  static HistoryConfig _parseHistory(String content) {
    final Map<String, Object?> doc = loadYamlAsMap(
      content,
      errorFactory: BrainRunConfigException.new,
    );
    final block = doc['history'];
    if (block != null && block is! Map<String, Object?>) {
      throw const BrainRunConfigException(
        'Top-level `history:` must be a map when present.',
      );
    }
    try {
      return HistoryConfig.fromConfigMap(block as Map<String, Object?>?);
    } on HistoryConfigError catch (e) {
      throw BrainRunConfigException(e.toString());
    }
  }

  /// Loads the YAML file at [path] and parses it via [parse].
  ///
  /// Production callers go through this entry point; tests use [parse] with
  /// inline content. The file is read once and the same content is handed to
  /// every section loader.
  static BrainRunConfig loadFromFile(
    String path, {
    Map<String, String> envVars = const {},
  }) {
    final File file = File(path);
    if (!file.existsSync()) {
      throw BrainRunConfigException('Config file not found: $path');
    }
    return parse(
      file.readAsStringSync(),
      envVars: envVars,
      basePath: file.absolute.parent.path,
    );
  }
}

/// Thrown for whole-process-level config failures the section loaders cannot
/// own — currently only "config file not found" from [BrainRunConfigLoader
/// .loadFromFile].
///
/// Section-level failures surface as the owning loader's exception
/// (`SubstrateConfigException` / `MemoryConfigException` /
/// `AccessConfigException`) so the located key path is preserved.
class BrainRunConfigException implements Exception {
  /// Human-readable explanation.
  final String message;

  /// Builds the exception with a [message].
  const BrainRunConfigException(this.message);

  @override
  String toString() => 'BrainRunConfigException: $message';
}
