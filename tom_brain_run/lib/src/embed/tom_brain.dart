// TomBrain — the embedding facade (`tom_brain_cli.md` § 10, CLI plan step #10).
//
// A host application that wants a brain *in-process* (rather than shelling out
// to `tom_brain serve`) constructs a [TomBrain]. Both constructors stand the
// same production cognition up — a running `BrainProcess` plus the co-hosted
// memory-MCP and Trail-Observatory isolates — behind the shared
// [defaultServeBoot] seam, and hand back a handle exposing the bound OpenAI
// edge port, the Observatory URL, the boot [ProfileRegistry], and a graceful
// [stop].
//
// Two constructors, two postures (§ 10.1 / § 10.2):
//
//   * [TomBrain.fromProjectDir] — the `--home`/`agent` directory convention
//     (§ 2). Every editable surface maps to a real file under `<home>/agent/`,
//     so the Observatory's three `PUT` routes stay **read-write**; profiles are
//     read from `<agent>/profiles/`.
//   * [TomBrain.fromConfig] — fully programmatic, no backing files. Profiles are
//     passed as `List<Profile>` objects. Because an edit would have nowhere to
//     persist, the Observatory is forced **read-only** (`configWritable=false`),
//     so its three `PUT` routes return `409 config_is_immutable` — read-only is
//     a *consequence* of construction, not a flag the embedder can forget.
//
// Both auto-include the bundled sqlite-vec native library (§ 7): the resolver
// walks explicit-config → on-disk → the compiled-in [brainBundle] → the
// in-quest `${TOM_BINARIES_ROOT}` tree, and the resolved root is stamped into
// `memory.sqliteVec.binariesRoot` before boot, so a depending project finds
// vec0 with no external file and no extra setup.

import 'dart:io';

import 'package:tom_brain_shared/tom_brain_shared.dart' show SqliteVecConfig;

import '../brain_run_config.dart';
import '../brain_run_config_loader.dart';
import '../bundle/brain_bundle.g.dart' show brainBundle;
import '../bundle/bundle_manifest.dart' show BundleManifest;
import '../bundle/bundled_sqlite_vec.dart'
    show SqliteVecOrigin, SqliteVecResolution, resolveSqliteVecBinariesRoot;
import '../cli/serve_config_assembler.dart' show ServeRuntimeOptions;
import '../cli/serve_runner.dart'
    show BrainServeSession, ServeBoot, ServeNarrate, defaultServeBoot;
import '../profile/profile.dart' show Profile;
import '../profile/profile_registry.dart' show ProfileRegistry;
import '../project_home.dart' show HomeOverrides, ProjectHome;

/// Where a programmatic brain's prompt templates come from ([BrainConfig.prompts]).
///
/// [PromptSource.bundle] uses the compiled-in [brainBundle]; when the bundle
/// carries no prompts (the committed empty default) the boot falls back to the
/// package-relative cognition defaults. [PromptSource.disk] reads an on-disk
/// cognition tree (a `cognition.root`).
final class PromptSource {
  /// Use the compiled-in bundle (package defaults when the bundle is empty).
  const PromptSource.bundle() : diskRoot = null;

  /// Read prompt templates from the on-disk cognition tree at [root].
  const PromptSource.disk(String root) : diskRoot = root;

  /// The on-disk cognition root, or `null` for the bundle.
  final String? diskRoot;
}

/// Where a programmatic brain's procedure scripts come from ([BrainConfig.scripts]).
///
/// [ScriptSource.bundle] uses the compiled-in [brainBundle]; when the bundle
/// carries no scripts (the committed empty default) the boot falls back to the
/// package-relative `scripts/system/` directory. [ScriptSource.disk] reads an
/// on-disk system-scripts directory.
final class ScriptSource {
  /// Use the compiled-in bundle (package defaults when the bundle is empty).
  const ScriptSource.bundle() : diskRoot = null;

  /// Read procedure scripts from the on-disk system directory at [root].
  const ScriptSource.disk(String root) : diskRoot = root;

  /// The on-disk `scripts/system` root, or `null` for the bundle.
  final String? diskRoot;
}

/// One substrate provider in a programmatic [BrainConfig] — rendered into the
/// `substrate.providers[]` block the `SubstrateConfigLoader` parses.
final class BrainProvider {
  /// Builds a provider entry; [kind] is the loader's provider kind
  /// (`openai` / `ollama` / `agentSdk`).
  const BrainProvider({
    required this.id,
    required this.kind,
    required this.baseUrl,
    required this.models,
  });

  /// The provider id (referenced by [BrainRoute.providerId] and the embedding).
  final String id;

  /// The provider kind the loader manufactures lazily at first call.
  final String kind;

  /// The provider base URL.
  final String baseUrl;

  /// The model ids the provider advertises.
  final List<String> models;
}

