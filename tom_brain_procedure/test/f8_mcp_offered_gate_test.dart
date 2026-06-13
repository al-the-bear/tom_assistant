// Request (c) § 3.3 — the `offered(serverId)` availability gate on
// `McpClientToolSource` (`agent_sdk_provider_and_mcp_liveness.md` § 3.3).
//
// The set of MCP servers actually offered to LLMs at any moment is
// `offered(serverId) = exposeToLlms(serverId) && monitor.isLive(serverId)`.
// `McpClientToolSource` is the seam where that gate is enforced against the
// tools layer:
//
//   * `listTools()` filters its server enumeration through `offered(...)`, so a
//     dead or non-exposed server contributes no tools to the merge.
//   * `invokeTool(...)` denies a call to a non-offered (dead / unexposed)
//     server with `ToolSurfaceUnavailable` rather than a silent wrong answer —
//     the "auto-disable on dead" half of request (c), enforced dynamically per
//     call (the boot-time merge runs `listTools()` once, so the invoke path is
//     what flips a server out of service without a restart).
//
// A `null` gate (the default) offers every configured server — preserving the
// pre-gate behaviour the existing f8 merge suite pins.
//
// What this suite locks:
//
//   OG-1 — listTools omits a server the gate rejects.
//   OG-2 — listTools includes a server the gate accepts.
//   OG-3 — invokeTool on a rejected server throws ToolSurfaceUnavailable.
//   OG-4 — invokeTool on an accepted server forwards to client.callTool.
//   OG-5 — a null gate (default) offers every server (regression guard).

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('f8 — McpClientToolSource offered() gate', () {
    McpClient twoServerClient() => McpClient(
          <McpServerConfig>[
            const McpServerConfig(id: 'open', transport: McpTransport.stdio),
            const McpServerConfig(id: 'hidden', transport: McpTransport.stdio),
          ],
          _MapConnector(<String, McpServerConnection?>{
            'open': _StubConnection(
              tools: <Map<String, Object?>>[
                <String, Object?>{'name': 'ping', 'description': 'pings'},
              ],
              callResult: const <String, Object?>{'done': true},
            ),
            'hidden': _StubConnection(
              tools: <Map<String, Object?>>[
                <String, Object?>{'name': 'secret', 'description': 'hidden'},
              ],
            ),
          }),
        );

    test('OG-1/OG-2: listTools filters server enumeration through the gate',
        () async {
      final source = McpClientToolSource(
        twoServerClient(),
        offered: (serverId) => serverId == 'open',
      );

      final defs = await source.listTools();

      expect(defs.map((d) => d.qualifiedName), <String>['mcp__open__ping'],
          reason: 'the non-offered "hidden" server contributes no tools');
    });

    test('OG-3: invokeTool on a rejected server throws ToolSurfaceUnavailable',
        () async {
      final source = McpClientToolSource(
        twoServerClient(),
        offered: (serverId) => serverId == 'open',
      );

      await expectLater(
        source.invokeTool('hidden', 'secret', const <String, Object?>{}),
        throwsA(isA<ToolSurfaceUnavailable>()
            .having((e) => e.surface, 'surface', 'mcp')
            .having((e) => e.tool, 'tool', 'mcp__hidden__secret')),
      );
    });

    test('OG-4: invokeTool on an accepted server forwards to client.callTool',
        () async {
      final source = McpClientToolSource(
        twoServerClient(),
        offered: (serverId) => serverId == 'open',
      );

      final result = await source.invokeTool(
        'open',
        'ping',
        const <String, Object?>{'n': 1},
      );

      expect(result, <String, Object?>{'done': true});
    });

    test('OG-5: a null gate (default) offers every server', () async {
      final source = McpClientToolSource(twoServerClient());

      final defs = await source.listTools();

      expect(
        defs.map((d) => d.qualifiedName).toSet(),
        <String>{'mcp__open__ping', 'mcp__hidden__secret'},
        reason: 'a null gate preserves the pre-gate offer-all behaviour',
      );
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// A stub MCP connection: returns canned tool/result data.
final class _StubConnection implements McpServerConnection {
  _StubConnection({
    this.tools = const <Map<String, Object?>>[],
    this.callResult = const <String, Object?>{},
  });

  final List<Map<String, Object?>> tools;
  final Map<String, Object?> callResult;

  @override
  Future<List<Map<String, Object?>>> listTools() async => tools;

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      callResult;

  @override
  Future<void> close() async {}
}

/// A connector keyed by server id; a null entry throws `mcp.unreachable`.
final class _MapConnector implements McpConnector {
  _MapConnector(this._byId);

  final Map<String, McpServerConnection?> _byId;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async {
    final connection = _byId[config.id];
    if (connection == null) {
      throw McpFailure(
        mcpUnreachableCode,
        serverId: config.id,
        message: 'unreachable',
      );
    }
    return connection;
  }
}
