// serve_config_assembler.dart — the single authority over `tom_brain serve`
// flag semantics (CLI plan step #8; `tom_brain_cli.md` § 5.2 / § 5.3 / § 6 / § 9).
//
// The `tom_build_base` arg parser cannot express three things the serve surface
// needs: repeatable options (`--set` / `--write-scope` / `--read-scope` keep
// only the last occurrence), optional-value channel flags (`--openai[=port]`),
// and the `${env:…}`-expand-before-resolve contract (every flag value passes
// through the step-7 expander BEFORE path resolution). So the serve executor
// holds the raw argv and hands it here; this assembler parses it itself, then
// resolves a `BrainRunConfig` through the two config-assembly modes:
//
//   * single-file mode — `--config` given, no home-implying flag: the file is
//     parsed as-is (today's behaviour, § 9), then the channel / `--set` overlay
//     is deep-merged on top. No `<home>/agent` convention is applied.
//   * home mode — otherwise (a `--home` / `--agent-dir` / path-override flag, or
//     no `--config` at all): `ProjectHome` resolves the `<home>/agent`
//     convention under the (optional) file, the path overrides over that, and
//     the channel / `--set` overlay last (CLP-40). The default `--home` is the
//     process working directory.
//
// The runtime knobs (`--observatory*`, `--memory-mcp` / `--no-memory-mcp`) are
// collected into [ServeRuntimeOptions]; the serve runner honours them when it
// co-hosts the inspection surface.

import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart'
    show ObservatoryOptions;
import 'package:tom_core_agentic/tom_core_agentic.dart' show loadYamlAsMap;

import '../brain_run_config.dart';
import '../brain_run_config_loader.dart';
import '../cli_env_expansion.dart';
import '../project_home.dart';
import 'config_overlay.dart';
import 'tom_brain_tool.dart';

/// Thrown when a serve invocation carries a malformed or unknown flag — a clear
/// startup error pointing at the bad argument.
final class ServeConfigException implements Exception {
  ServeConfigException(this.message);

  /// Engineer-readable description of the bad invocation.
  final String message;

  @override
  String toString() => 'ServeConfigException: $message';
}

/// The co-host runtime knobs for a `serve` invocation (§ 5.3). Defaults mean
/// the memory MCP server and the Observatory are co-hosted in-process.
final class ServeRuntimeOptions {
  /// Builds the runtime options; every field defaults to the co-host default.
  const ServeRuntimeOptions({
    this.observatoryEnabled = true,
    this.observatoryHost = ObservatoryOptions.defaultHost,
    this.observatoryPort = ObservatoryOptions.defaultPort,
    this.observatoryReadonly = false,
    this.memoryMcpEnabled = true,
    this.memoryMcpPort = 0,
  });

  /// Whether to co-host the Observatory (default true; `--no-observatory` off).
  final bool observatoryEnabled;

  /// The Observatory loopback bind address.
  final String observatoryHost;

  /// The Observatory loopback bind port.
  final int observatoryPort;

  /// Force the Observatory read-only even in directory mode (§ 10; step 9).
  final bool observatoryReadonly;

  /// Whether to co-host the memory MCP server (default true; `--no-memory-mcp`
  /// off).
  final bool memoryMcpEnabled;

  /// The co-hosted memory MCP server port (`0` = ephemeral loopback).
  final int memoryMcpPort;
}

/// The resolved product of a `serve` invocation: the [config] to boot, the
/// [runtime] co-host knobs, and the on-disk [runConfigPath] (so the running
/// brain can persist a changed bridge port back into the file it booted from).
final class ServeAssembly {
  /// Builds the assembly result.
  const ServeAssembly({
    required this.config,
    required this.runtime,
    required this.runConfigPath,
  });

  /// The resolved whole-process config.
  final BrainRunConfig config;

  /// The co-host runtime knobs.
  final ServeRuntimeOptions runtime;

  /// The on-disk run-config path (the `--config` file, or `<agent>/brain.yaml`).
  final String runConfigPath;
}

/// The signature `assembleServeConfig` conforms to, so the serve executor can
/// inject a fake in tests.
typedef ServeConfigAssembler = ServeAssembly Function(
  List<String> serveArgs, {
  required Map<String, String> env,
  String? workingDirectory,
  String Function(String path)? readFile,
});

