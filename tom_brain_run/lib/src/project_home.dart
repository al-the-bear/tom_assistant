// ProjectHome — the `--home`/`agent` resolver (CLI plan step #6;
// `tom_brain_cli.md` § 2 / § 6 / § 8).
//
// A standalone or embedded brain confines all its files to one project folder.
// `--home <dir>` (default: the current working directory) names the *host*
// project root; the brain's own files default into an `agent/` subdirectory of
// it — the *agent root*, `<agent> = <home>/agent`, relocatable with
// `--agent-dir` (CLI-Q14). Every brain directory then defaults under `<agent>/`:
//
//   memory/   trail/   history/   edge/   scratchpad/   bin/sqlite_vec/
//   providers/   models/   profiles/   prompts/   scripts/
//
// `ProjectHome` is the resolver for that convention. It owns two layers of the
// precedence ladder (§ 6):
//
//   CLI flag (an explicit override)  >  <home>/agent convention
//
// The middle layer — an explicit value in the *config file* — is applied by
// [buildConfig], which deep-merges the convention overlay UNDER the user's base
// config so a value the file already sets wins over the convention, while an
// override (a CLI flag) wins over both. The remaining ladder rungs (`${env:…}`
// expansion on flag values, the bundled / built-in defaults, the `--config`
// additive merge) are owned by later CLI plan steps (#7, #8).
//
// What `ProjectHome` does NOT do: it never reads a config file, never expands
// `${env:…}` (step #7), and never resolves the sqlite-vec native library
// fallback chain (step #7/#8). It is a pure path resolver plus an on-demand
// writable-directory creator plus a config-overlay assembler.

import 'dart:io';

import 'package:tom_core_agentic/tom_core_agentic.dart' show loadYamlAsMap;

import 'brain_run_config.dart';
import 'brain_run_config_loader.dart';
import 'cli/config_overlay.dart';

/// Which layer of the precedence ladder (§ 6) supplied a resolved path.
///
/// `ProjectHome` owns the two outer layers it can see from `--home` /
/// `--agent-dir` / overrides alone; the config-file layer is resolved later by
/// [ProjectHome.buildConfig]'s deep-merge.
enum PathLayer {
  /// An explicit CLI-flag override beat the convention.
  flag,

  /// The `<home>/agent` convention supplied the value (no override).
  convention,
}

/// One resolved brain path and the [PathLayer] that supplied it — the
/// boot-time "logs each resolved layer" record (§ 6).
final class ResolvedPath {
  /// Builds a resolution record for [aspect] = [value] from [layer].
  const ResolvedPath(this.aspect, this.value, this.layer);

  /// The dotted config key this path lands on (e.g. `memory.root`).
  final String aspect;

  /// The resolved absolute (or override-supplied) path.
  final String value;

  /// Which precedence layer won.
  final PathLayer layer;

  @override
  String toString() => '$aspect = $value (${layer.name})';
}

/// Per-aspect / per-path overrides — the resolved CLI-flag values, each `null`
/// when the flag was not given (CLI plan § 5.2). An override beats the
/// `<home>/agent` convention and (in [ProjectHome.buildConfig]) an explicit
/// value in the base config file.
///
final class HomeOverrides {
  /// Builds an override set; every field defaults to "not overridden".
  const HomeOverrides({
    this.memoryRoot,
    this.trailRoot,
    this.historyDir,
    this.edgeDir,
    this.providersDir,
    this.modelsDir,
    this.profilesDir,
    this.mcpServersDir,
    this.promptsDir,
    this.scriptsSystemDir,
    this.sqliteVecBinariesRoot,
    this.writeScope,
    this.readScope,
  });

  /// `--memory-dir` → `memory.root`.
  final String? memoryRoot;

  /// `--trail-dir` → `trail.root`.
  final String? trailRoot;

  /// `--history-dir` → `access.history.directory`.
  final String? historyDir;

  /// `--edge-dir` → `access.edgeState.directory`.
  final String? edgeDir;

  /// `--providers` → `substrate.providersDir`.
  final String? providersDir;

  /// `--models` → `substrate.modelsDir`.
  final String? modelsDir;

  /// `--profiles` → top-level `profilesDir`.
  final String? profilesDir;

  /// `--mcp` → top-level `mcpServersDir`.
  final String? mcpServersDir;

  /// `--prompts` → `cognition.root`.
  final String? promptsDir;

  /// `--scripts` → `scripts.systemDir`.
  final String? scriptsSystemDir;

  /// `--sqlite-vec` → `memory.sqliteVec.binariesRoot`.
  final String? sqliteVecBinariesRoot;