/// One role-route entry in a programmatic [BrainConfig] — rendered into the
/// `substrate.roleRoutes.<role>[]` chain.
final class BrainRoute {
  /// Builds a route entry pointing [providerId] at [model].
  const BrainRoute({required this.providerId, required this.model});

  /// The provider this route dispatches to.
  final String providerId;

  /// The model id on that provider.
  final String model;
}

/// The embedding-service choice in a programmatic [BrainConfig] — rendered into
/// the `substrate.embedding` block.
final class BrainEmbedding {
  /// Builds an embedding choice ([dims]-dimensional, optionally L2-normalised).
  const BrainEmbedding({
    required this.providerId,
    required this.model,
    required this.dims,
    this.normalize = true,
  });

  /// The provider hosting the embedding model.
  final String providerId;

  /// The embedding model id.
  final String model;

  /// The embedding dimensionality.
  final int dims;

  /// Whether embeddings are L2-normalised.
  final bool normalize;
}

/// One OpenAI bearer credential in a programmatic [BrainConfig] — rendered into
/// the `access.apiKeys[]` block.
final class BrainApiKey {
  /// Builds a bearer credential binding [key] to [principal].
  const BrainApiKey({
    required this.key,
    required this.principal,
    this.displayName,
  });

  /// The bearer token value.
  final String key;

  /// The principal the token authenticates as.
  final String principal;

  /// An optional human-readable label.
  final String? displayName;
}

/// A fully-programmatic brain configuration (`tom_brain_cli.md` § 10.2). Every
/// path is explicit; prompts/scripts come from [PromptSource] / [ScriptSource];
/// session profiles are passed as [Profile] objects. There are no backing
/// files, so the Observatory is forced read-only.
final class BrainConfig {
  /// Assembles a programmatic config. The four directory roots
  /// ([memoryRoot] / [trailRoot] / [historyDir] / [edgeDir]) are created on
  /// boot; the substrate / access blocks are rendered and parsed through the
  /// real section loaders; [profiles] are wired into the boot registry directly.
  const BrainConfig({
    required this.providers,
    required this.routes,
    required this.embedding,
    required this.memoryRoot,
    required this.trailRoot,
    required this.historyDir,
    required this.edgeDir,
    required this.openAiPort,
    required this.apiKeys,
    this.prompts = const PromptSource.bundle(),
    this.scripts = const ScriptSource.bundle(),
    this.profiles = const <Profile>[],
  });

  /// The substrate provider catalogue.
  final List<BrainProvider> providers;

  /// Role → ordered route chain.
  final Map<String, List<BrainRoute>> routes;

  /// The embedding-service choice.
  final BrainEmbedding embedding;

  /// `memory.root` — the on-disk store root.
  final String memoryRoot;

  /// `trail.root` — the prompt-tracing trail root.
  final String trailRoot;

  /// `access.history.directory` — durable conversation histories.
  final String historyDir;

  /// `access.edgeState.directory` — the edge limiters' persisted state.
  final String edgeDir;

  /// The OpenAI edge port (must be `> 0`).
  final int openAiPort;

  /// The OpenAI bearer credentials.
  final List<BrainApiKey> apiKeys;

  /// Where prompt templates come from.
  final PromptSource prompts;

  /// Where procedure scripts come from.
  final ScriptSource scripts;

  /// The session profiles, passed as objects (immutable at runtime, § 10.3).
  final List<Profile> profiles;
}

/// Per-construction overrides for [TomBrain.fromProjectDir] (`§ 10.1`).
final class BrainOverrides {
  /// Builds an override set; [observatory] gates whether the read-write
  /// Observatory is co-hosted, [openAiPort] overrides the edge port when set.
  const BrainOverrides({this.openAiPort, this.observatory = true});

  /// An explicit OpenAI edge port, or `null` to use the config-file value.
  final int? openAiPort;

  /// Whether the (read-write) Observatory is co-hosted (default `true`).
  final bool observatory;
}

/// A running, in-process brain — the embedding facade (`tom_brain_cli.md` § 10).
///
/// Wraps the [BrainServeSession] the boot stood up. Read the bound [openAiPort],
/// the [observatoryUrl] / [memoryMcpUrl], or the boot [profiles]; await
/// [completed] for the process exit; call [stop] once to tear everything down
/// (Observatory → memory MCP → cognition).
final class TomBrain {
  TomBrain._(
    this._session,
    this.profiles, {
    required this.sqliteVecOrigin,
  });

  final BrainServeSession _session;

  /// The boot profile registry (the built-in `default` plus any configured /
  /// passed profiles). A host routes its requests to a profile through the
  /// access edge; this registry is the same one the edge resolves against.
  final ProfileRegistry profiles;

  /// Where the sqlite-vec native library was resolved from (§ 7) — the bundle in
  /// the auto-included case.
  final SqliteVecOrigin sqliteVecOrigin;

