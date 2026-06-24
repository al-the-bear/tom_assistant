// serve_runner.dart — the reusable `serve` boot, extracted from the old
// `bin/brain_serve.dart` (CLI plan step #8; `tom_brain_cli.md` § 5).
//
// `runBrainServe` is the production boot the `tom_brain serve` executor calls:
// it drives a [ServeBoot] seam to stand the cognition up (plus, by default, the
// co-hosted memory MCP server and Observatory), narrates the serving URLs, wires
// graceful SIGINT/SIGTERM teardown, and blocks until the process completes.
//
// The boot is a seam so a test can inject a fake [BrainServeSession] and assert
// the co-host defaults / `--no-*` flips reach it without binding real sockets.
// [defaultServeBoot] is the real composition root — the exact sequence the old
// launcher ran: install the standalone platform, install the trail fan-out log
// sink, emit the trail banner, `standUpBrainProcessFromConfig`, and (honouring
// the runtime knobs and a configured trail) spawn the memory MCP + Observatory
// isolates.

import 'dart:async';
import 'dart:io';

import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils, tomLog;
import 'package:tom_brain_memory/tom_brain_memory.dart' show FanoutLogOutput;
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;

import '../brain_run_config.dart';
import '../dream_cadence_driver.dart' show CadenceSchedule;
import '../memory_mcp_isolate_host.dart'
    show MemoryMcpIsolateHost, spawnMemoryMcpIsolate;
import '../observatory_banner.dart' show ObservatoryBanner;
import '../observatory_isolate_host.dart'
    show ObservatoryIsolateHost, spawnObservatoryIsolate;
import '../provision_brain.dart'
    show BrainProcess, standUpBrainProcessFromConfig;
import '../trail_banner.dart' show TrailBanner;
import 'package:tom_brain_observatory/tom_brain_observatory.dart'
    show ObservatoryOptions, RuntimeSnapshot;
import 'serve_config_assembler.dart' show ServeRuntimeOptions;

/// A one-line narrator for serving status (defaults to stdout in
/// [runBrainServe]; tests pass a silent or capturing sink).
typedef ServeNarrate = void Function(String message);

/// A booted serve session: the bound ports + URLs, the completion future, and
/// graceful teardown. The real session wraps a [BrainProcess] + the optional
/// co-hosted isolates; a test session is a fake.
abstract interface class BrainServeSession {
  /// The bound OpenAI edge port.
  int get openAiPort;

  /// Whether the Telegram channel came up.
  bool get telegramEnabled;

  /// The co-hosted memory MCP server URL, or `null` when not co-hosted.
  String? get memoryMcpUrl;

  /// The co-hosted Observatory URL, or `null` when not co-hosted.
  String? get observatoryUrl;

  /// Resolves with the process exit code once teardown completes.
  Future<int> get completed;

  /// Stops the Observatory, the memory MCP server, then the cognition.
  Future<void> stop();
}

/// The boot seam: stands a [BrainServeSession] up from a resolved [config] and
/// the co-host [runtime] knobs. [runConfigPath] is threaded so the running
/// brain can persist a changed bridge port back to its config file.
typedef ServeBoot = Future<BrainServeSession> Function(
  BrainRunConfig config,
  ServeRuntimeOptions runtime, {
  required String runConfigPath,
  required ServeNarrate narrate,
});

/// Boots the cognition over [boot], narrates the serving surface, wires
/// graceful teardown, and blocks until the process completes — returning its
/// exit code.
Future<int> runBrainServe(
  BrainRunConfig config,
  ServeRuntimeOptions runtime, {
  required String runConfigPath,
  ServeBoot boot = defaultServeBoot,
  ServeNarrate? narrate,
}) async {
  final say = narrate ?? (String m) => stdout.writeln(m);

  final BrainServeSession session = await boot(
    config,
    runtime,
    runConfigPath: runConfigPath,
    narrate: say,
  );

  say('tom_brain serving — OpenAI edge on '
      'http://127.0.0.1:${session.openAiPort}/v1 '
      '(POST /v1/chat/completions with a configured bearer token).');
  say('Telegram channel: '
      '${session.telegramEnabled ? 'enabled (long-polling)' : 'disabled'}.');
  if (session.memoryMcpUrl != null) {
    say('Memory MCP server: ${session.memoryMcpUrl}.');
  }
  if (session.observatoryUrl != null) {
    say('Trail Observatory: ${session.observatoryUrl}.');
  }
  say('Press Ctrl-C to stop.');

  var stopping = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    say('tom_brain: $signal — stopping…');
    await session.stop();
  }

  final subs = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen(shutdown),
  ];
  if (!Platform.isWindows) {
    subs.add(ProcessSignal.sigterm.watch().listen(shutdown));
  }

  final code = await session.completed;
  for (final sub in subs) {
    await sub.cancel();
  }
  return code;
}

