// Standalone tom_brain process — boots the whole cognition from a run config
// and serves prompts over every configured access channel (OpenAI HTTP/SSE and,
// when `access.telegram.botToken` is set, the Telegram bot).
//
// This is the production sibling of the `r32`/`r34`/`r36` live tests: it
// installs the standalone platform (so the real substrate's HTTP client factory
// is available — a bare `dart run` otherwise uses the fallback platform whose
// `httpClient()` throws), parses the config, and calls
// `standUpBrainProcessFromConfig`, which manufactures the real substrate
// (oMLX chat + Ollama embeddings), boots the real on-disk `SqliteTomBrainMemory`,
// and stands the access process up. It then serves until SIGINT/SIGTERM.
//
// Usage:
//   dart run bin/brain_serve.dart <run-config.yaml> [--no-observatory]
//       [--observatory-port=N] [--observatory-host=ADDR]
//
// The Trail Observatory (the official config + control surface) is hosted
// in-process by default, in a second isolate; `--no-observatory` skips it and
// `--observatory-port` / `--observatory-host` move its loopback bind.
//
// `${ENV}` references in the config (e.g. `access.telegram.botToken:
// "${TELEGRAM_BOT_TOKEN}"`) are expanded from this process's environment.
import 'dart:async';
import 'dart:io';

import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils, tomLog;
import 'package:tom_brain_memory/tom_brain_memory.dart' show FanoutLogOutput;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_core_server/tom_core_server.dart' show standalonePlatformUtils;

const String _usage = 'usage: dart run bin/brain_serve.dart <run-config.yaml> '
    '[--no-observatory] [--observatory-port=N] [--observatory-host=ADDR]';

