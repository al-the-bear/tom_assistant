// B.8 — `McpClient` + `McpSession`.
//
// Plan steps:
//   - B.33 Implement `McpClient` on `dart_mcp` for outbound MCP calls.
//   - B.34 Implement bearer-token auth plumbing (HTTP only — policy
//          override 2 on `prototype_implementation_plan.md`).
//   - B.35 Tests: tool discovery; tool-call roundtrip; auth failure
//          surfaces as typed error.
//
// What this file owns:
//
//   - The substrate-facing surface for outbound MCP calls. Procedures
//     never touch `dart_mcp` directly; they go through `McpSession`.
//     This keeps the dependency on dart_mcp inside one cohesive
//     boundary so a later library swap (Q-B.8.1) does not ripple
//     into the rest of substrate.
//   - Auth failure → typed error race. `McpClient.connect` awaits
//     `Future.any([transport.done, handshake.complete])`. If the
//     transport's `done` future completes first with an error (the
//     HTTP transport's auth-rejection path), that typed error wins
//     and `McpClient.connect` re-throws it. The dart_mcp `MCPClient`
//     is shut down behind the scenes so we don't leak the
//     connection.
//
// What this file deliberately does NOT own:
//
//   - Retry / cooldown logic. That lives one layer up (the router
//     and, eventually, the dispatcher).
//   - Tool catalogue caching. Substrate Spec § 10.3 wants per-call
//     telemetry; caching would obscure the per-call surface and the
//     prototype set is small enough that the round-trip is cheap.
//   - The Streamable HTTP GET / SSE half. See `http_transport.dart`
//     for the scope cut.

import 'dart:async';

import 'package:dart_mcp/client.dart' as mcp;
import 'package:dart_mcp/server.dart' as mcp_proto;

import 'mcp_errors.dart';
import 'mcp_transport.dart';

/// Identity advertised by this MCP client during the `initialize`
/// handshake. Carried in `clientInfo.name` / `clientInfo.version`.
final class McpClientIdentity {
  final String name;
  final String version;

  /// Optional human-readable title surfaced to the server's logs.
  final String? title;

  const McpClientIdentity({
    required this.name,
    required this.version,
    this.title,
  });
}

/// Public, library-agnostic description of a tool the server
/// advertises. Hides the dart_mcp `Tool` extension-type so callers
/// can pattern-match on plain fields without binding to the
/// upstream library.
final class McpToolInfo {
  final String name;
  final String? description;

  /// Raw JSON-schema-shaped input schema. Left as `Map<String,
  /// Object?>` because the prototype's procedures consume it via the
  /// procedure dispatcher's schema validation, not via type-safe
  /// Dart wrappers.
  final Map<String, Object?> inputSchema;

  const McpToolInfo({
    required this.name,
    this.description,
    required this.inputSchema,
  });
}

/// Result of an [McpSession.callTool] invocation.
///
/// Carries the structured content blocks returned by the MCP server.
/// Each block is a `Map<String, Object?>` matching the MCP
/// `ContentBlock` shape from the spec (`type: "text" | "image" |
/// ...` + per-type fields).
final class McpToolResult {
  /// Whether the server flagged the call as an error (the MCP
  /// `isError: true` shape). Substrate consumers treat this as a
  /// caller-recoverable failure (the tool itself reports it); the
  /// transport / handshake errors still raise [McpClientException].
  final bool isError;

  /// Raw content blocks (each block is a Map matching MCP's
  /// `ContentBlock` shape).
  final List<Map<String, Object?>> content;

  /// Optional structured-content payload (MCP `structuredContent`).
  final Map<String, Object?>? structuredContent;

  const McpToolResult({
    required this.isError,
    required this.content,
    this.structuredContent,
  });
}

/// Outbound MCP client.
///
/// Lifecycle:
///
/// ```dart
/// final client = McpClient(
///   identity: const McpClientIdentity(name: 'tom_brain_substrate', version: '0.0.1'),
/// );
/// final session = await client.connect(transport);
/// final tools = await session.listTools();
/// final result = await session.callTool('memory.recall', {'q': 'cats'});
/// await session.close();
/// await client.close();
/// ```
///
/// A single [McpClient] may hold any number of concurrent
/// [McpSession]s (one per [McpTransport]).
final class McpClient {
  final McpClientIdentity identity;
  final mcp.MCPClient _mcp;
  final _sessions = <McpSession>{};
  bool _closed = false;

  McpClient({required this.identity})
      : _mcp = mcp.MCPClient(mcp.Implementation(
          name: identity.name,
          version: identity.version,
          title: identity.title,
        ));