/// Parses [serveArgs] (the raw argv, optionally with a leading `:serve` /
/// `serve` token) into a [ServeAssembly].
///
/// [env] supplies the `${env:…}` expansion source (the binary passes
/// `Platform.environment`); [workingDirectory] is the default `--home`
/// (defaults to the process CWD); [readFile] reads a `--config` file (defaults
/// to a real on-disk read; injected in tests).
ServeAssembly assembleServeConfig(
  List<String> serveArgs, {
  required Map<String, String> env,
  String? workingDirectory,
  String Function(String path)? readFile,
}) {
  final read = readFile ?? (p) => File(p).readAsStringSync();
  final cwd = workingDirectory ?? Directory.current.path;

  final _ParsedServeFlags flags = _parseServeFlags(serveArgs, env);

  // The base config: the --config file content, or empty (convention-only).
  final String baseYaml =
      flags.configPath == null ? '' : read(flags.configPath!);
  final Map<Object?, Object?> baseMap = baseYaml.trim().isEmpty
      ? <Object?, Object?>{}
      : loadYamlAsMap(baseYaml, errorFactory: ServeConfigException.new)
          .cast<Object?, Object?>();

  final bool homeMode = flags.homeFlag != null ||
      flags.agentDirFlag != null ||
      flags.hasPathOverride ||
      flags.configPath == null;

  // The CLI-tier overlay (channel ports + --set), the top precedence rung.
  final Map<Object?, Object?> overlay =
      _cliOverlay(flags, baseMap, homeMode: homeMode);

  final BrainRunConfig config;
  final String runConfigPath;
  if (homeMode) {
    final home = ProjectHome(
      home: flags.homeFlag ?? cwd,
      agentDir: flags.agentDirFlag,
      overrides: flags.toHomeOverrides(),
    );
    config = home.buildConfig(baseYaml, envVars: env, overlay: overlay);
    runConfigPath = flags.configPath ?? '${home.agentRoot}/brain.yaml';
  } else {
    // Single-file mode: the file as-is, then the channel / --set overlay.
    final Map<Object?, Object?> merged = deepMergeMaps(baseMap, overlay);
    config = BrainRunConfigLoader.parse(
      emitYamlDoc(merged),
      envVars: env,
      basePath: File(flags.configPath!).absolute.parent.path,
    );
    runConfigPath = flags.configPath!;
  }

  return ServeAssembly(
    config: config,
    runtime: flags.toRuntimeOptions(),
    runConfigPath: runConfigPath,
  );
}

/// Builds the CLI-tier overlay: the channel ports (`--openai` / `--ollama` /
/// `--anthropic` / `--telegram-token`) and the `--set` scalar overrides.
///
/// The mandatory OpenAI port is injected with its default only in home mode
/// when neither the base config nor `--openai` supplies one — a bare
/// `tom_brain serve` then still binds the conventional edge (the section loader
/// requires `access.openai.port > 0`). In single-file mode the file already
/// carries the port (§ 9).
Map<Object?, Object?> _cliOverlay(
  _ParsedServeFlags flags,
  Map<Object?, Object?> baseMap, {
  required bool homeMode,
}) {
  final overlay = <Object?, Object?>{};

  // OpenAI: an explicit flag wins; else inject the default in home mode when
  // the base config does not already set it.
  if (flags.openaiGiven) {
    setDottedKey(overlay, 'access.openai.port',
        flags.openaiPort ?? defaultServeOpenAiPort);
  } else if (homeMode && !_baseHasOpenAiPort(baseMap)) {
    setDottedKey(overlay, 'access.openai.port', defaultServeOpenAiPort);
  }
  if (flags.ollamaGiven) {
    setDottedKey(overlay, 'access.ollama.port',
        flags.ollamaPort ?? defaultServeOllamaPort);
  }
  if (flags.anthropicGiven) {
    setDottedKey(overlay, 'access.anthropic.port',
        flags.anthropicPort ?? defaultServeAnthropicPort);
  }
  if (flags.telegramToken != null) {
    setDottedKey(overlay, 'access.telegram.botToken', flags.telegramToken);
  }

  // --set scalar overrides land last (within the CLI tier).
  for (final entry in flags.setOverrides) {
    setDottedKey(overlay, entry.key, entry.value);
  }

  return overlay;
}