Future<void> main(List<String> args) async {
  final List<String> positional =
      args.where((a) => !a.startsWith('-')).toList();
  if (positional.length != 1) {
    stderr.writeln(_usage);
    exitCode = 64; // EX_USAGE
    return;
  }
  final String configPath = positional.single;

  // The Observatory is hosted in-process by default; the flags only turn it off
  // or move its loopback bind. Unknown flags are a usage error, so a typo never
  // silently changes behaviour.
  bool observatoryEnabled = true;
  String observatoryHost = ObservatoryOptions.defaultHost;
  int observatoryPort = ObservatoryOptions.defaultPort;
  for (final String flag in args.where((a) => a.startsWith('-'))) {
    if (flag == '--observatory') {
      observatoryEnabled = true;
    } else if (flag == '--no-observatory') {
      observatoryEnabled = false;
    } else if (flag.startsWith('--observatory-port=')) {
      final int? value = int.tryParse(flag.substring(flag.indexOf('=') + 1));
      if (value == null) {
        stderr.writeln('brain_serve: --observatory-port needs an integer.');
        exitCode = 64;
        return;
      }
      observatoryPort = value;
    } else if (flag.startsWith('--observatory-host=')) {
      observatoryHost = flag.substring(flag.indexOf('=') + 1);
    } else {
      stderr.writeln('brain_serve: unknown flag "$flag".\n$_usage');
      exitCode = 64;
      return;
    }
  }

  final File configFile = File(configPath);
  if (!configFile.existsSync()) {
    stderr.writeln('brain_serve: config not found: $configPath');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  // The real substrate sources its wire HTTP client from the `tom_core_kernel`
  // factory via the active `TomPlatformUtils`; install the standalone platform
  // so the live OpenAI/Ollama path is reachable (mirrors r32 / r34 / r36).
  TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);

  final BrainRunConfig config = BrainRunConfigLoader.parse(
    configFile.readAsStringSync(),
    envVars: Platform.environment,
  );

  // Install the component file sink before anything logs (logging-spec §5.1 /
  // §10 step #3) so the trail banner itself lands in `brain.log`. The root is
  // `trail.root` in full mode and the current working directory when no
  // `trail:` block is configured (§4.1). `FanoutLogOutput` tees to the console,
  // so the existing stdout/stderr behaviour is preserved.
  final Directory logRoot = config.trail == null
      ? Directory.current
      : Directory(config.trail!.root);
  tomLog.logOutput = FanoutLogOutput(logRoot: logRoot);

  // Announce the active trail mode before anything writes a trail surface
  // (logging-spec §4.1). `tomLog.status` renders the `STATUS ` level the §4.1
  // example shows; the banner body carries the `[tom_brain.trail]` category.
  tomLog.status(
    TrailBanner.forStartup(config.trail, cwd: Directory.current.path),
  );

  // The memory isolate runs its own `tomLog`; thread the same root so its
  // component lines (`tom_brain.memory.*`) reach the same files (§5.1, §2.1).
  final BrainProcess process = await standUpBrainProcessFromConfig(
    config,
    isolateLogRootPath: logRoot.path,
    // The on-disk run-config path, so `/cli_server_port` can persist a changed
    // bridge port back into the file it booted from (survives a restart).
    runConfigPath: configPath,
  );

  stdout.writeln(
    'tom_brain process serving — OpenAI edge on '
    'http://127.0.0.1:${process.port}/v1 '
    '(send POST /v1/chat/completions with a configured bearer token).',
  );
  stdout.writeln(
    'Telegram channel: '
    '${config.access.hasTelegram ? 'enabled (long-polling)' : 'disabled (no access.telegram.botToken)'}.',
  );

  // Host the read-only Trail Observatory in a second isolate (the official
  // config + control surface), unless `--no-observatory` was passed or no trail
  // tree is configured (there is nothing for the mirror to read). It binds its
  // own loopback socket; a failure to come up is non-fatal — the brain keeps
  // serving and the banner falls back to the hand-launch hint.
  //
  // The observatory's `/api/memory/*` routes connect to the read-mostly memory
  // MCP server, so we host that in-process too (a third isolate, an ephemeral
  // loopback port) and thread its URL into the observatory. Hosting it here is
  // what lets `run_tom_brain.sh` start the whole inspection surface in one
  // process — no separate `memory_mcp_server.dart`. It opens its own WAL
  // concurrent handle on the same store root; a failure to come up is non-fatal
  // (the observatory then 503s the memory routes).
  MemoryMcpIsolateHost? memoryMcp;
  ObservatoryIsolateHost? observatory;
  if (observatoryEnabled && config.trail != null) {
    memoryMcp = await spawnMemoryMcpIsolate(
      configPath,
      onInfo: (m) => tomLog.status('[tom_brain.memory.mcp] $m'),
      onWarning: (m) => tomLog.status('[tom_brain.memory.mcp] $m'),
    );
    observatory = await spawnObservatoryIsolate(
      ObservatoryOptions(
        trailRoot: config.trail!.root,
        cognitionDir: config.cognition?.root,
        runConfigDir: File(configPath).parent.path,
        memoryMcpUrl: memoryMcp?.url.toString(),
        host: observatoryHost,
        port: observatoryPort,
        // The live values the process actually bound, for the Runtime tab's
        // "currently running" display (prompt_tracing.md § 6.4, § 8.3(13)).
        // `process.port` is the bound OpenAI edge port; the rest come from the
        // parsed config the brain booted from.
        runtime: RuntimeSnapshot(
          openAiPort: process.port,
          openAiBasePath: config.access.openAiBasePath,
          ollamaPort: config.access.ollamaPort,
          ollamaBasePath: config.access.ollamaBasePath,
          anthropicPort: config.access.anthropicPort,
          anthropicBasePath: config.access.anthropicBasePath,
          telegramEnabled: config.access.hasTelegram,
          memoryRoot: config.memory.root,
          trailRoot: config.trail?.root,
          cognitionRoot: config.cognition?.root,
          // The resolved per-lane conversation-history sizing the brain bound
          // (lane → defaults → code default), for the Runtime tab's effective
          // sizing display (history-compaction quest, todo #16).
          history: config.history.toJson(),
        ),
      ),
      onInfo: (m) => tomLog.status('[tom_brain.observatory] $m'),
      onWarning: (m) => tomLog.status('[tom_brain.observatory] $m'),
    );
  }

  // `tomLog.status` renders the `STATUS ` level. When the observatory is serving
  // in-process the banner names its bound URL; otherwise it names the URL and the
  // hand-launch command for the standalone process.
  tomLog.status(
    observatory != null
        ? ObservatoryBanner.running(observatory.url, config.trail!.root)
        : ObservatoryBanner.forStartup(
            config.trail,
            host: observatoryHost,
            port: observatoryPort,
          ),
  );

  stdout.writeln('Press Ctrl-C to stop.');
  await stdout.flush();

  // Graceful teardown: stop the observatory isolate and its memory MCP server,
  // then the access channels and the booted cognition (drain foreground, dispose
  // the memory isolate, close the substrate) on a signal. The observatory is
  // stopped before the memory MCP server it reads from, so no request outlives
  // the store handle behind it.
  bool stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    stdout.writeln('brain_serve: $signal — stopping…');
    await observatory?.stop();
    await memoryMcp?.stop();
    await process.stop();
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }

  final int code = await process.completed;
  exitCode = code;
}
