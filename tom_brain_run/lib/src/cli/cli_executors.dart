// cli_executors.dart — the five `tom_build_base` command executors behind the
// unified `tom_brain` binary (CLI plan step #8; `tom_brain_cli.md` § 5).
//
// Each subcommand is a non-traversal `CommandExecutor`: the brain runs as one
// process, never a project walk, so every executor implements
// `executeWithoutTraversal` and refuses `execute` (the traversal path).
//
// The executors hold the *raw* argv (CLP-38): the `tom_build_base` parser
// cannot express the serve surface's repeatable / optional-value / `${env:…}`
// flags, so the serve executor hands the raw argv to `assembleServeConfig`,
// which is the single authority over flag semantics. The factory
// [createTomBrainExecutors] binds that argv (and the injectable boot / assembler
// seams the test drives) into the map `ToolRunner` dispatches on.
//
//   * `serve`       — assemble the whole-process config + co-host runtime knobs,
//                     then `runBrainServe` (brain + memory-MCP + Observatory in
//                     one process).
//   * `memory-mcp`  — the read-mostly memory MCP server standalone (split
//                     deployments); blocks until SIGINT/SIGTERM.
//   * `observatory` — the read-only Observatory standalone against a trail root;
//                     blocks until SIGINT/SIGTERM.
//   * `init`        — refuses for now; the scaffold lands at CLI plan step #11
//                     (CLP-42).
//   * `bundle`      — codegen the compiled-in prompt/script/native asset bundle
//                     (§ 4), or `--list` a human-readable inventory.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils, tomLog;
import 'package:tom_brain_observatory/tom_brain_observatory.dart'
    show ObservatoryOptions;
import 'package:tom_build_base/tom_build_base_v2.dart';
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

import '../bundle/bundle_codegen.dart'
    show buildBundleManifest, renderBundleSource;
import '../bundle/bundle_listing.dart' show renderBundleListing;
import '../bundle/bundle_manifest.dart' show BundleManifest;
import '../memory_mcp_isolate_host.dart'
    show MemoryMcpIsolateHost, spawnMemoryMcpIsolate;
import '../observatory_banner.dart' show ObservatoryBanner;
import '../observatory_isolate_host.dart'
    show ObservatoryIsolateHost, spawnObservatoryIsolate;
import 'serve_config_assembler.dart'
    show ServeAssembly, ServeConfigAssembler, assembleServeConfig;
import 'serve_runner.dart' show ServeBoot, defaultServeBoot, runBrainServe;
import 'tom_brain_tool.dart';

/// The default standalone memory MCP server port (`tom_brain memory-mcp`),
/// matching the historical `memory_mcp_server.dart` default.
const int defaultStandaloneMemoryMcpPort = 8765;

/// Builds the five subcommand executors keyed by command name.
///
/// [rawArgs] is the (already subcommand-normalised) process argv — the serve
/// executor parses it directly through [assemble]. [env] is the `${env:…}`
/// expansion source (the binary passes `Platform.environment`). [boot] and
/// [assemble] are the injectable seams the tests fake; production uses the real
/// [defaultServeBoot] / [assembleServeConfig].
Map<String, CommandExecutor> createTomBrainExecutors({
  required List<String> rawArgs,
  required Map<String, String> env,
  ServeBoot boot = defaultServeBoot,
  ServeConfigAssembler assemble = assembleServeConfig,
}) {
  return {
    tomBrainServeCommandName: ServeCommandExecutor(
      rawArgs: rawArgs,
      env: env,
      boot: boot,
      assemble: assemble,
    ),
    tomBrainMemoryMcpCommandName:
        MemoryMcpCommandExecutor(rawArgs: rawArgs, env: env),
    tomBrainObservatoryCommandName:
        ObservatoryCommandExecutor(rawArgs: rawArgs, env: env),
    tomBrainInitCommandName: InitCommandExecutor(),
    tomBrainBundleCommandName: BundleCommandExecutor(rawArgs: rawArgs),
  };
}

/// `tom_brain serve` — assemble the whole-process config and boot the cognition
/// plus the co-hosted memory MCP server and Observatory in one process.
final class ServeCommandExecutor extends CommandExecutor {
  /// Binds the raw argv + the env-expansion source + the injectable seams.
  ServeCommandExecutor({
    required this.rawArgs,
    required this.env,
    this.boot = defaultServeBoot,
    this.assemble = assembleServeConfig,
  });

