// Request (c) § 3.2 — `McpClient.evict(id)`, the public pool eviction the
// liveness monitor calls when a probe finds a server dead
// (`agent_sdk_provider_and_mcp_liveness.md` § 3.2).
//
// The pool already evicts a *failed connect* on its own (so the next call
// retries), but a connection that came up and later went dead stays pooled —
// a probe that fails against it would keep failing against the same stale
// connection. The monitor needs to drop it explicitly so the next 30 s tick
// reconnects. `evict(id)` closes the pooled connection (best-effort) and
// removes it; it is idempotent (a no-op for an id that was never pooled).
//
// What this suite locks:
//
//   EV-1 — evict closes the pooled connection and the next call reconnects.
//   EV-2 — evict on a never-pooled id is a no-op (does not throw).
//   EV-3 — evict swallows a close-time McpFailure (best-effort teardown).

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('f8 — McpClient.evict(id)', () {
    test('EV-1: evict closes the pooled connection and the next call reconnects',
        () async {
      final connector = _CountingConnector();
      final client = McpClient(
        <McpServerConfig>[
          const McpServerConfig(id: 'srv', transport: McpTransport.stdio),
        ],
        connector,
      );

      await client.listTools('srv'); // opens + pools connection #1
      expect(connector.connectCount, 1);
      final first = connector.connections.single;
      expect(first.closed, isFalse);

      await client.evict('srv');
      expect(first.closed, isTrue, reason: 'evict closes the pooled connection');

      await client.listTools('srv'); // must reconnect → connection #2
      expect(connector.connectCount, 2,
          reason: 'the next call reconnects after eviction');
    });

    test('EV-2: evict on a never-pooled id is a no-op', () async {
      final client = McpClient(
        <McpServerConfig>[
          const McpServerConfig(id: 'srv', transport: McpTransport.stdio),
        ],
        _CountingConnector(),
      );

      await expectLater(client.evict('srv'), completes);
      await expectLater(client.evict('never-configured'), completes);
    });

    test('EV-3: evict swallows a close-time McpFailure (best-effort)', () async {
      final connector = _CountingConnector(closeThrows: true);
      final client = McpClient(
        <McpServerConfig>[
          const McpServerConfig(id: 'srv', transport: McpTransport.stdio),
        ],
        connector,
      );

      await client.listTools('srv');
      await expectLater(client.evict('srv'), completes);
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// A connector that hands out fresh [_RecordingConnection]s and counts opens.
final class _CountingConnector implements McpConnector {
  _CountingConnector({this.closeThrows = false});

  final bool closeThrows;
  final List<_RecordingConnection> connections = <_RecordingConnection>[];
  int get connectCount => connections.length;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async {
    final connection = _RecordingConnection(closeThrows: closeThrows);
    connections.add(connection);
    return connection;
  }
}

/// A connection that records whether it was closed.
final class _RecordingConnection implements McpServerConnection {
  _RecordingConnection({this.closeThrows = false});

  final bool closeThrows;
  bool closed = false;

  @override
  Future<List<Map<String, Object?>>> listTools() async =>
      const <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      const <String, Object?>{};

  @override
  Future<void> close() async {
    closed = true;
    if (closeThrows) {
      throw const McpFailure(
        mcpUnreachableCode,
        serverId: 'srv',
        message: 'close failed',
      );
    }
  }
}