  /// Connects through [transport] and completes the MCP `initialize`
  /// handshake.
  ///
  /// Throws an [McpClientException] subtype on failure:
  ///   - [McpAuthFailed] when the HTTP transport observes 401 / 403.
  ///   - [McpTransportUnreachable] when the transport cannot be
  ///     established or the connection drops before initialize.
  ///   - [McpHandshakeFailed] when the server replies with an
  ///     unsupported protocol version or any other initialize
  ///     malformation.
  Future<McpSession> connect(McpTransport transport) async {
    if (_closed) {
      throw StateError(
        'McpClient(${identity.name}) is closed; '
        'create a new client to connect again.',
      );
    }

    final channel = await transport.connect();

    final connection = _mcp.connectServer(channel);

    // Race the handshake against transport-level failures so a
    // mid-handshake auth rejection surfaces as the typed error
    // rather than as a generic dart_mcp StateError.
    late mcp_proto.InitializeResult initResult;
    try {
      initResult = await Future.any(<Future<mcp_proto.InitializeResult>>[
        connection.initialize(
          mcp_proto.InitializeRequest(
            protocolVersion: mcp_proto.ProtocolVersion.latestSupported,
            capabilities: mcp_proto.ClientCapabilities(),
            clientInfo: mcp_proto.Implementation(
              name: identity.name,
              version: identity.version,
              title: identity.title,
            ),
          ),
        ),
        transport.done.then((_) {
          // Transport completed normally before handshake — surface
          // as unreachable (the server closed the channel).
          throw McpTransportUnreachable(
            transport.id,
            'Transport closed before MCP `initialize` completed.',
          );
        }),
      ]);
    } on McpClientException {
      // Already typed — clean up and rethrow.
      unawaited(connection.shutdown());
      unawaited(transport.close());
      rethrow;
    } on Object catch (error) {
      // dart_mcp produces StateError when the channel closes
      // prematurely. We have to figure out whether it was an auth
      // rejection (HTTP transport's done future will hold the typed
      // error) or a generic handshake malformation.
      unawaited(connection.shutdown());
      try {
        // Give the transport.done future a microtask to settle.
        await transport.done.timeout(const Duration(milliseconds: 50));
      } on McpClientException {
        unawaited(transport.close());
        rethrow;
      } on TimeoutException {
        // No typed error from the transport — fall through.
      } on Object {
        // Some other error from done — fall through.
      }
      unawaited(transport.close());
      throw McpHandshakeFailed(
        transport.id,
        'MCP `initialize` failed: $error',
      );
    }

    final protocolVersion = initResult.protocolVersion;
    if (protocolVersion == null || !protocolVersion.isSupported) {
      unawaited(connection.shutdown());
      unawaited(transport.close());
      throw McpHandshakeFailed(
        transport.id,
        'Server advertised unsupported protocol version '
        '(${protocolVersion?.versionString ?? "<null>"}).',
      );
    }

    connection.notifyInitialized();

    final session = McpSession._(
      transport: transport,
      connection: connection,
      serverInfo: initResult.serverInfo,
      protocolVersion: protocolVersion,
      onClose: _sessions.remove,
    );
    _sessions.add(session);
    return session;
  }

  /// Closes all open sessions and the underlying dart_mcp client.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final sessions = _sessions.toList(growable: false);
    _sessions.clear();
    for (final session in sessions) {
      try {
        await session.close();
      } catch (_) {/* best effort */}
    }
    await _mcp.shutdown();
  }
}

/// A single open MCP session backed by an [McpTransport] and a
/// dart_mcp [mcp.ServerConnection].
final class McpSession {
  final McpTransport _transport;
  final mcp.ServerConnection _connection;
  final void Function(McpSession) _onClose;

  /// Server identity as returned by the `initialize` handshake.
  final mcp_proto.Implementation serverInfo;

  /// Negotiated MCP protocol version.
  final mcp_proto.ProtocolVersion protocolVersion;

  bool _closed = false;

  McpSession._({
    required McpTransport transport,
    required mcp.ServerConnection connection,
    required this.serverInfo,
    required this.protocolVersion,
    required void Function(McpSession) onClose,
  })  : _transport = transport,
        _connection = connection,
        _onClose = onClose;

  /// The endpoint id (transport-level) — useful for telemetry.
  String get endpointId => _transport.id;

  /// Returns the catalogue of tools the server advertises.
  ///
  /// Each call performs a fresh `tools/list` request; the substrate
  /// does not cache. Failure surfaces as [McpTransportUnreachable]
  /// when the underlying transport drops mid-call, otherwise as the
  /// raw dart_mcp / json_rpc_2 exception so caller-level critique
  /// paths can inspect the JSON-RPC error code.
  Future<List<McpToolInfo>> listTools() async {
    _assertOpen();
    final result = await _connection.listTools();
    return [
      for (final tool in result.tools)
        McpToolInfo(
          name: tool.name,
          description: tool.description,
          inputSchema:
              Map<String, Object?>.from(tool.inputSchema as Map),
        ),
    ];
  }

  /// Invokes [toolName] with [arguments].
  ///
  /// Arguments are passed through verbatim — the substrate does not
  /// validate against the tool's input schema (that is the caller's
  /// responsibility, and / or the dispatcher's). Tool-reported errors
  /// (MCP `isError: true`) are returned in [McpToolResult.isError];
  /// transport / handshake errors continue to throw.
  Future<McpToolResult> callTool(
    String toolName,
    Map<String, Object?> arguments,
  ) async {
    _assertOpen();
    final result = await _connection.callTool(
      mcp_proto.CallToolRequest(name: toolName, arguments: arguments),
    );
    return McpToolResult(
      isError: result.isError ?? false,
      content: [
        for (final block in result.content)
          Map<String, Object?>.from(block as Map),
      ],
      structuredContent: result.structuredContent == null
          ? null
          : Map<String, Object?>.from(result.structuredContent as Map),
    );
  }

  /// Closes this session and tears down the underlying transport.
  /// Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _connection.shutdown();
    } catch (_) {/* best effort */}
    try {
      await _transport.close();
    } catch (_) {/* best effort */}
    _onClose(this);
  }

  void _assertOpen() {
    if (_closed) {
      throw StateError(
        'McpSession(${_transport.id}) is closed.',
      );
    }
  }
}