  /// `--write-scope` (repeatable) → `tools.writeScope`.
  final List<String>? writeScope;

  /// `--read-scope` (repeatable) → `tools.readScope`.
  final List<String>? readScope;
}

/// Resolves the `--home`/`agent` directory convention (§ 2) into fully-pathed
/// brain directories and, via [buildConfig], a complete [BrainRunConfig].
///
/// Construction is pure: it computes the agent root and absolutises `--home`
/// but touches no filesystem. [ensureWritableDirs] creates the writable tree on
/// demand; [buildConfig] overlays the convention under a base config and parses
/// the result.
final class ProjectHome {
  /// Builds a resolver for host project [home] (relative paths are resolved
  /// against the current working directory), with the agent root at
  /// [agentDir] (default `<home>/agent`) and the CLI-flag [overrides].
  ProjectHome({
    required String home,
    String? agentDir,
    this.overrides = const HomeOverrides(),
  })  : home = _absolute(home),
        agentRoot = agentDir == null
            ? _join(_absolute(home), 'agent')
            : _absolute(agentDir);

  /// The host project root (absolute) — the default file-tool read scope.
  final String home;

  /// The agent root (absolute) — every brain directory defaults under it.
  final String agentRoot;

  /// The resolved CLI-flag overrides.
  final HomeOverrides overrides;

  // ── Resolved brain paths (override > convention) ──────────────────────

  /// `memory.root` — the SQLite databases, vectors, trails, and JSON stores.
  String get memoryRoot => overrides.memoryRoot ?? _underAgent('memory');

  /// `trail.root` — the prompt-tracing trail the Observatory reads.
  String get trailRoot => overrides.trailRoot ?? _underAgent('trail');

  /// `access.history.directory` — durable conversation histories.
  String get historyDir => overrides.historyDir ?? _underAgent('history');

  /// `access.edgeState.directory` — the edge limiters' persisted state.
  String get edgeDir => overrides.edgeDir ?? _underAgent('edge');

  /// `tools.writeScope` default root — the brain's own scratch tree. Not
  /// independently relocatable (only `--write-scope` overrides the scope list).
  String get scratchpadDir => _underAgent('scratchpad');

  /// `substrate.providersDir` — connection definitions.
  String get providersDir => overrides.providersDir ?? _underAgent('providers');

  /// `substrate.modelsDir` — role→model routing + embedding.
  String get modelsDir => overrides.modelsDir ?? _underAgent('models');

  /// top-level `profilesDir` — session-profile config.
  String get profilesDir => overrides.profilesDir ?? _underAgent('profiles');

  /// top-level `mcpServersDir` — external MCP-server definitions.
  String get mcpServersDir => overrides.mcpServersDir ?? _underAgent('mcp');

  /// `cognition.root` — the prompt registry, roles, and overlays.
  String get promptsDir => overrides.promptsDir ?? _underAgent('prompts');

  /// `scripts.systemDir` — the procedure d4rt scripts.
  String get scriptsSystemDir =>
      overrides.scriptsSystemDir ?? _underAgent('scripts');

  /// `memory.sqliteVec.binariesRoot` on-disk default (`<agent>/bin/sqlite_vec`).
  /// The full sqlite-vec fallback chain (§ 7) is wired in a later step; the
  /// convention does not inject this into [buildConfig].
  String get sqliteVecBinariesRoot =>
      overrides.sqliteVecBinariesRoot ?? _join(agentRoot, 'bin/sqlite_vec');

  /// `tools.writeScope` — defaults to `[<agent>/scratchpad]` (§ 8).
  List<String> get writeScope => overrides.writeScope ?? <String>[scratchpadDir];

  /// `tools.readScope` — defaults to `[<home>]`, the whole host project (§ 8).
  List<String> get readScope => overrides.readScope ?? <String>[home];

  /// The boot-time "logs each resolved layer" record (§ 6): one entry per
  /// resolved path, in a stable order, marking whether a flag override or the
  /// convention won.
  List<ResolvedPath> get resolutionLog => <ResolvedPath>[
        _layer('memory.root', memoryRoot, overrides.memoryRoot),
        _layer('trail.root', trailRoot, overrides.trailRoot),
        _layer('history.directory', historyDir, overrides.historyDir),
        _layer('edge.directory', edgeDir, overrides.edgeDir),
        _layer('providers.dir', providersDir, overrides.providersDir),
        _layer('models.dir', modelsDir, overrides.modelsDir),
        _layer('profiles.dir', profilesDir, overrides.profilesDir),
        _layer('mcpServers.dir', mcpServersDir, overrides.mcpServersDir),
        _layer('cognition.root', promptsDir, overrides.promptsDir),
        _layer('scripts.systemDir', scriptsSystemDir,
            overrides.scriptsSystemDir),
        _layer('sqliteVec.binariesRoot', sqliteVecBinariesRoot,
            overrides.sqliteVecBinariesRoot),
      ];