  /// The subcommand-normalised process argv (leading `:serve` skipped by the
  /// assembler).
  final List<String> rawArgs;

  /// The `${env:…}` expansion source.
  final Map<String, String> env;

  /// The boot seam (faked in tests).
  final ServeBoot boot;

  /// The config-assembly seam (faked in tests).
  final ServeConfigAssembler assemble;

  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) =>
      throw UnsupportedError('serve does not traverse projects');

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    final ServeAssembly asm = assemble(rawArgs, env: env);
    final int code = await runBrainServe(
      asm.config,
      asm.runtime,
      runConfigPath: asm.runConfigPath,
      boot: boot,
    );
    return code == 0
        ? const ToolResult.success(processedCount: 1)
        : ToolResult.failure('tom_brain serve exited with code $code.');
  }
}

/// `tom_brain memory-mcp` — run the read-mostly memory MCP server standalone
/// (split deployments), blocking until SIGINT/SIGTERM.
final class MemoryMcpCommandExecutor extends CommandExecutor {
  /// Binds the raw argv + the env-expansion source.
  MemoryMcpCommandExecutor({required this.rawArgs, required this.env});

  /// The subcommand-normalised process argv.
  final List<String> rawArgs;

  /// The `${env:…}` expansion source (reserved for future flag expansion).
  final Map<String, String> env;

  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) =>
      throw UnsupportedError('memory-mcp does not traverse projects');

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    final String? configPath = _flagValue(rawArgs, 'config', abbr: 'c');
    if (configPath == null) {
      return const ToolResult.failure(
        'memory-mcp needs --config <brain.yaml> (the memory: block to serve).',
      );
    }
    final int port =
        _intFlag(rawArgs, 'memory-mcp') ?? defaultStandaloneMemoryMcpPort;

    // The store opens through the real platform's kernel factory; install the
    // standalone platform (mirrors the serve boot).
    TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);

    final MemoryMcpIsolateHost? host = await spawnMemoryMcpIsolate(
      configPath,
      port: port,
      onInfo: (m) => stdout.writeln('[tom_brain.memory.mcp] $m'),
      onWarning: (m) => stderr.writeln('[tom_brain.memory.mcp] $m'),
    );
    if (host == null) {
      return const ToolResult.failure('memory MCP server failed to start.');
    }
    stdout.writeln('tom_brain memory-mcp serving — ${host.url}.');
    stdout.writeln('Press Ctrl-C to stop.');
    await _blockUntilSignal(host.stop);
    return const ToolResult.success(processedCount: 1);
  }
}

/// `tom_brain observatory` — run the read-only Observatory standalone against a
/// trail root (split deployments), blocking until SIGINT/SIGTERM.
final class ObservatoryCommandExecutor extends CommandExecutor {
  /// Binds the raw argv + the env-expansion source.
  ObservatoryCommandExecutor({required this.rawArgs, required this.env});

  /// The subcommand-normalised process argv.
  final List<String> rawArgs;

  /// The `${env:…}` expansion source (reserved for future flag expansion).
  final Map<String, String> env;

  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) =>
      throw UnsupportedError('observatory does not traverse projects');

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    final String? trailRoot = _flagValue(rawArgs, 'trail-dir');
    if (trailRoot == null) {
      return const ToolResult.failure(
        'observatory needs --trail-dir <trail-root> (the trail tree to read).',
      );
    }
    final ObservatoryIsolateHost? host = await spawnObservatoryIsolate(
      ObservatoryOptions(
        trailRoot: trailRoot,
        cognitionDir: _flagValue(rawArgs, 'prompts'),
        scriptsDir: _flagValue(rawArgs, 'scripts'),
        host: _flagValue(rawArgs, 'observatory-host') ??
            ObservatoryOptions.defaultHost,
        port: _intFlag(rawArgs, 'observatory-port') ??
            ObservatoryOptions.defaultPort,
      ),
      onInfo: (m) => stdout.writeln('[tom_brain.observatory] $m'),
      onWarning: (m) => stderr.writeln('[tom_brain.observatory] $m'),
    );
    if (host == null) {
      return const ToolResult.failure('observatory backend failed to start.');
    }
    stdout.writeln(ObservatoryBanner.running(host.url, trailRoot));
    stdout.writeln('Press Ctrl-C to stop.');
    await _blockUntilSignal(host.stop);
    return const ToolResult.success(processedCount: 1);
  }
}

