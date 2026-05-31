// A.75 — MCP server skeleton conformance tests.
//
// What this file locks:
//
//   1. The server class constructs over a `StreamChannel<String>`
//      without throwing.
//   2. After the `initialize` handshake, `serverInfo` carries the
//      Tom Brain memory identity (name + version) the spec § 3.2
//      identifies the server by.
//   3. Capability advertisement includes a `tools` capability (with
//      `listChanged: true`, courtesy of `ToolsSupport`), even though
//      A.75 registers no tools — clients should see the surface as
//      "tools-capable, currently empty" rather than "tools-not-
//      supported".
//   4. The instructions string mentions the read-only contract and
//      the seven tool names — so the spec § 3.2 contract is part of
//      the protocol-visible surface, not just a code comment.
//   5. `listTools` returns an empty list at A.75 (tools land in
//      A.77 – A.79; the skeleton must not pretend to register any).
//   6. `callTool` against an unregistered tool name returns a
//      `CallToolResult(isError: true, …)` — the `ToolsSupport` mixin
//      handles this for us; the test pins the behaviour so an A.77
//      regression that silently swallows unknown calls would surface
//      here.
//   7. The `socketChannel` transport adapter round-trips JSON-RPC
//      frames through a real socket pair (loopback TCP — the
//      adapter does not care whether the underlying socket is UNIX
//      or TCP, and TCP is portable across CI environments).
//   8. The `stdioChannel` re-export from `mcp_transports.dart` is
//      reachable through the package barrel — proves the export
//      chain is wired.
//
// What this file does NOT lock:
//
//   - Bearer-token authentication (A.76).
//   - Per-tool schemas or behaviour (A.77 – A.79).
//   - UNIX-domain socket binding semantics — see the deployment
//     example in `mcp_transports.dart` for how a caller wires
//     `ServerSocket.bind(InternetAddress.unix, …)` to
//     `socketChannel`. The adapter behaves identically for UNIX and
//     TCP sockets because `dart:io`'s `Socket` is the common type.
//
// Test driving pattern: the in-memory `StreamController<String>`
// pair (mirrors the `TestEnvironment` helper inside dart_mcp's own
// tests) lets us run an MCPClient and the server in the same isolate
// without spawning a subprocess. The pattern is the workspace's
// standard MCP-server testing shape and is explicitly endorsed by
// the upstream test_utils.dart in `package:dart_mcp`.