  // ── Writable-dir creation ─────────────────────────────────────────────

  /// Creates the writable directories on demand — `memory/`, `trail/`,
  /// `history/`, `edge/`, `scratchpad/` (§ 2). The config aspects (`providers/`,
  /// `models/`, `mcp/`, `profiles/`, `prompts/`, `scripts/`) are deliberately
  /// left un-created: a missing *required* aspect is a boot error unless the
  /// bundle satisfies it.
  void ensureWritableDirs() {
    for (final dir in <String>[
      memoryRoot,
      trailRoot,
      historyDir,
      edgeDir,
      scratchpadDir,
    ]) {
      Directory(dir).createSync(recursive: true);
    }
  }

  // ── Config assembly ───────────────────────────────────────────────────

  /// Parses [baseYaml] (the user's config, possibly empty) and overlays the
  /// `<home>/agent` convention to produce a fully-pathed [BrainRunConfig].
  ///
  /// Three layers are deep-merged (a map recurses; a list/scalar replaces):
  ///
  ///   convention overlay  <  base config  <  flag overrides
  ///
  /// so a path the base config sets wins over the convention (§ 9), and an
  /// override (a CLI flag) wins over both (§ 6). The merged document is rendered
  /// back to YAML and parsed through [BrainRunConfigLoader.parse] with
  /// `basePath: agentRoot`, so each section loader stays the single authority
  /// over its own shape (and a relative aspect dir resolves against the agent
  /// root). [envVars] is forwarded for `${env:…}` expansion inside the config.
  ///
  /// A missing *required* aspect (e.g. no inline providers and no
  /// `<agent>/providers/` directory) surfaces as the owning loader's located
  /// boot error during the parse.
  ///
  /// [overlay] is the top CLI-tier layer (channel ports + `--set` scalar
  /// overrides assembled by `assembleServeConfig`, step #8): it is deep-merged
  /// LAST, so a flag-tier value wins over the file, the path overrides, and the
  /// convention — the top rung of the precedence ladder (§ 6).
  BrainRunConfig buildConfig(
    String baseYaml, {
    Map<String, String> envVars = const {},
    Map<Object?, Object?> overlay = const {},
  }) {
    final Map<Object?, Object?> base = baseYaml.trim().isEmpty
        ? <Object?, Object?>{}
        : loadYamlAsMap(baseYaml, errorFactory: BrainRunConfigException.new)
            .cast<Object?, Object?>();

    final Map<Object?, Object?> merged = deepMergeMaps(
      deepMergeMaps(
        deepMergeMaps(_conventionOverlay(base), base),
        _overridesOverlay(),
      ),
      overlay,
    );

    return BrainRunConfigLoader.parse(
      emitYamlDoc(merged),
      envVars: envVars,
      basePath: agentRoot,
    );
  }

  /// The convention overlay — the bottom merge layer (every value defaults
  /// under `<agent>/`). The mutually-exclusive aspects (providers/models/
  /// profiles) are injected ONLY when the base sets neither the inline block
  /// nor the directory key, because "inline XOR directory for one aspect" is a
  /// config error the section loaders reject (§ 9).
  Map<Object?, Object?> _conventionOverlay(Map<Object?, Object?> base) {
    final Map<Object?, Object?> overlay = <Object?, Object?>{
      'memory': <Object?, Object?>{'root': memoryRoot},
      'access': <Object?, Object?>{
        'history': <Object?, Object?>{'directory': historyDir},
        'edgeState': <Object?, Object?>{'directory': edgeDir},
      },
      'trail': <Object?, Object?>{'root': trailRoot},
      'cognition': <Object?, Object?>{'root': promptsDir},
      'scripts': <Object?, Object?>{'systemDir': scriptsSystemDir},
      'tools': <Object?, Object?>{
        'writeScope': writeScope,
        'readScope': readScope,
      },
    };

    final Map<Object?, Object?> substrate = <Object?, Object?>{};
    final Map<Object?, Object?> baseSub = _mapAt(base, 'substrate');
    if (!baseSub.containsKey('providers') &&
        !baseSub.containsKey('providersDir')) {
      substrate['providersDir'] = providersDir;
    }
    if (!baseSub.containsKey('roleRoutes') &&
        !baseSub.containsKey('embedding') &&
        !baseSub.containsKey('modelsDir')) {
      substrate['modelsDir'] = modelsDir;
    }
    if (substrate.isNotEmpty) overlay['substrate'] = substrate;

    // Profiles is an OPTIONAL aspect — the built-in `default` profile always
    // exists, so a brain with no profile config is valid. Unlike the required
    // providers/models aspects (whose missing convention directory is a boot
    // error), the convention points `profilesDir` at `<agent>/profiles/` only
    // when that directory actually exists; otherwise it stays unset and the
    // default profile stands. An explicit `--profiles` flag (the override
    // overlay) is honoured unconditionally — a missing flagged dir is an error.
    if (!base.containsKey('profiles') &&
        !base.containsKey('profilesDir') &&
        Directory(profilesDir).existsSync()) {
      overlay['profilesDir'] = profilesDir;
    }

    // External MCP servers are an OPTIONAL aspect — an absent block yields an
    // empty registry (the cognition has no outbound MCP servers). Like
    // profiles, the convention points `mcpServersDir` at `<agent>/mcp/` only
    // when that directory actually exists; otherwise it stays unset and the
    // registry is empty. An explicit `--mcp` flag is honoured unconditionally
    // (a missing flagged dir is an error).
    if (!base.containsKey('mcpServers') &&
        !base.containsKey('mcpServersDir') &&
        Directory(mcpServersDir).existsSync()) {
      overlay['mcpServersDir'] = mcpServersDir;
    }

    return overlay;
  }

