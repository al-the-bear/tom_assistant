// Request (c) § 3.3 — the run-layer composition glue that turns the static
// `exposeToLlms` config and the dynamic `McpLivenessMonitor` into the single
// `offered = exposeToLlms && isLive` gate the procedure engine consumes, plus
// the monitor factory that binds the heartbeat's probe/evict seams to a real
// `McpClient` (`agent_sdk_provider_and_mcp_liveness.md` § 3.2 / § 3.3).
//
// These two helpers are the only place the run layer joins the procedure
// package's `McpServersConfig` / `McpClient` to the run package's monitor.
// Keeping them as pure functions (rather than inline in the provisioner) lets
// this suite lock the join without standing a whole brain up.
//
// What this suite locks:
//
//   OW-1 — mcpOfferedGate: an exposed + live server is offered.
//   OW-2 — mcpOfferedGate: an exposed but dead server is NOT offered.
//   OW-3 — mcpOfferedGate: a configured-but-unexposed server is NOT offered.
//   OW-4 — mcpOfferedGate: an unconfigured id is NOT offered.
//   OW-5 — mcpLivenessMonitorOverClient: probe binds to client.listTools (a
//          reachable server is marked live) and evict binds to client.evict (a
//          server whose listTools fails is marked dead and its pool dropped).

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        McpClient,
        McpConnector,
        McpFailure,
        McpServerConfig,
        McpServerConnection,
        McpServersConfig,
        McpTransport,
        mcpCallFailedCode;
import 'package:tom_brain_run/tom_brain_run.dart'
    show
        McpLivenessMonitor,
        mcpLivenessMonitorOverClient,
        mcpOfferedGate;

void main() {
  group('r40 — mcpOfferedGate', () {
    // Two configured servers: 'open' is exposed, 'hidden' is not.
    final config = McpServersConfig(<McpServerConfig>[
      const McpServerConfig(
        id: 'open',
        transport: McpTransport.stdio,
        exposeToLlms: true,
      ),
      const McpServerConfig(
        id: 'hidden',
        transport: McpTransport.stdio,
        exposeToLlms: false,
      ),
    ]);

    test('OW-1: an exposed + live server is offered', () {
      final monitor = _monitorOver(<String>['open', 'hidden']);
      final offered = mcpOfferedGate(config, monitor);

      // Both start optimistically live; 'open' is exposed.
      expect(offered('open'), isTrue);
    });

    test('OW-2: an exposed but dead server is NOT offered', () async {
      var fail = false;
      final monitor = McpLivenessMonitor(
        serverIds: const <String>['open'],
        probe: (_) async {
          if (fail) throw StateError('down');
        },
        evict: (_) async {},
      );
      final offered = mcpOfferedGate(config, monitor);

      fail = true;
      await monitor.probeOnce(); // 'open' → dead
      expect(offered('open'), isFalse,
          reason: 'exposed but not live → not offered');
    });

    test('OW-3: a configured-but-unexposed server is NOT offered', () {
      final monitor = _monitorOver(<String>['open', 'hidden']);
      final offered = mcpOfferedGate(config, monitor);

      // 'hidden' is live (optimistic) but exposeToLlms is false.
      expect(offered('hidden'), isFalse);
    });

    test('OW-4: an unconfigured id is NOT offered', () {
      final monitor = _monitorOver(<String>['open']);
      final offered = mcpOfferedGate(config, monitor);

      expect(offered('ghost'), isFalse);
    });
  });

  group('r40 — mcpLivenessMonitorOverClient', () {
    test('OW-5: probe binds to listTools and evict binds to client.evict',
        () async {
      final connector = _CountingConnector();
      final config = McpServersConfig(<McpServerConfig>[
        const McpServerConfig(id: 'srv', transport: McpTransport.stdio),
      ]);
      final client = McpClient(config, connector);
      final monitor = mcpLivenessMonitorOverClient(client, config);

      // Reachable server → listTools succeeds → marked live.
      await monitor.probeOnce();
      expect(monitor.isLive('srv'), isTrue);
      expect(connector.connectCount, 1);

      // Now make listTools fail: the next probe marks the server dead AND
      // evicts the pooled connection (so a later call reconnects).
      connector.connections.single.listToolsThrows = true;
      await monitor.probeOnce();
      expect(monitor.isLive('srv'), isFalse,
          reason: 'a failing listTools marks the server dead');

      // Evict dropped the pool: the next listTools reconnects (connect #2).
      connector.connections.single.listToolsThrows = false;
      await client.listTools('srv');
      expect(connector.connectCount, 2,
          reason: 'evict bound to client.evict dropped the dead connection');
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// A monitor over [ids] with no-op seams — every id starts optimistically live.
McpLivenessMonitor _monitorOver(List<String> ids) => McpLivenessMonitor(
      serverIds: ids,
      probe: (_) async {},
      evict: (_) async {},
    );

/// A connector that hands out fresh [_RecordingConnection]s and counts opens.
final class _CountingConnector implements McpConnector {
  final List<_RecordingConnection> connections = <_RecordingConnection>[];
  int get connectCount => connections.length;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async {
    final connection = _RecordingConnection();
    connections.add(connection);
    return connection;
  }
}

/// A connection whose [listTools] can be flipped to fail.
final class _RecordingConnection implements McpServerConnection {
  bool listToolsThrows = false;

  @override
  Future<List<Map<String, Object?>>> listTools() async {
    if (listToolsThrows) {
      throw const McpFailure(
        mcpCallFailedCode,
        serverId: 'srv',
        message: 'listTools failed',
      );
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      const <String, Object?>{};

  @override
  Future<void> close() async {}
}
