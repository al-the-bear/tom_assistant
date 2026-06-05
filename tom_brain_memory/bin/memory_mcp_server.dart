// Standalone memory MCP server — the brain's external memory-inspection
// surface (`memory_specification.md` § 3.2), run as its own OS process.
//
// It opens the real on-disk `SqliteTomBrainMemory` at the `memory:` root of a
// run config and serves the read-only MCP v1 tool surface over Streamable HTTP
// (`McpHttpServer`, path `/mcp`). The store opens WAL-mode with a 5 s
// busy-timeout, so this server and the live brain process can hold the *same*
// on-disk root concurrently — readers never block the single writer, and the
// boot is idempotent on an already-seeded store (so start order does not
// matter).
//
// Usage:
//   dart run bin/memory_mcp_server.dart <run-config.yaml> [--port N]
//
// `<run-config.yaml>` is the same whole-process config the brain launcher
// consumes; only its `memory:` section is read here. `--port` defaults to 8765
// (pass 0 for an OS-assigned port). The process prints one machine-readable
// handshake line — `MCP_HTTP_PORT=<port>` — then serves until SIGINT/SIGTERM.
import 'dart:async';
import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart';

/// The marker prefix a supervisor can scan stdout for to discover the port.
const String _portMarker = 'MCP_HTTP_PORT=';

const int _defaultPort = 8765;

Future<void> main(List<String> args) async {
  final _Args parsed;
  try {
    parsed = _Args.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('memory_mcp_server: ${e.message}');
    stderr.writeln(
      'usage: dart run bin/memory_mcp_server.dart <run-config.yaml> [--port N]',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  // The store loads the sqlite-vec extension at open() and refuses to boot
  // without it; the config's `memory.sqliteVec.binariesRoot` must point at the
  // packaged vec0 for this platform.
  final MemoryConfig config = MemoryConfigLoader.loadFromFile(parsed.configPath);

  final SqliteTomBrainMemory memory = SqliteTomBrainMemory();
  await memory.open(config);

  final McpHttpServer server = await McpHttpServer.bind(
    port: parsed.port,
    onSession: (channel) => TomBrainMemoryMcpServer(channel, memory: memory),
  );

  // One machine-readable handshake line, then human-readable context.
  stdout.writeln('$_portMarker${server.port}');
  stdout.writeln(
    'memory MCP server (read-only v1) serving at '
    'http://127.0.0.1:${server.port}/mcp — store root: ${config.root}',
  );
  await stdout.flush();

  // Graceful shutdown on a termination signal: close the HTTP transport, then
  // close the store (truncating WAL checkpoint) before exiting.
  final Completer<void> done = Completer<void>();
  void shutdown(ProcessSignal signal) {
    if (done.isCompleted) return;
    stdout.writeln('memory_mcp_server: ${signal.toString()} — shutting down');
    done.complete();
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  // SIGTERM is not deliverable on Windows; guard so the launcher stays portable.
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }

  await done.future;
  await server.close();
  await memory.close();
}

/// Parsed command line: the required config path and the optional `--port`.
final class _Args {
  final String configPath;
  final int port;

  const _Args._(this.configPath, this.port);

  static _Args parse(List<String> args) {
    String? configPath;
    int port = _defaultPort;

    for (int i = 0; i < args.length; i++) {
      final String arg = args[i];
      if (arg == '--port') {
        if (i + 1 >= args.length) {
          throw const FormatException('--port requires a value');
        }
        port = _parsePort(args[++i]);
      } else if (arg.startsWith('--port=')) {
        port = _parsePort(arg.substring('--port='.length));
      } else if (arg.startsWith('-')) {
        throw FormatException('unknown option: $arg');
      } else if (configPath == null) {
        configPath = arg;
      } else {
        throw const FormatException('unexpected extra positional argument');
      }
    }

    if (configPath == null) {
      throw const FormatException('missing required <run-config.yaml> argument');
    }
    return _Args._(configPath, port);
  }

  static int _parsePort(String raw) {
    final int? value = int.tryParse(raw);
    if (value == null || value < 0 || value > 65535) {
      throw FormatException('invalid port: $raw (expected 0..65535)');
    }
    return value;
  }
}