/// The production boot: the exact sequence the old `bin/brain_serve.dart` ran.
Future<BrainServeSession> defaultServeBoot(
  BrainRunConfig config,
  ServeRuntimeOptions runtime, {
  required String runConfigPath,
  required ServeNarrate narrate,
}) async {
  // The real substrate sources its wire HTTP client from the kernel factory via
  // the active platform; install the standalone platform so the live
  // OpenAI/Ollama path is reachable (mirrors r32 / r34 / r36).
  TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);

  // Install the trail fan-out sink before anything logs (logging-spec §5.1):
  // the trail root in full mode, the CWD when no trail block is configured.
  final Directory logRoot = config.trail == null
      ? Directory.current
      : Directory(config.trail!.root);
  tomLog.logOutput = FanoutLogOutput(logRoot: logRoot);
  tomLog.status(
    TrailBanner.forStartup(config.trail, cwd: Directory.current.path),
  );

  final BrainProcess process = await standUpBrainProcessFromConfig(
    config,
    isolateLogRootPath: logRoot.path,
    runConfigPath: runConfigPath,
  );

  // Co-host the read-only Observatory and its read-mostly memory MCP server in
  // their own isolates, unless turned off or no trail tree is configured
  // (nothing for the mirror to read). A failure to come up is non-fatal.
  MemoryMcpIsolateHost? memoryMcp;
  ObservatoryIsolateHost? observatory;
  if (runtime.memoryMcpEnabled && config.trail != null) {
    memoryMcp = await spawnMemoryMcpIsolate(
      runConfigPath,
      port: runtime.memoryMcpPort,
      onInfo: (m) => tomLog.status('[tom_brain.memory.mcp] $m'),
      onWarning: (m) => tomLog.status('[tom_brain.memory.mcp] $m'),
    );
  }
  if (runtime.observatoryEnabled && config.trail != null) {
    observatory = await spawnObservatoryIsolate(
      ObservatoryOptions(
        trailRoot: config.trail!.root,
        cognitionDir: config.cognition?.root,
        runConfigDir: File(runConfigPath).parent.path,
        memoryMcpUrl: memoryMcp?.url.toString(),
        host: runtime.observatoryHost,
        port: runtime.observatoryPort,
        configWritable: !runtime.observatoryReadonly,
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
          history: config.history.toJson(),
          cadence: config.dream?.cadence ?? CadenceSchedule.defaults(),
        ),
      ),
      onInfo: (m) => tomLog.status('[tom_brain.observatory] $m'),
      onWarning: (m) => tomLog.status('[tom_brain.observatory] $m'),
    );
    if (observatory != null) {
      tomLog.status(
        ObservatoryBanner.running(observatory.url, config.trail!.root),
      );
    }
  }

  return _DefaultBrainServeSession(
    process: process,
    memoryMcp: memoryMcp,
    observatory: observatory,
    telegramEnabled: config.access.hasTelegram,
  );
}

/// The real [BrainServeSession]: the [BrainProcess] plus the optional co-hosted
/// isolates, torn down Observatory → memory MCP → cognition so no request
/// outlives the store handle behind it.
class _DefaultBrainServeSession implements BrainServeSession {
  _DefaultBrainServeSession({
    required BrainProcess process,
    required MemoryMcpIsolateHost? memoryMcp,
    required ObservatoryIsolateHost? observatory,
    required this.telegramEnabled,
  })  : _process = process,
        _memoryMcp = memoryMcp,
        _observatory = observatory;

  final BrainProcess _process;
  final MemoryMcpIsolateHost? _memoryMcp;
  final ObservatoryIsolateHost? _observatory;

  @override
  final bool telegramEnabled;

  @override
  int get openAiPort => _process.port;

  @override
  String? get memoryMcpUrl => _memoryMcp?.url.toString();

  @override
  String? get observatoryUrl => _observatory?.url.toString();

  @override
  Future<int> get completed => _process.completed;

  @override
  Future<void> stop() async {
    await _observatory?.stop();
    await _memoryMcp?.stop();
    await _process.stop();
  }
}
