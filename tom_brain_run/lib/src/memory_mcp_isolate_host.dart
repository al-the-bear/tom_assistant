// spawnMemoryMcpIsolate — hosts the read-mostly memory MCP server (v1) in a
// second isolate inside the running brain process, so the operator no longer
// launches a separate `dart run tom_brain_memory/bin/memory_mcp_server.dart`.
// Its sole consumer here is the in-process Trail Observatory: the observatory's
// `/api/memory/*` routes connect to this endpoint, so without it they 503
// "memory unavailable". Hosting it in-process is what makes `run_tom_brain.sh`
// start *everything relevant* in one process.
//
// Why a second store handle (not the brain's memory isolate): the MCP tool
// surface (`registerMemoryTools`) needs the full in-process `TomBrainMemory`
// Dart API, but the brain's memory isolate only exposes the narrower
// `TomBrainMemoryClient` over its isolate adapter. So this server opens its own
// `SqliteTomBrainMemory` against the *same* on-disk root — exactly what the
// standalone `memory_mcp_server.dart` does. The store opens WAL-mode with a
// busy-timeout, so the brain's writer and this read-mostly server hold the same
// root concurrently (readers never block the single writer), and the boot is
// idempotent on an already-seeded store, so start order does not matter
// (`memory_specification.md` § 3.2).
//
// Why a dedicated isolate (not the main isolate): SQLite / sqlite-vec queries
// are synchronous work. Running them on the main isolate would compete with the
// access-serving event loop (the OpenAI gateway, Telegram, the dream cadence).
// A dedicated isolate keeps the inspection surface's queries off the brain's hot
// path, and buys the same fault isolation the observatory isolate has.
//
// Signal discipline: the spawned entry must NEVER touch `ProcessSignal` or
// `exit` — those are process-wide and belong to the parent brain isolate
// (`tom_brain serve`). The entry stops only on an explicit control message from the
// host; the parent's SIGINT/SIGTERM handler calls [MemoryMcpIsolateHost.stop],
// which closes both the HTTP transport and the store (a truncating WAL
// checkpoint), mirroring the standalone server's graceful shutdown.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        McpHttpServer,
        MemoryConfig,
        MemoryConfigLoader,
        SqliteTomBrainMemory,
        TomBrainMemoryMcpServer;

/// A narration sink for a single host line (a started / warning message). The
/// run layer routes it to `tomLog` / the console.
typedef MemoryMcpHostLog = void Function(String message);

/// A running in-process memory MCP server — the spawned isolate plus the live
/// endpoint URL and a graceful [stop]. Returned by [spawnMemoryMcpIsolate] (or
/// `null` when the server failed to come up, which is non-fatal: the brain
/// serves without it and the observatory's `/api/memory/*` routes 503).
final class MemoryMcpIsolateHost {
  final Isolate _isolate;
  final SendPort _control;
  final ReceivePort _events;
  final ReceivePort _exit;
  final StreamSubscription<dynamic> _sub;

  /// The loopback Streamable-HTTP endpoint the MCP server bound, including the
  /// `/mcp` path — the URL the observatory connects to.
  final Uri url;

  bool _stopped = false;

  MemoryMcpIsolateHost._(
    this._isolate,
    this._control,
    this._events,
    this._exit,
    this._sub,
    this.url,
  );

  /// Asks the spawned isolate to close its transport and store, then reaps it.
  /// Idempotent. If the isolate does not exit within [grace] it is killed, so a
  /// wedged server can never block the brain's shutdown.
  Future<void> stop({Duration grace = const Duration(seconds: 5)}) async {
    if (_stopped) return;
    _stopped = true;
    _control.send('stop');
    try {
      await _exit.first.timeout(grace);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
    }
    await _sub.cancel();
    _events.close();
    _exit.close();
  }
}