bool _baseHasOpenAiPort(Map<Object?, Object?> baseMap) {
  final access = baseMap['access'];
  if (access is! Map) return false;
  final openai = access['openai'];
  return openai is Map && openai['port'] != null;
}

// ── Raw-argv flag parsing ────────────────────────────────────────────────────

/// The flags recognised at the global + serve level whose value is a single
/// path (accept both `--flag value` and `--flag=value`).
const Set<String> _valueFlags = {
  'home',
  'agent-dir',
  'config',
  'providers',
  'models',
  'mcp',
  'profiles',
  'prompts',
  'scripts',
  'memory-dir',
  'trail-dir',
  'history-dir',
  'edge-dir',
  'sqlite-vec',
  'telegram-token',
  'observatory-host',
  'observatory-port',
};

/// Repeatable value flags (accumulate; both forms).
const Set<String> _repeatableFlags = {'set', 'write-scope', 'read-scope'};

/// Optional-value channel/port flags (`--flag` enables, `--flag=port` pins).
const Set<String> _optionalValueFlags = {
  'openai',
  'ollama',
  'anthropic',
  'memory-mcp',
};

/// Boolean flags.
const Set<String> _boolFlags = {
  'telegram',
  'no-memory-mcp',
  'observatory',
  'no-observatory',
  'observatory-readonly',
};

class _ParsedServeFlags {
  String? homeFlag;
  String? agentDirFlag;
  String? configPath;
  String? providersDir;
  String? modelsDir;
  String? profilesDir;
  String? mcpDir;
  String? promptsDir;
  String? scriptsDir;
  String? memoryDir;
  String? trailDir;
  String? historyDir;
  String? edgeDir;
  String? sqliteVecDir;
  final List<String> writeScope = [];
  final List<String> readScope = [];
  final List<MapEntry<String, String>> setOverrides = [];

  bool openaiGiven = false;
  int? openaiPort;
  bool ollamaGiven = false;
  int? ollamaPort;
  bool anthropicGiven = false;
  int? anthropicPort;

  bool telegram = false;
  String? telegramToken;

  bool observatoryEnabled = true;
  String observatoryHost = ObservatoryOptions.defaultHost;
  int observatoryPort = ObservatoryOptions.defaultPort;
  bool observatoryReadonly = false;
  bool memoryMcpEnabled = true;
  int memoryMcpPort = 0;

  bool get hasPathOverride =>
      providersDir != null ||
      modelsDir != null ||
      profilesDir != null ||
      mcpDir != null ||
      promptsDir != null ||
      scriptsDir != null ||
      memoryDir != null ||
      trailDir != null ||
      historyDir != null ||
      edgeDir != null ||
      sqliteVecDir != null ||
      writeScope.isNotEmpty ||
      readScope.isNotEmpty;

  HomeOverrides toHomeOverrides() => HomeOverrides(
        memoryRoot: memoryDir,
        trailRoot: trailDir,
        historyDir: historyDir,
        edgeDir: edgeDir,
        providersDir: providersDir,
        modelsDir: modelsDir,
        profilesDir: profilesDir,
        mcpServersDir: mcpDir,
        promptsDir: promptsDir,
        scriptsSystemDir: scriptsDir,
        sqliteVecBinariesRoot: sqliteVecDir,
        writeScope: writeScope.isEmpty ? null : writeScope,
        readScope: readScope.isEmpty ? null : readScope,
      );

  ServeRuntimeOptions toRuntimeOptions() => ServeRuntimeOptions(
        observatoryEnabled: observatoryEnabled,
        observatoryHost: observatoryHost,
        observatoryPort: observatoryPort,
        observatoryReadonly: observatoryReadonly,
        memoryMcpEnabled: memoryMcpEnabled,
        memoryMcpPort: memoryMcpPort,
      );
}

