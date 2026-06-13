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
//   dart run bin/brain_serve.dart <run-config.yaml>
//
// `${ENV}` references in the config (e.g. `access.telegram.botToken:
// "${TELEGRAM_BOT_TOKEN}"`) are expanded from this process's environment.
import 'dart:async';
import 'dart:io';

import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils, tomLog;
import 'package:tom_brain_memory/tom_brain_memory.dart' show FanoutLogOutput;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_core_server/tom_core_server.dart' show standalonePlatformUtils;

Future<void> main(List<String> args) async {
  if (args.length != 1 || args.first.startsWith('-')) {
    stderr.writeln('usage: dart run bin/brain_serve.dart <run-config.yaml>');
    exitCode = 64; // EX_USAGE
    return;
  }
  final String configPath = args.first;

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

  // Point the operator at the read-only Trail Observatory (a separate loopback
  // process). `tomLog.status` renders the `STATUS ` level; the banner names the
  // URL to open and the trail root to launch it against.
  tomLog.status(ObservatoryBanner.forStartup(config.trail));

  stdout.writeln('Press Ctrl-C to stop.');
  await stdout.flush();

  // Graceful teardown: stop the access channels and the booted cognition (drain
  // foreground, dispose the memory isolate, close the substrate) on a signal.
  bool stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    stdout.writeln('brain_serve: $signal — stopping…');
    await process.stop();
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }

  final int code = await process.completed;
  exitCode = code;
}