/// Spawns the memory MCP server in a second isolate against the `memory:` block
/// of the run config at [runConfigPath], and returns a live
/// [MemoryMcpIsolateHost], or `null` when it could not be brought up within
/// [readyTimeout] (the brain then serves without it — a missing inspection
/// surface is never fatal).
///
/// [port] is the loopback bind port; the default `0` lets the OS assign an
/// ephemeral port (the bound URL is reported back), so the server never collides
/// with a running standalone `memory_mcp_server.dart`. The endpoint is bound
/// loopback-only and anonymous (no bearer auth) — the same trust-the-loopback
/// posture as the standalone server's default. Narration emitted during boot is
/// forwarded to [onInfo] / [onWarning] so the run layer can log it from the main
/// isolate.
Future<MemoryMcpIsolateHost?> spawnMemoryMcpIsolate(
  String runConfigPath, {
  int port = 0,
  MemoryMcpHostLog? onInfo,
  MemoryMcpHostLog? onWarning,
  Duration readyTimeout = const Duration(seconds: 30),
}) async {
  final info = onInfo ?? (_) {};
  final warn = onWarning ?? (_) {};

  final events = ReceivePort();
  final exitPort = ReceivePort();

  final Isolate isolate;
  try {
    isolate = await Isolate.spawn<_MemoryMcpBoot>(
      _memoryMcpIsolateEntry,
      (runConfigPath: runConfigPath, port: port, events: events.sendPort),
      onExit: exitPort.sendPort,
      debugName: 'tom_brain_memory_mcp',
      errorsAreFatal: false,
    );
  } catch (e) {
    warn('could not spawn the memory MCP isolate ($e) — '
        'serving without it (the observatory\'s /api/memory/* will 503).');
    events.close();
    exitPort.close();
    return null;
  }

  final ready = Completer<MemoryMcpIsolateHost?>();
  late final StreamSubscription<dynamic> sub;
  sub = events.listen((dynamic msg) {
    if (msg is! Map) return;
    switch (msg['status']) {
      case 'ready':
        if (ready.isCompleted) return;
        ready.complete(MemoryMcpIsolateHost._(
          isolate,
          msg['control'] as SendPort,
          events,
          exitPort,
          sub,
          Uri.parse(msg['url'] as String),
        ));
      case 'error':
        warn('memory MCP server failed to start (${msg['message']}) — '
            'serving without it (the observatory\'s /api/memory/* will 503).');
        if (!ready.isCompleted) ready.complete(null);
      default:
        // Forwarded boot narration (`{'log': 'info'|'warn', 'message': …}`).
        final message = msg['message'];
        if (message is! String) return;
        if (msg['log'] == 'warn') {
          warn(message);
        } else {
          info(message);
        }
    }
  });

  final host = await ready.future.timeout(readyTimeout, onTimeout: () {
    warn('memory MCP server did not report ready within '
        '${readyTimeout.inSeconds}s — serving without it.');
    return null;
  });

  if (host == null) {
    // Either error / timeout: tear the half-started isolate down so it never
    // lingers holding a half-open store or socket.
    isolate.kill(priority: Isolate.immediate);
    await sub.cancel();
    events.close();
    exitPort.close();
  }
  return host;
}

/// The message [Isolate.spawn] hands [_memoryMcpIsolateEntry]: the run-config
/// path (the isolate loads the `memory:` block itself, avoiding any
/// sendability concern over the parsed config), the loopback bind port, and the
/// [SendPort] the entry reports lifecycle + narration back on.
typedef _MemoryMcpBoot = ({String runConfigPath, int port, SendPort events});

/// The second-isolate entrypoint: open the on-disk `SqliteTomBrainMemory` at the
/// config's `memory:` root, bind the read-mostly MCP v1 surface over Streamable
/// HTTP, report `ready` (with the bound `/mcp` URL + a control port) or `error`,
/// then block on the control port until told to `stop`. Touches no
/// `ProcessSignal` and never `exit`s — the parent brain isolate owns the process
/// lifecycle.
Future<void> _memoryMcpIsolateEntry(_MemoryMcpBoot boot) async {
  final events = boot.events;

  final SqliteTomBrainMemory memory;
  final McpHttpServer server;
  try {
    final MemoryConfig config = MemoryConfigLoader.loadFromFile(
      boot.runConfigPath,
      envVars: Platform.environment,
    );
    memory = SqliteTomBrainMemory();
    await memory.open(config);
    events.send(<String, Object?>{
      'log': 'info',
      'message': 'memory MCP server opened store root: ${config.root}',
    });
    server = await McpHttpServer.bind(
      port: boot.port,
      onSession: (channel) => TomBrainMemoryMcpServer(channel, memory: memory),
    );
  } catch (e) {
    events.send(<String, Object?>{'status': 'error', 'message': '$e'});
    return;
  }

  final control = ReceivePort();
  events.send(<String, Object?>{
    'status': 'ready',
    'url': server.url.toString(),
    'control': control.sendPort,
  });

  await for (final msg in control) {
    if (msg == 'stop') break;
  }
  // Graceful shutdown mirrors the standalone server: close the HTTP transport
  // first, then close the store (a truncating WAL checkpoint).
  await server.close();
  await memory.close();
  control.close();
}