  /// The bound OpenAI edge port (`POST /v1/chat/completions`).
  int get openAiPort => _session.openAiPort;

  /// The co-hosted Trail-Observatory URL, or `null` when not co-hosted.
  String? get observatoryUrl => _session.observatoryUrl;

  /// The co-hosted memory-MCP server URL, or `null` when not co-hosted.
  String? get memoryMcpUrl => _session.memoryMcpUrl;

  /// Whether the Telegram channel came up.
  bool get telegramEnabled => _session.telegramEnabled;

  /// Resolves with the process exit code once teardown completes.
  Future<int> get completed => _session.completed;

  /// Tears the brain down: Observatory, then memory MCP, then the cognition.
  Future<void> stop() => _session.stop();

  /// Stands a brain up from the `--home`/`agent` directory convention (§ 10.1).
  ///
  /// Brain directories default under `<home>/agent/`; an existing
  /// `<agent>/brain.yaml` supplies the base config (an absent one is fine — the
  /// convention fills every required aspect). The sqlite-vec library is resolved
  /// (explicit → on-disk → [bundle] → `${TOM_BINARIES_ROOT}`) and stamped into
  /// the memory config. The Observatory comes up **read-write** unless
  /// `overrides.observatory` is `false`.
  ///
  /// [bundle] and [boot] are test seams — the bundle defaults to the compiled-in
  /// [brainBundle], the boot to the production [defaultServeBoot].
  static Future<TomBrain> fromProjectDir(
    Directory home, {
    BrainOverrides overrides = const BrainOverrides(),
    ServeNarrate? narrate,
    BundleManifest? bundle,
    ServeBoot? boot,
  }) async {
    final BundleManifest effectiveBundle = bundle ?? brainBundle;
    final ServeBoot effectiveBoot = boot ?? defaultServeBoot;

    // Resolve the sqlite-vec root against `<agent>/bin` before building the
    // overrides (the agent root is independent of the overrides).
    final ProjectHome probe = ProjectHome(home: home.path);
    final SqliteVecResolution vec = await resolveSqliteVecBinariesRoot(
      config: const SqliteVecConfig(),
      agentBinRoot: '${probe.agentRoot}/bin',
      bundle: effectiveBundle,
    );

    final ProjectHome ph = ProjectHome(
      home: home.path,
      overrides: HomeOverrides(sqliteVecBinariesRoot: vec.binariesRoot),
    );

    final File brainYaml = File('${ph.agentRoot}/brain.yaml');
    final String baseYaml =
        brainYaml.existsSync() ? brainYaml.readAsStringSync() : '';

    final Map<Object?, Object?> overlay = <Object?, Object?>{};
    if (overrides.openAiPort != null) {
      overlay['access'] = <Object?, Object?>{
        'openai': <Object?, Object?>{'port': overrides.openAiPort},
      };
    }

    final BrainRunConfig config = ph.buildConfig(baseYaml, overlay: overlay);
    ph.ensureWritableDirs();

    final BrainServeSession session = await effectiveBoot(
      config,
      ServeRuntimeOptions(
        observatoryEnabled: overrides.observatory,
        observatoryPort: 0,
        observatoryReadonly: false,
        memoryMcpPort: 0,
      ),
      runConfigPath: brainYaml.path,
      narrate: narrate ?? _silent,
    );

    return TomBrain._(session, config.profiles, sqliteVecOrigin: vec.origin);
  }