import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('A.75 MCP server skeleton', () {
    test('constructs over an in-memory StreamChannel without throwing', () {
      final env = _TestEnv();
      addTearDown(env.shutdown);

      // Constructing must not throw; the `initialized` future is in
      // pending state until the client side initialises.
      expect(env.server, isA<TomBrainMemoryMcpServer>());
      expect(env.server.ready, isFalse);
    });

    test('serverInfo carries the tom_brain_memory identity', () async {
      final env = _TestEnv();
      addTearDown(env.shutdown);

      final result = await env.initializeHandshake();
      expect(result.serverInfo.name, equals('tom_brain_memory'));
      expect(result.serverInfo.version, equals('0.0.1'));
      expect(
        TomBrainMemoryMcpServer.serverName,
        equals('tom_brain_memory'),
        reason: 'constant must match the advertised name',
      );
      expect(
        TomBrainMemoryMcpServer.serverVersion,
        equals('0.0.1'),
        reason: 'constant must match the advertised version',
      );
    });

    test('initialize advertises a tools capability (currently empty)', () async {
      final env = _TestEnv();
      addTearDown(env.shutdown);

      final result = await env.initializeHandshake();

      // ToolsSupport sets `tools.listChanged = true` during initialize,
      // even when no tools are registered. Clients should see the
      // surface as tools-capable.
      expect(
        result.capabilities.tools,
        equals(mcp_server.Tools(listChanged: true)),
      );

      final list = await env.serverConnection.listTools();
      expect(
        list.tools,
        isEmpty,
        reason: 'A.75 skeleton registers no tools; A.77 - A.79 add the seven.',
      );
    });

    test('instructions encode the read-only contract and the seven tools', () async {
      final env = _TestEnv();
      addTearDown(env.shutdown);

      final result = await env.initializeHandshake();
      final instructions = result.instructions ?? '';

      expect(instructions, contains('read-only'));
      expect(instructions, contains('memory.persistNote'));
      expect(instructions, contains('memory.recall'));
      expect(instructions, contains('memory.get'));
      expect(instructions, contains('memory.edgesOf'));
      expect(instructions, contains('memory.stack.list'));
      expect(instructions, contains('memory.stack.peek'));
      expect(instructions, contains('memory.classify'));
      // Spec invariants mentioned by section reference.
      expect(instructions, contains('Section 1.2'));
      expect(instructions, contains('Section 1.7'));
      expect(instructions, contains('Section 3.2'));
    });

    test(
      'callTool with an unregistered name returns isError, not a crash',
      () async {
        final env = _TestEnv();
        addTearDown(env.shutdown);

        await env.initializeHandshake();

        final result = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(name: 'memory.recall'),
        );

        expect(
          result.isError,
          isTrue,
          reason:
              'No tool is registered at A.75; ToolsSupport returns isError, '
              'not an RPC failure.',
        );
        expect(result.content, isNotEmpty);
        expect(result.content.first, isA<mcp_server.TextContent>());
        final text = (result.content.first as mcp_server.TextContent).text;
        expect(text, contains('memory.recall'));
      },
    );

    test('server completes its initialized future after the handshake', () async {
      final env = _TestEnv();
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      // ToolsSupport / MCPServer mark `ready` once the client has sent
      // the `initialized` notification.
      expect(env.server.ready, isTrue);
    });
  });

  group('A.75 transports', () {
    test('stdioChannel is reachable through the package barrel', () {
      // Identifier-existence check; constructing one would consume the
      // process's real stdio.
      expect(stdioChannel, isNotNull);
    });

    test('socketChannel round-trips line-delimited UTF-8 frames', () async {
      // Loopback TCP pair stands in for any `Socket`-typed transport
      // (the adapter does not depend on socket family). UNIX-domain
      // socket binding semantics are a deployment concern and are
      // covered by the deployment example in `mcp_transports.dart`.
      final listener = await io.ServerSocket.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listener.close);

      final acceptedFuture = listener.first;
      final clientSocket = await io.Socket.connect(
        io.InternetAddress.loopbackIPv4,
        listener.port,
      );
      final serverSocket = await acceptedFuture;

      final clientChannel = socketChannel(clientSocket);
      final serverChannel = socketChannel(serverSocket);

      final received = <String>[];
      final sub = serverChannel.stream.listen(received.add);

      clientChannel.sink.add('hello');
      clientChannel.sink.add('world');
      // Give the event loop a chance to flush both lines.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await sub.cancel();
      await clientChannel.sink.close();
      await serverChannel.sink.close();
      await clientSocket.close();
      await serverSocket.close();

      expect(received, equals(['hello', 'world']));
    });
  });
}

/// A minimal in-isolate test environment mirroring `dart_mcp`'s own
/// `TestEnvironment` helper (`package:dart_mcp/test/test_utils.dart`).
///
/// The two `StreamController<String>` instances form a single in-memory
/// duplex channel: writes to the client side appear on the server side
/// and vice versa. This lets us run the real server class against a
/// real client connection without spawning a subprocess.
class _TestEnv {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  late final StreamChannel<String> clientChannel;
  late final StreamChannel<String> serverChannel;
  late final mcp_client.MCPClient client;
  late final TomBrainMemoryMcpServer server;
  late final mcp_client.ServerConnection serverConnection;

  _TestEnv() {
    // Both channels share the same underlying controllers — client
    // writes appear on the server side and vice versa.
    clientChannel = StreamChannel<String>.withCloseGuarantee(
      serverController.stream,
      clientController.sink,
    );
    serverChannel = StreamChannel<String>.withCloseGuarantee(
      clientController.stream,
      serverController.sink,
    );
    client = _TestMcpClient();
    // Order matters: the server has to be listening before the client
    // tries to send `initialize`. The dart_mcp TestEnvironment uses
    // exactly this construction order.
    server = TomBrainMemoryMcpServer(serverChannel);
    serverConnection = client.connectServer(clientChannel);
  }

  Future<mcp_server.InitializeResult> initializeHandshake({
    mcp_server.ProtocolVersion protocolVersion =
        mcp_server.ProtocolVersion.latestSupported,
  }) async {
    final result = await serverConnection.initialize(
      mcp_server.InitializeRequest(
        protocolVersion: protocolVersion,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    if (result.protocolVersion?.isSupported == true) {
      serverConnection.notifyInitialized(mcp_server.InitializedNotification());
      await server.initialized;
    }
    return result;
  }

  Future<void> shutdown() async {
    await client.shutdown();
    await server.shutdown();
  }
}

base class _TestMcpClient extends mcp_client.MCPClient {
  _TestMcpClient()
    : super(
        mcp_client.Implementation(name: 'a75-test-client', version: '0.0.1'),
      );
}
