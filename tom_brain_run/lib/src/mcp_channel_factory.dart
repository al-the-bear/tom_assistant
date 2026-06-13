// productionMcpChannelFactory — the composition-root transport seam that opens
// a real wire channel to a configured external MCP server (request f;
// `tom_brain_procedure_specification.md` § 21.3).
//
// The procedure package's `DartMcpConnector` is transport-neutral: it takes a
// `McpChannelFactory` and never spawns a process or opens a socket itself (the
// `dart_mcp_connection.dart` header is explicit that OS I/O stays at the
// composition root). This file IS that composition root for the run assembly —
// the one place a child process is started for a `stdio:` server.
//
// ── Transports ───────────────────────────────────────────────────────
//
//   * `stdio` — the dominant external-MCP transport. We `Process.start` the
//     server's `command` + `args` and wrap its stdout/stdin in dart_mcp's
//     line-delimited `stdioChannel`. A spawn failure (missing executable,
//     non-zero exec) propagates and `DartMcpConnector.connect` wraps it as an
//     `mcp.unreachable` `McpFailure` — environmental (PE-6), so the boot-time
//     tool merge simply omits that server rather than aborting.
//
//   * `http` — dart_mcp 0.5.1 ships no client-side Streamable-HTTP transport,
//     so an `http:` external server raises an `mcp.unreachable` `McpFailure`
//     here. It is environmental, not a config error: the server is configured
//     correctly, the running build just cannot reach it over HTTP, so its
//     tools are omitted at boot (PE-6) exactly like an unreachable stdio one.
//     (The memory MCP server is reached in-process, not through this factory.)

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/stdio.dart' show stdioChannel;
import 'package:stream_channel/stream_channel.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        McpChannelFactory,
        McpFailure,
        McpServerConfig,
        McpTransport,
        mcpUnreachableCode;

/// The production [McpChannelFactory] the run assembly hands its
/// `DartMcpConnector` (request f).
///
/// Dispatches on [McpServerConfig.transport]: a [McpTransport.stdio] server is
/// spawned as a child process; a [McpTransport.http] server raises an
/// `mcp.unreachable` [McpFailure] (no HTTP client transport in this build).
McpChannelFactory productionMcpChannelFactory() => _openProductionChannel;

Future<StreamChannel<String>> _openProductionChannel(
  McpServerConfig config,
) async {
  switch (config.transport) {
    case McpTransport.stdio:
      return _openStdioChannel(config);
    case McpTransport.http:
      throw McpFailure(
        mcpUnreachableCode,
        serverId: config.id,
        message: 'http MCP transport is not supported by this build '
            '(server "${config.id}")',
      );
  }
}

/// Spawns the [config]'s child process and wraps its stdio as a
/// line-delimited MCP channel.
///
/// A missing [McpServerConfig.command] is a configured-but-unreachable server
/// (an `mcp.unreachable` [McpFailure]); a spawn I/O error propagates and the
/// connector wraps it the same way.
Future<StreamChannel<String>> _openStdioChannel(
  McpServerConfig config,
) async {
  final command = config.command;
  if (command == null || command.isEmpty) {
    throw McpFailure(
      mcpUnreachableCode,
      serverId: config.id,
      message: 'stdio MCP server "${config.id}" has no "command"',
    );
  }
  final process = await Process.start(command, config.args);
  // Surface the child's stderr as warnings without coupling the channel to it.
  unawaited(process.stderr.drain<void>());
  return stdioChannel(input: process.stdout, output: process.stdin);
}