  /// Stands a brain up from a fully-programmatic [BrainConfig] (§ 10.2).
  ///
  /// No backing files: the substrate / memory / access / trail sections are
  /// rendered to YAML and parsed through the real section loaders, then the
  /// passed `profiles:` are wired into the boot registry directly. The
  /// sqlite-vec library is resolved (explicit → on-disk → [bundle] →
  /// `${TOM_BINARIES_ROOT}`) under `<memoryRoot>/bin` and stamped into the
  /// memory config. The Observatory is forced **read-only**
  /// (`configWritable=false`): its three `PUT` routes return
  /// `409 config_is_immutable`.
  ///
  /// [bundle] and [boot] are test seams — see [fromProjectDir].
  static Future<TomBrain> fromConfig(
    BrainConfig config, {
    ServeNarrate? narrate,
    BundleManifest? bundle,
    ServeBoot? boot,
  }) async {
    final BundleManifest effectiveBundle = bundle ?? brainBundle;
    final ServeBoot effectiveBoot = boot ?? defaultServeBoot;

    // Create the writable tree before boot (no ProjectHome to do it for us).
    for (final String dir in <String>[
      config.memoryRoot,
      config.trailRoot,
      config.historyDir,
      config.edgeDir,
    ]) {
      Directory(dir).createSync(recursive: true);
    }

    final SqliteVecResolution vec = await resolveSqliteVecBinariesRoot(
      config: const SqliteVecConfig(),
      agentBinRoot: '${_trimTrailing(config.memoryRoot)}/bin',
      bundle: effectiveBundle,
    );

    final String yaml = _renderConfigYaml(config, vec.binariesRoot);

    // Persist the rendered config so the Observatory has a (read-only)
    // run-config directory; the parse itself reads from the in-memory string.
    final File generated =
        File('${_trimTrailing(config.memoryRoot)}/brain.generated.yaml');
    generated.writeAsStringSync(yaml);

    final BrainRunConfig parsed = BrainRunConfigLoader.parse(
      yaml,
      basePath: config.memoryRoot,
    );

    // Rebuild with the passed profiles wired into the boot registry directly —
    // the only section not sourced from a file (§ 10.3).
    final ProfileRegistry registry = ProfileRegistry(config.profiles);
    final BrainRunConfig runConfig = BrainRunConfig(
      substrate: parsed.substrate,
      memory: parsed.memory,
      access: parsed.access,
      trail: parsed.trail,
      tools: parsed.tools,
      scripts: parsed.scripts,
      dream: parsed.dream,
      cognition: parsed.cognition,
      mcpServers: parsed.mcpServers,
      history: parsed.history,
      profiles: registry,
    );

    final BrainServeSession session = await effectiveBoot(
      runConfig,
      const ServeRuntimeOptions(
        observatoryPort: 0,
        observatoryReadonly: true,
        memoryMcpPort: 0,
      ),
      runConfigPath: generated.path,
      narrate: narrate ?? _silent,
    );

    return TomBrain._(session, registry, sqliteVecOrigin: vec.origin);
  }

  /// Renders the programmatic [config] into the whole-process YAML the section
  /// loaders parse. [vecBinariesRoot] is the resolved sqlite-vec root. Profiles
  /// are deliberately NOT rendered — they are wired as objects (§ 10.3).
  static String _renderConfigYaml(BrainConfig config, String vecBinariesRoot) {
    final StringBuffer b = StringBuffer();

    b.writeln('substrate:');
    b.writeln('  providers:');
    for (final BrainProvider p in config.providers) {
      b.writeln('    - id: ${p.id}');
      b.writeln('      kind: ${p.kind}');
      b.writeln('      baseUrl: ${p.baseUrl}');
      b.writeln('      models:');
      for (final String m in p.models) {
        b.writeln('        - $m');
      }
    }
    b.writeln('  roleRoutes:');
    config.routes.forEach((String role, List<BrainRoute> chain) {
      b.writeln('    $role:');
      for (final BrainRoute r in chain) {
        b.writeln('      - providerId: ${r.providerId}');
        b.writeln('        model: ${r.model}');
      }
    });
    b.writeln('  embedding:');
    b.writeln('    providerId: ${config.embedding.providerId}');
    b.writeln('    model: ${config.embedding.model}');
    b.writeln('    dims: ${config.embedding.dims}');
    b.writeln('    normalize: ${config.embedding.normalize}');

    b.writeln('memory:');
    b.writeln('  root: "${config.memoryRoot}"');
    b.writeln('  sqliteVec:');
    b.writeln('    binariesRoot: "$vecBinariesRoot"');

    b.writeln('access:');
    b.writeln('  openai:');
    b.writeln('    port: ${config.openAiPort}');
    b.writeln('    basePath: /v1');
    b.writeln('  history:');
    b.writeln('    directory: "${config.historyDir}"');
    b.writeln('  edgeState:');
    b.writeln('    directory: "${config.edgeDir}"');
    b.writeln('  apiKeys:');
    for (final BrainApiKey k in config.apiKeys) {
      b.writeln('    - key: ${k.key}');
      b.writeln('      principal: ${k.principal}');
      b.writeln('      displayName: ${k.displayName ?? k.principal}');
    }
    b.writeln('  rateLimit:');
    b.writeln('    capacity: 1000000');
    b.writeln('    refillTokens: 1000000');
    b.writeln('    refillPeriodSeconds: 1');
    b.writeln('  quota:');
    b.writeln('    dailyCap: 1000000');

    b.writeln('trail:');
    b.writeln('  root: "${config.trailRoot}"');

    final String? promptsRoot = config.prompts.diskRoot;
    if (promptsRoot != null) {
      b.writeln('cognition:');
      b.writeln('  root: "$promptsRoot"');
    }
    final String? scriptsRoot = config.scripts.diskRoot;
    if (scriptsRoot != null) {
      b.writeln('scripts:');
      b.writeln('  systemDir: "$scriptsRoot"');
    }

    return b.toString();
  }

  static void _silent(String _) {}

  static String _trimTrailing(String path) {
    var end = path.length;
    while (end > 0 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
      end--;
    }
    return path.substring(0, end);
  }
}
