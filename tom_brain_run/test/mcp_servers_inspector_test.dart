// The run-layer `McpServersInspector` — the concrete `TelegramMcpInspector`
// behind the edge's `/mcp_list` and `/mcp_inspect <server> [<tool>]` commands
// (requests a + b), reading over the process-spanning `McpClient`.
//
// What is proven:
//   MI-1 — `mcpList` renders every configured server with transport +
//          description; the empty registry says so.
//   MI-2 — `mcpDetail(server)` lists that server's advertised tools (fetched
//          live), and an unconfigured server name is reported, never thrown.
//   MI-3 — `mcpDetail(server, tool: …)` renders one tool's description + JSON
//          input schema, and an unknown tool on a known server is reported.
//   MI-4 — an unreachable configured server (the connector throws
//          `mcp.unreachable`) renders an explicit "is unreachable" notice
//          rather than propagating the failure (PE-6).

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        McpClient,
        McpConnector,
        McpFailure,
        McpServerConfig,
        McpServerConnection,
        McpTransport,
        mcpUnreachableCode;
import 'package:tom_brain_run/tom_brain_run.dart' show McpServersInspector;
import 'package:test/test.dart';

void main() {
  group('MI-1 mcpList renders the configured servers', () {
    test('lists each server with transport and description', () async {
      final inspector = McpServersInspector(
        client: McpClient(
          const <McpServerConfig>[
            McpServerConfig(
              id: 'files',
              transport: McpTransport.stdio,
              description: 'local filesystem tools',
            ),
            McpServerConfig(
              id: 'weather',
              transport: McpTransport.http,
              url: 'https://example.test/mcp',
            ),
          ],
          _MapConnector(const <String, McpServerConnection?>{}),
        ),
      );

      final text = await inspector.mcpList();

      expect(text, contains('MCP servers (2 servers):'));
      expect(text, contains('files (transport: stdio)'));
      expect(text, contains('local filesystem tools'));
      expect(text, contains('weather (transport: http)'));
      // A server without a description falls back to a placeholder.
      expect(text, contains('(no description)'));
    });

    test('reports the empty registry', () async {
      final inspector = McpServersInspector(
        client: McpClient(
          const <McpServerConfig>[],
          _MapConnector(const <String, McpServerConnection?>{}),
        ),
      );
      expect(await inspector.mcpList(), 'No MCP servers are configured.');
    });
  });

  group('MI-2 mcpDetail lists a server\'s advertised tools', () {
    test('renders the live tool list of a reachable server', () async {
      final inspector = _inspectorWith(
        config: const McpServerConfig(id: 'files', transport: McpTransport.stdio),
        connection: _StubConnection(tools: <Map<String, Object?>>[
          <String, Object?>{'name': 'read', 'description': 'reads a file'},
          <String, Object?>{'name': 'write', 'description': 'writes a file'},
        ]),
      );

      final text = await inspector.mcpDetail('files');

      expect(text, contains('MCP server "files" tools (2 tools):'));
      expect(text, contains('read — reads a file'));
      expect(text, contains('write — writes a file'));
    });

    test('reports an unconfigured server name', () async {
      final inspector = McpServersInspector(
        client: McpClient(
          const <McpServerConfig>[
            McpServerConfig(id: 'files', transport: McpTransport.stdio),
          ],
          _MapConnector(const <String, McpServerConnection?>{}),
        ),
      );
      expect(await inspector.mcpDetail('nope'),
          'No MCP server named "nope" is configured.');
    });
  });

  group('MI-3 mcpDetail renders one tool', () {
    test('shows the tool description and JSON input schema', () async {
      final inspector = _inspectorWith(
        config: const McpServerConfig(id: 'files', transport: McpTransport.stdio),
        connection: _StubConnection(tools: <Map<String, Object?>>[
          <String, Object?>{
            'name': 'read',
            'description': 'reads a file',
            'input_schema': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'path': <String, Object?>{'type': 'string'},
              },
            },
          },
        ]),
      );

      final text = await inspector.mcpDetail('files', tool: 'read');

      expect(text, contains('MCP tool files / read'));
      expect(text, contains('description: reads a file'));
      expect(text, contains('input schema:'));
      expect(text, contains('"path"'));
    });

    test('reports an unknown tool on a known server', () async {
      final inspector = _inspectorWith(
        config: const McpServerConfig(id: 'files', transport: McpTransport.stdio),
        connection: _StubConnection(tools: const <Map<String, Object?>>[]),
      );
      expect(await inspector.mcpDetail('files', tool: 'ghost'),
          'MCP server "files" advertises no tool named "ghost".');
    });
  });

  group('MI-4 an unreachable server renders a notice (PE-6)', () {
    test('mcpDetail returns an "is unreachable" message, not a throw', () async {
      // The connector has no connection for the configured id → it throws
      // `mcp.unreachable`, which the inspector must catch and render.
      final inspector = McpServersInspector(
        client: McpClient(
          const <McpServerConfig>[
            McpServerConfig(id: 'files', transport: McpTransport.stdio),
          ],
          _MapConnector(const <String, McpServerConnection?>{'files': null}),
        ),
      );

      final text = await inspector.mcpDetail('files');

      expect(text, contains('MCP server "files" is unreachable:'));
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// Builds an inspector over a one-server client whose [config] id resolves to
/// [connection] through the stub connector.
McpServersInspector _inspectorWith({
  required McpServerConfig config,
  required _StubConnection connection,
}) =>
    McpServersInspector(
      client: McpClient(
        <McpServerConfig>[config],
        _MapConnector(<String, McpServerConnection?>{config.id: connection}),
      ),
    );

/// A stub MCP connection: returns canned advertised tools.
final class _StubConnection implements McpServerConnection {
  _StubConnection({this.tools = const <Map<String, Object?>>[]});

  final List<Map<String, Object?>> tools;

  @override
  Future<List<Map<String, Object?>>> listTools() async => tools;

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      const <String, Object?>{};

  @override
  Future<void> close() async {}
}

/// A connector keyed by server id: a null entry simulates an unreachable
/// server (throws `mcp.unreachable`).
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