_ParsedServeFlags _parseServeFlags(List<String> args, Map<String, String> env) {
  final out = _ParsedServeFlags();
  var i = 0;
  // Skip a leading subcommand token (`:serve` or `serve`).
  if (args.isNotEmpty &&
      (args.first == ':$tomBrainServeCommandName' ||
          args.first == tomBrainServeCommandName)) {
    i = 1;
  }

  String expand(String flag, String value) =>
      expandCliFlag('--$flag', value, env: env);

  for (; i < args.length; i++) {
    final token = args[i];
    if (!token.startsWith('--')) {
      throw ServeConfigException(
        'Unexpected argument "$token" — serve takes only --flags.',
      );
    }
    final body = token.substring(2);
    final eq = body.indexOf('=');
    final name = eq < 0 ? body : body.substring(0, eq);
    final inline = eq < 0 ? null : body.substring(eq + 1);

    String requireValue() {
      if (inline != null) return expand(name, inline);
      if (i + 1 >= args.length) {
        throw ServeConfigException('--$name needs a value.');
      }
      return expand(name, args[++i]);
    }

    if (_boolFlags.contains(name)) {
      if (inline != null) {
        throw ServeConfigException('--$name does not take a value.');
      }
      _applyBool(out, name);
    } else if (_optionalValueFlags.contains(name)) {
      final int? port =
          inline == null ? null : _parsePort(name, expand(name, inline));
      _applyChannel(out, name, port);
    } else if (_repeatableFlags.contains(name)) {
      _applyRepeatable(out, name, requireValue(), env);
    } else if (_valueFlags.contains(name)) {
      _applyValue(out, name, requireValue());
    } else {
      throw ServeConfigException('unknown flag "--$name".');
    }
  }
  return out;
}

void _applyBool(_ParsedServeFlags out, String name) {
  switch (name) {
    case 'telegram':
      out.telegram = true;
    case 'no-memory-mcp':
      out.memoryMcpEnabled = false;
    case 'observatory':
      out.observatoryEnabled = true;
    case 'no-observatory':
      out.observatoryEnabled = false;
    case 'observatory-readonly':
      out.observatoryReadonly = true;
  }
}

void _applyChannel(_ParsedServeFlags out, String name, int? port) {
  switch (name) {
    case 'openai':
      out.openaiGiven = true;
      out.openaiPort = port;
    case 'ollama':
      out.ollamaGiven = true;
      out.ollamaPort = port;
    case 'anthropic':
      out.anthropicGiven = true;
      out.anthropicPort = port;
    case 'memory-mcp':
      out.memoryMcpEnabled = true;
      if (port != null) out.memoryMcpPort = port;
  }
}

void _applyRepeatable(
  _ParsedServeFlags out,
  String name,
  String value,
  Map<String, String> env,
) {
  switch (name) {
    case 'set':
      final eq = value.indexOf('=');
      if (eq < 0) {
        throw ServeConfigException('--set needs key=value, got "$value".');
      }
      final key = value.substring(0, eq);
      // The value half is re-expanded under the --set key error path so an
      // unset variable names the exact override (step 7 expandSetValue).
      final raw = value.substring(eq + 1);
      out.setOverrides.add(MapEntry(key, expandSetValue(key, raw, env: env)));
    case 'write-scope':
      out.writeScope.add(value);
    case 'read-scope':
      out.readScope.add(value);
  }
}

void _applyValue(_ParsedServeFlags out, String name, String value) {
  switch (name) {
    case 'home':
      out.homeFlag = value;
    case 'agent-dir':
      out.agentDirFlag = value;
    case 'config':
      out.configPath = value;
    case 'providers':
      out.providersDir = value;
    case 'models':
      out.modelsDir = value;
    case 'mcp':
      out.mcpDir = value;
    case 'profiles':
      out.profilesDir = value;
    case 'prompts':
      out.promptsDir = value;
    case 'scripts':
      out.scriptsDir = value;
    case 'memory-dir':
      out.memoryDir = value;
    case 'trail-dir':
      out.trailDir = value;
    case 'history-dir':
      out.historyDir = value;
    case 'edge-dir':
      out.edgeDir = value;
    case 'sqlite-vec':
      out.sqliteVecDir = value;
    case 'telegram-token':
      out.telegramToken = value;
    case 'observatory-host':
      out.observatoryHost = value;
    case 'observatory-port':
      out.observatoryPort = _parsePort('observatory-port', value);
  }
}

int _parsePort(String flag, String value) {
  final port = int.tryParse(value);
  if (port == null) {
    throw ServeConfigException('--$flag needs an integer, got "$value".');
  }
  return port;
}