/// `tom_brain init` — scaffold the `<home>/agent` convention skeleton. Deferred:
/// the wiring lands at CLI plan step #11 (CLP-42), so this refuses cleanly
/// rather than silently doing nothing.
final class InitCommandExecutor extends CommandExecutor {
  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) =>
      throw UnsupportedError('init does not traverse projects');

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    return const ToolResult.failure(
      'tom_brain init is not implemented yet (CLI plan step #11). Create the '
      '<home>/agent skeleton by hand, or run `tom_brain serve --home <dir>` '
      'which fills the convention paths from the bundle.',
    );
  }
}

/// `tom_brain bundle` — codegen the compiled-in prompt/script/native asset
/// bundle (§ 4), or `--list` a human-readable inventory.
final class BundleCommandExecutor extends CommandExecutor {
  /// Binds the raw argv.
  BundleCommandExecutor({required this.rawArgs});

  /// The subcommand-normalised process argv.
  final List<String> rawArgs;

  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) =>
      throw UnsupportedError('bundle does not traverse projects');

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    final String? promptsDir = _flagValue(rawArgs, 'prompts');
    final String? scriptsDir = _flagValue(rawArgs, 'scripts');
    final String? sqliteVecDir = _flagValue(rawArgs, 'sqlite-vec');
    final bool listOnly = _hasFlag(rawArgs, 'list');

    final BundleManifest manifest = await buildBundleManifest(
      promptsDir: promptsDir == null ? null : Directory(promptsDir),
      scriptsDir: scriptsDir == null ? null : Directory(scriptsDir),
      sqliteVecBinariesRoot:
          sqliteVecDir == null ? null : Directory(sqliteVecDir),
      platforms: <Abi>[Abi.current()],
    );

    if (listOnly) {
      stdout.writeln(renderBundleListing(manifest));
      return const ToolResult.success(processedCount: 1);
    }

    final String? outPath = _flagValue(rawArgs, 'out');
    if (outPath == null) {
      return const ToolResult.failure(
        'bundle needs --out <file> (the generated Dart source path), or --list '
        'to print an inventory.',
      );
    }
    File(outPath).writeAsStringSync(renderBundleSource(manifest));
    stdout.writeln('tom_brain bundle: wrote $outPath (${manifest.buildHash}).');
    return const ToolResult.success(processedCount: 1);
  }
}

// ── Raw-argv flag helpers ────────────────────────────────────────────────────
//
// The standalone subcommands read a small fixed set of single-value flags
// straight from the raw argv (the parser cannot be the authority here — see the
// serve assembler's rationale). Both `--flag value` and `--flag=value` forms are
// accepted; the abbreviation form (`-c`) is matched when given.

String? _flagValue(List<String> args, String name, {String? abbr}) {
  for (var i = 0; i < args.length; i++) {
    final token = args[i];
    if (token == '--$name' || (abbr != null && token == '-$abbr')) {
      return i + 1 < args.length ? args[i + 1] : null;
    }
    if (token.startsWith('--$name=')) {
      return token.substring('--$name='.length);
    }
  }
  return null;
}

int? _intFlag(List<String> args, String name) {
  final value = _flagValue(args, name);
  return value == null ? null : int.tryParse(value);
}

bool _hasFlag(List<String> args, String name) =>
    args.contains('--$name') || args.any((a) => a.startsWith('--$name='));

/// Blocks until SIGINT (or SIGTERM, off Windows), then runs [stop] and resolves.
/// Shared by the standalone server subcommands so a wedged guest never blocks
/// the operator's Ctrl-C.
Future<void> _blockUntilSignal(Future<void> Function() stop) async {
  final done = Completer<void>();
  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    tomLog.status('tom_brain: $signal — stopping…');
    await stop();
    if (!done.isCompleted) done.complete();
  }

  final subs = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen(shutdown),
  ];
  if (!Platform.isWindows) {
    subs.add(ProcessSignal.sigterm.watch().listen(shutdown));
  }
  await done.future;
  for (final sub in subs) {
    await sub.cancel();
  }
}