  /// The override overlay — the top merge layer; only the keys whose flag was
  /// given are present, so an unset override never shadows a base value.
  Map<Object?, Object?> _overridesOverlay() {
    final Map<Object?, Object?> overlay = <Object?, Object?>{};

    final Map<Object?, Object?> memory = <Object?, Object?>{};
    if (overrides.memoryRoot != null) memory['root'] = overrides.memoryRoot;
    if (overrides.sqliteVecBinariesRoot != null) {
      memory['sqliteVec'] = <Object?, Object?>{
        'binariesRoot': overrides.sqliteVecBinariesRoot,
      };
    }
    if (memory.isNotEmpty) overlay['memory'] = memory;

    final Map<Object?, Object?> access = <Object?, Object?>{};
    if (overrides.historyDir != null) {
      access['history'] = <Object?, Object?>{'directory': overrides.historyDir};
    }
    if (overrides.edgeDir != null) {
      access['edgeState'] = <Object?, Object?>{'directory': overrides.edgeDir};
    }
    if (access.isNotEmpty) overlay['access'] = access;

    final Map<Object?, Object?> substrate = <Object?, Object?>{};
    if (overrides.providersDir != null) {
      substrate['providersDir'] = overrides.providersDir;
    }
    if (overrides.modelsDir != null) {
      substrate['modelsDir'] = overrides.modelsDir;
    }
    if (substrate.isNotEmpty) overlay['substrate'] = substrate;

    if (overrides.trailRoot != null) {
      overlay['trail'] = <Object?, Object?>{'root': overrides.trailRoot};
    }
    if (overrides.promptsDir != null) {
      overlay['cognition'] = <Object?, Object?>{'root': overrides.promptsDir};
    }
    if (overrides.scriptsSystemDir != null) {
      overlay['scripts'] =
          <Object?, Object?>{'systemDir': overrides.scriptsSystemDir};
    }
    if (overrides.profilesDir != null) {
      overlay['profilesDir'] = overrides.profilesDir;
    }
    if (overrides.mcpServersDir != null) {
      overlay['mcpServersDir'] = overrides.mcpServersDir;
    }

    final Map<Object?, Object?> tools = <Object?, Object?>{};
    if (overrides.writeScope != null) tools['writeScope'] = overrides.writeScope;
    if (overrides.readScope != null) tools['readScope'] = overrides.readScope;
    if (tools.isNotEmpty) overlay['tools'] = tools;

    return overlay;
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  String _underAgent(String name) => _join(agentRoot, name);

  ResolvedPath _layer(String aspect, String value, String? override) =>
      ResolvedPath(aspect, value,
          override == null ? PathLayer.convention : PathLayer.flag);

  /// The sub-map at [key] in [map], or an empty map when absent / not a map.
  static Map<Object?, Object?> _mapAt(Map<Object?, Object?> map, String key) {
    final value = map[key];
    return value is Map<Object?, Object?> ? value : const <Object?, Object?>{};
  }

  /// Returns [path] made absolute against the current working directory; an
  /// already-absolute path is returned unchanged. Mirrors the workspace norm of
  /// not depending on `package:path` for these joins.
  static String _absolute(String path) =>
      _isAbsolute(path) ? path : _join(Directory.current.path, path);

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  static String _join(String base, String name) =>
      base.endsWith('/') ? '$base$name' : '$base/$name';
}
