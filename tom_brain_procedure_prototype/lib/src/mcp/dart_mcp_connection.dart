// DartMcpConnection + DartMcpConnector — the concrete `dart_mcp` adapter for
// the MCP client (Extension F step 8;
// `tom_brain_procedure_prototype_specification.md` § 21.3;
// `tom_brain_mcp_server_reference.md`).
//
// This is the *only* file in `lib/src/mcp/` that holds `dart_mcp` types. It
// adapts a `dart_mcp` `ServerConnection` to the client's transport-neutral
// [McpServerConnection] contract, and adapts channel-opening to the
// [McpConnector] contract. Keeping `dart_mcp` confined here means the client
// (`mcp_client.dart`) and the bridge (`mcp_bridge.dart`) carry no wire types,
// and a test substitutes a stub without touching `dart_mcp` at all (PE-1,
// PE-10).
//
// The channel is supplied by a [McpChannelFactory] rather than opened here:
// the same seam the host's installer pattern uses keeps OS I/O (a child
// process, an HTTP socket) at the composition root, out of this adapter. The
// integration test hands a factory that returns an in-memory channel wired to
// a real `TomBrainMemoryMcpServer`; a production assembly hands one that
// spawns a process or opens an HTTP transport.

library;

import 'package:dart_mcp/client.dart';
import 'package:stream_channel/stream_channel.dart';

import 'mcp_client.dart';
import 'mcp_server_config.dart';

/// Opens a `StreamChannel<String>` to the MCP server described by [config].
///
/// The transport seam: a stdio factory spawns `config.command` + `config.args`
/// and wraps its stdio; an HTTP factory opens a Streamable-HTTP transport to
/// `config.url`. A connect-time I/O error propagates and is wrapped by
/// [DartMcpConnector.connect] as an `mcp.unreachable` [McpFailure].
typedef McpChannelFactory = Future<StreamChannel<String>> Function(
  McpServerConfig config,
);

/// A `dart_mcp`-backed [McpServerConnection].
///
/// Wraps an initialized `ServerConnection` and translates its tool surface
/// into the plain-map shapes the client expects. Wire errors surface as
/// [McpFailure] (`mcp.call.failed`).
final class DartMcpConnection implements McpServerConnection {
  DartMcpConnection._(this._serverId, this._client, this._connection);

  final String _serverId;
  final MCPClient _client;
  final ServerConnection _connection;

  /// Opens and initializes a connection over [channel] for server [serverId].
  ///
  /// Performs the MCP handshake (`initialize` + `notifyInitialized`). A
  /// handshake failure throws [McpFailure] (`mcp.unreachable`).
  static Future<DartMcpConnection> connect(
    String serverId,
    StreamChannel<String> channel, {
    String clientName = 'tom-brain-procedure',
    String clientVersion = '0.0.1',
  }) async {
    final client = MCPClient(
      Implementation(name: clientName, version: clientVersion),
    );
    final connection = client.connectServer(channel);
    try {
      await connection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: ClientCapabilities(),
          clientInfo: Implementation(name: clientName, version: clientVersion),
        ),
      );
      connection.notifyInitialized();
    } catch (error) {
      await client.shutdown();
      throw McpFailure(
        mcpUnreachableCode,
        serverId: serverId,
        message: 'MCP handshake with "$serverId" failed',
        cause: error,
      );
    }
    return DartMcpConnection._(serverId, client, connection);
  }

  @override
  Future<List<Map<String, Object?>>> listTools() async {
    try {
      final result = await _connection.listTools();
      return <Map<String, Object?>>[
        for (final tool in result.tools)
          <String, Object?>{
            'name': tool.name,
            'description': tool.description,
            'input_schema': _plainMap(tool.inputSchema),
          },
      ];
    } on McpFailure {
      rethrow;
    } catch (error) {
      throw McpFailure(
        mcpCallFailedCode,
        serverId: _serverId,
        message: 'listing tools on "$_serverId" failed',
        cause: error,
      );
    }
  }

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    final CallToolResult result;
    try {
      result = await _connection.callTool(
        CallToolRequest(name: name, arguments: args),
      );
    } on McpFailure {
      rethrow;
    } catch (error) {
      throw McpFailure(
        mcpCallFailedCode,
        serverId: _serverId,
        message: 'tool call "$name" on "$_serverId" failed',
        cause: error,
      );
    }

    if (result.isError ?? false) {
      throw McpFailure(
        mcpCallFailedCode,
        serverId: _serverId,
        message: 'tool "$name" reported an error',
        cause: _textOf(result.content),
      );
    }

    final structured = result.structuredContent;
    if (structured != null) {
      return Map<String, Object?>.from(structured);
    }
    return <String, Object?>{
      'content': <Object?>[for (final item in result.content) _plainMap(item)],
    };
  }

  @override
  Future<void> close() => _client.shutdown();

  /// Joins the text parts of a content list (for error messages).
  static String _textOf(List<Content> content) {
    final buffer = StringBuffer();
    for (final item in content) {
      if (item.isText) buffer.write((item as TextContent).text);
    }
    return buffer.toString();
  }

  /// Converts a `dart_mcp` extension-type value (an `ObjectSchema`, a
  /// `Content`, …) into a plain `Map<String, Object?>`. These wire types are
  /// extension types over `Map<String, Object?>` that do not declare `Object`
  /// as a supertype, so the parameter is `dynamic`: at runtime each value
  /// erases to its underlying map, and `as Map` recovers it without leaking
  /// the wire type into our surface.
  static Map<String, Object?> _plainMap(dynamic value) =>
      Map<String, Object?>.from(value as Map);
}

/// A `dart_mcp`-backed [McpConnector].
///
/// Opens a channel via the injected [channelFactory] and runs the handshake.
/// A failure to open the channel or complete the handshake surfaces as
/// [McpFailure] (`mcp.unreachable`).
final class DartMcpConnector implements McpConnector {
  /// Builds a connector over a [channelFactory] that opens the transport.
  const DartMcpConnector({required this.channelFactory});

  /// Opens the `StreamChannel<String>` for a given server config.
  final McpChannelFactory channelFactory;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async {
    final StreamChannel<String> channel;
    try {
      channel = await channelFactory(config);
    } on McpFailure {
      rethrow;
    } catch (error) {
      throw McpFailure(
        mcpUnreachableCode,
        serverId: config.id,
        message: 'opening a channel to "${config.id}" failed',
        cause: error,
      );
    }
    return DartMcpConnection.connect(config.id, channel);
  }
}
