// The `serve` command executor for the access-prototype process (E.45).
//
// This is the entry point the `ToolRunner` dispatches the (default) `serve`
// command to. It is the thin I/O boundary around the boot root
// (`startBrainAccessProcess`, boot/): it loads the `AccessConfig` (from the
// `--config` file, or a permissive built-in default), **provisions** the
// cognition through the injected [BrainProvisioner], and serves until a
// termination signal drives the graceful teardown.
//
// ── Why the provisioner is injected, and why the CLI default refuses ──
//
// The access package may not import `tom_brain_substrate` / `tom_brain_memory`
// (pubspec § "Explicitly NOT here"), and `BrainProcessBoot.boot` requires a
// `TomBrainSubstrateClient` — a forbidden type. So this executor cannot boot a
// brain on its own; it takes one through the [BrainProvisioner] seam. The CLI
// default ([unsupportedBrainProvisioner]) refuses with a clear message naming
// the missing wiring (Q-E.45.1), so a bare `serve` invocation reports the
// boundary honestly — and without crashing the tool framework — rather than
// pretending to serve. A higher assembly (Tom Assistant integration, or a test)
// constructs the executor with a real provisioner.
//
// The `serve` command is declared non-traversal (see
// `access_prototype_tool.dart`), so the `ToolRunner` dispatches to
// [executeWithoutTraversal]. [execute] is part of the [CommandExecutor]
// contract but is unreachable for a non-traversal command; it delegates to the
// same routine so the two entry points cannot drift.

import 'dart:io';

import 'package:tom_build_base/tom_build_base_v2.dart';

import '../boot/boot.dart';
import '../config/access_config.dart';
import '../config/access_config_loader.dart';
import '../edge_security/edge_security.dart';
import 'access_prototype_tool.dart';

/// Executor for the `serve` command (E.45).
///
/// Construct it with a [BrainProvisioner] (the CLI default refuses; a higher
/// assembly injects a real one) and optionally the [AccessServeSeam] /
/// [TelegramChatApiFactory] seams (defaults bind a real socket / Telegram
/// backend; a test injects fakes).
class AccessServeExecutor extends CommandExecutor {
  final BrainProvisioner _provisioner;
  final AccessServeSeam _serve;
  final TelegramChatApiFactory _telegramChatApiFactory;

  /// Builds the executor over its injected seams.
  AccessServeExecutor({
    BrainProvisioner provisioner = unsupportedBrainProvisioner,
    AccessServeSeam serve = serveWithShelfIo,
    TelegramChatApiFactory telegramChatApiFactory =
        defaultTelegramChatApiFactory,
  })  : _provisioner = provisioner,
        _serve = serve,
        _telegramChatApiFactory = telegramChatApiFactory;

  @override
  Future<ToolResult> executeWithoutTraversal(CliArgs args) async {
    return _serveProcess(args);
  }

  // Unreachable for a non-traversal command, but the contract requires it.
  // Delegating keeps the two paths in lockstep if `serve` ever becomes
  // traversal-capable.
  @override
  Future<ItemResult> execute(CommandContext context, CliArgs args) async {
    final ToolResult result = await _serveProcess(args);
    return result.success
        ? ItemResult.success(
            path: context.path,
            name: context.name,
            message: 'access process exited cleanly',
          )
        : ItemResult.failure(
            path: context.path,
            name: context.name,
            error: result.errorMessage ?? 'access process failed',
          );
  }

  /// Loads the config, provisions the cognition, and serves until shutdown.
  ///
  /// Returns a failure (without throwing through the tool framework) when no
  /// usable [BrainProvisioner] is wired — the honest expression of the
  /// substrate / memory dependency boundary (Q-E.45.1).
  Future<ToolResult> _serveProcess(CliArgs args) async {
    final AccessConfig config = _loadConfig(args);

    final ProvisionedBrain brain;
    try {
      brain = await _provisioner(config);
    } on BrainProvisioningException catch (failure) {
      print(accessPrototypeVersionString);
      print('Cannot start the access process: no brain is wired.');
      print(failure.message);
      return ToolResult.failure(failure.message);
    }

    final BrainAccessProcess process = await startBrainAccessProcess(
      config: config,
      brain: brain,
      serve: _serve,
      telegramChatApiFactory: _telegramChatApiFactory,
    );
    print(accessPrototypeVersionString);
    print('Serving the OpenAI + /healthz surface on port ${process.port}.');
    if (config.hasTelegram) {
      print('Telegram channel active (long-polling).');
    }
    print('Send SIGINT / SIGTERM to shut down gracefully.');

    // Blocks for the process lifetime; `completed` resolves only after a
    // termination signal drives the teardown. The teardown is itself bounded
    // (`shutdownDeadline`, G.3.6), so this wait cannot hang on a wedged drain —
    // a blanket timeout *here* would instead (wrongly) fire during healthy
    // serving, since `completed` does not resolve until shutdown begins.
    final int exitCode = await process.completed;
    return exitCode == shutdownExitOk
        ? const ToolResult.success(processedCount: 1)
        : ToolResult.failure(
            'The access process shut down with exit code $exitCode.',
          );
  }

  /// Resolves the `AccessConfig`: parses the `--config` file when supplied
  /// (expanding `${ENV}` from the real environment — the executor is the I/O
  /// boundary the deterministic loader leaves that to), or the permissive
  /// built-in default otherwise.
  AccessConfig _loadConfig(CliArgs args) {
    final String? configPath = args.configPath;
    if (configPath == null) {
      return _defaultAccessConfig();
    }
    return AccessConfigLoader.loadFromFile(
      configPath,
      envVars: Platform.environment,
    );
  }

  /// The permissive built-in `AccessConfig` for a `--config`-less invocation:
  /// the default OpenAI port, generous edge-security limits, and no anchor
  /// signatures (the screen is disabled). Bindings are empty — with no
  /// provisioner wired (the CLI default) the process never reaches admission
  /// anyway; a higher assembly that actually serves supplies a real config
  /// file (Q-E.45.4).
  static AccessConfig _defaultAccessConfig() => AccessConfig(
        openAiPort: defaultAccessOpenAiPort,
        rateLimitPolicy: RateLimitPolicy(
          capacity: 60,
          refillTokens: 60,
          refillPeriod: const Duration(minutes: 1),
        ),
        dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100000),
        anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
      );
}

/// Build the executor map the `ToolRunner` dispatches against.
///
/// Keyed by command name (`serve`); the bare invocation routes here via the
/// tool's `defaultCommand`. The [provisioner] defaults to
/// [unsupportedBrainProvisioner] (the standalone binary cannot boot a brain);
/// a higher assembly or a test passes a real one, optionally with its own
/// [serve] / [telegramChatApiFactory] seams.
Map<String, CommandExecutor> createAccessPrototypeExecutors({
  BrainProvisioner provisioner = unsupportedBrainProvisioner,
  AccessServeSeam serve = serveWithShelfIo,
  TelegramChatApiFactory telegramChatApiFactory = defaultTelegramChatApiFactory,
}) {
  return {
    accessServeCommandName: AccessServeExecutor(
      provisioner: provisioner,
      serve: serve,
      telegramChatApiFactory: telegramChatApiFactory,
    ),
  };
}
