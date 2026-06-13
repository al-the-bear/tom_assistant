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
//   * `http` — the Streamable-HTTP (POST + JSON response) transport, reached by
//     delegating to the substrate's `HttpMcpTransport`
//     (`tom_brain_substrate/lib/src/mcp_client/http_transport.dart`) — the same
//     transport the substrate's own outbound MCP client already uses, so the run
//     assembly reuses it rather than rebuilding an HTTP MCP stack. The VS Code
//     Extension MCP server (request b; `agent_sdk_provider_and_mcp_liveness.md`
//     § 2) is reached this way at `http://127.0.0.1:19920/`. A server with no
//     `url` is a configured-but-unreachable server (`mcp.unreachable`); a
//     network failure surfaces through the transport's channel exactly like an
//     unreachable stdio one (PE-6), so its tools are omitted at boot.
//     (The memory MCP server is reached in-process, not through this factory.)

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/stdio.dart' show stdioChannel;
import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        McpChannelFactory,
        McpFailure,
        McpServerConfig,
        McpTransport,
        mcpUnreachableCode;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show HttpMcpTransport, McpBearerCredential;

/// The production [McpChannelFactory] the run assembly hands its
/// `DartMcpConnector` (request f).
///
/// Dispatches on [McpServerConfig.transport]: a [McpTransport.stdio] server is
/// spawned as a child process; a [McpTransport.http] server opens a
/// Streamable-HTTP channel via the substrate's `HttpMcpTransport`.
///
/// [httpClient] is an optional `package:http.Client` injected for the HTTP
/// transport (tests own its lifetime). When `null` — the production default —
/// `HttpMcpTransport` sources its client from the workspace-shared
/// `tom_core_kernel.TomHttpClientFactory`.
McpChannelFactory productionMcpChannelFactory({http.Client? httpClient}) =>
    (config) => _openProductionChannel(config, httpClient);

Future<StreamChannel<String>> _openProductionChannel(
  McpServerConfig config,
  http.Client? httpClient,
) async {
  switch (config.transport) {
    case McpTransport.stdio:
      return _openStdioChannel(config);
    case McpTransport.http:
      return _openHttpChannel(config, httpClient);
  }
}

/// Opens a Streamable-HTTP channel to the [config]'s `url` via the substrate's
/// `HttpMcpTransport`.
///
/// A missing/empty [McpServerConfig.url] is a configured-but-unreachable server
/// (an `mcp.unreachable` [McpFailure]); a `Bearer <token>` in
/// [McpServerConfig.headers] is forwarded as the transport's bearer credential.
Future<StreamChannel<String>> _openHttpChannel(
  McpServerConfig config,
  http.Client? httpClient,
) async {
  final rawUrl = config.url;
  if (rawUrl == null || rawUrl.isEmpty) {
    throw McpFailure(
      mcpUnreachableCode,
      serverId: config.id,
      message: 'http MCP server "${config.id}" has no "url"',
    );
  }
  final transport = HttpMcpTransport(
    id: config.id,
    url: Uri.parse(rawUrl),
    auth: _bearerFrom(config.headers),
    httpClient: httpClient,
  );
  return transport.connect();
}

/// Extracts a [McpBearerCredential] from an `Authorization: Bearer <token>`
/// entry in [headers] (case-insensitive header name), or `null` when none is
/// present (the endpoint is then reached anonymously).
McpBearerCredential? _bearerFrom(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() != 'authorization') continue;
    const prefix = 'Bearer ';
    if (entry.value.startsWith(prefix)) {
      return McpBearerCredential(entry.value.substring(prefix.length));
    }
  }
  return null;
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
