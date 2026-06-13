// Request (f) — merging an external MCP server's tools into the procedure tool
// loop (`tom_brain_procedure_specification.md` § 21.3, § 21.8).
//
// An operator can configure outbound MCP servers (`mcpServers:`); their
// advertised tools must become first-class entries in the `tool.*` surface the
// scripted LLM loop (`tool_loop_v1`) runs on, indistinguishable from a built-in
// tool. This mirrors the VS Code merge (f11): a narrow `McpToolSource` port the
// tools layer declares, an `McpBrainTool` wrapper (group `mcp`, qualified name
// `mcp__<server>__<tool>`), and a `mergeMcpTools` boot-time registration. A
// merged tool routes its effect through the run's optional `ToolContext.mcp`
// surface (PE-1) — it captures no live capability of its own.
//
// What this suite locks:
//
//   MM-1 — `mergeMcpTools(enabled: true)` registers each source tool as an
//          `mcp`-group `BrainTool` named `mcp__<server>__<tool>`; both appear
//          in `tool.list`.
//   MM-2 — a merged tool is callable via `tool.invoke`, routing through the
//          run's `McpToolSource` (the stub records the call).
//   MM-3 — `enabled: false` merges nothing.
//   MM-4 — an `mcp__*` tool invoked with no `ToolContext.mcp` surface raises
//          `ToolSurfaceUnavailable` (PE-1 wiring guard).
//   MM-5 — `McpClientToolSource` projects an `McpClient`'s servers + advertised
//          tools onto the port, and a configured-but-unreachable server is
//          omitted from the merge rather than aborting it (PE-6).
//   MM-6 — `McpClientToolSource.invokeTool` forwards to `client.callTool`.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemoryClient;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('MM-1 merge registers MCP tools as mcp-group BrainTools', () {
    test('both source tools appear in tool.list with group "mcp"', () async {
      final source = _StubMcpToolSource(<McpToolDefinition>[
        _def('files', 'read'),
        _def('files', 'write'),
      ]);
      final bridge = await _mergedBridge(source: source, enabled: true);

      final byName = <String, Map<String, Object?>>{
        for (final t in await bridge.list()) t['name'] as String: t,
      };

      expect(
        byName.keys,
        containsAll(<String>['mcp__files__read', 'mcp__files__write']),
      );
      expect(byName['mcp__files__read']!['group'], 'mcp');
      expect(byName['mcp__files__write']!['group'], 'mcp');
      expect(
        byName['mcp__files__read']!['input_schema'],
        isA<Map<String, Object?>>(),
      );
    });
  });

  group('MM-2 a merged tool is callable through tool.invoke', () {
    test('invoke routes through the run McpToolSource', () async {
      final source = _StubMcpToolSource(<McpToolDefinition>[
        _def('files', 'read'),
      ]);
      final bridge = await _mergedBridge(source: source, enabled: true);

      final result = await bridge.invoke(
        'mcp__files__read',
        <String, Object?>{'path': '/x'},
      );

      expect(result['ok'], isTrue);
      expect(result['result'], <String, Object?>{'echo': 'files/read'});
      // A record carrying a Map compares the Map by identity, so unpack the
      // single invocation and assert its fields individually.
      final (server, tool, args) = source.invocations.single;
      expect(server, 'files');
      expect(tool, 'read');
      expect(args, <String, Object?>{'path': '/x'},
          reason: 'the tool routed its effect through the mcp surface');
    });
  });

  group('MM-3 profile-off merges nothing', () {
    test('enabled: false leaves the registry empty', () async {
      final source = _StubMcpToolSource(<McpToolDefinition>[
        _def('files', 'read'),
      ]);
      final bridge = await _mergedBridge(source: source, enabled: false);

      expect(await bridge.list(), isEmpty);
    });
  });

  group('MM-4 an mcp tool needs the mcp surface', () {
    test('invoke with no ToolContext.mcp raises ToolSurfaceUnavailable',
        () async {
      final source = _StubMcpToolSource(<McpToolDefinition>[
        _def('files', 'read'),
      ]);
      final registry = ToolRegistry();
      await mergeMcpTools(registry, source, enabled: true);
      // Build the bridge's context WITHOUT an mcp surface — the guard must fire.
      final bridge = ToolBridge(
        registry,
        const ToolPolicy(ToolPolicyProfile.all),
        ToolContext(
          budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
          memory: _StubMemoryClient(),
          fileScope:
              FileScope.fromPriorityList(const <String>['/tom-brain-engine']),
        ),
      );

      await expectLater(
        bridge.invoke('mcp__files__read', <String, Object?>{'path': '/x'}),
        throwsA(isA<ToolSurfaceUnavailable>()),
      );
    });
  });

  group('MM-5 McpClientToolSource projects the client, omitting dead servers',
      () {
    test('reachable server tools are listed; unreachable one is skipped',
        () async {
      final client = McpClient(
        <McpServerConfig>[
          const McpServerConfig(id: 'up', transport: McpTransport.stdio),
          const McpServerConfig(id: 'down', transport: McpTransport.stdio),
        ],
        _MapConnector(<String, McpServerConnection?>{
          'up': _StubConnection(tools: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'ping',
              'description': 'pings',
              'input_schema': <String, Object?>{'type': 'object'},
            },
          ]),
          // A null connection => the connector throws `mcp.unreachable`.
          'down': null,
        }),
      );

      final defs = await McpClientToolSource(client).listTools();

      expect(defs.map((d) => d.qualifiedName), <String>['mcp__up__ping'],
          reason: 'the unreachable "down" server is omitted (PE-6)');
      expect(defs.single.description, 'pings');
    });
  });

  group('MM-6 McpClientToolSource forwards invokeTool to the client', () {
    test('invokeTool calls client.callTool with the same arguments', () async {
      final connection = _StubConnection(
        tools: const <Map<String, Object?>>[],
        callResult: const <String, Object?>{'done': true},
      );
      final client = McpClient(
        <McpServerConfig>[
          const McpServerConfig(id: 'up', transport: McpTransport.stdio),
        ],
        _MapConnector(<String, McpServerConnection?>{'up': connection}),
      );

      final result = await McpClientToolSource(client)
          .invokeTool('up', 'ping', <String, Object?>{'n': 1});

      expect(result, <String, Object?>{'done': true});
      expect(connection.lastCallName, 'ping');
      expect(connection.lastCallArgs, <String, Object?>{'n': 1});
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// An `McpToolDefinition` with a one-string-arg schema for [server]/[tool].
McpToolDefinition _def(String server, String tool) => McpToolDefinition(
      server: server,
      tool: tool,
      description: 'MCP tool $server/$tool',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{'type': 'string'},
        },
      },
    );

/// Builds a [ToolBridge] over a registry seeded by merging [source] (gated by
/// [enabled]), with a [ToolContext] carrying [source] as its `mcp` surface.
Future<ToolBridge> _mergedBridge({
  required McpToolSource source,
  required bool enabled,
}) async {
  final registry = ToolRegistry();
  await mergeMcpTools(registry, source, enabled: enabled);
  final context = ToolContext(
    budget: BudgetLedger(ProcedureBudget(const <String, int>{})),
    memory: _StubMemoryClient(),
    fileScope: FileScope.fromPriorityList(const <String>['/tom-brain-engine']),
    mcp: source,
  );
  return ToolBridge(registry, const ToolPolicy(ToolPolicyProfile.all), context);
}

/// A stub `McpToolSource`: lists [tools] and records each `(server, tool, args)`
/// invocation, echoing a deterministic `{echo: server/tool}` marker.
final class _StubMcpToolSource implements McpToolSource {
  final List<McpToolDefinition> tools;
  final List<(String, String, Map<String, Object?>)> invocations =
      <(String, String, Map<String, Object?>)>[];

  _StubMcpToolSource(this.tools);

  @override
  Future<List<McpToolDefinition>> listTools() async => tools;

  @override
  Future<Object?> invokeTool(
    String server,
    String tool,
    Map<String, Object?> arguments,
  ) async {
    invocations.add((server, tool, arguments));
    return <String, Object?>{'echo': '$server/$tool'};
  }
}

/// A stub MCP connection: returns canned tool/result data and records calls.
final class _StubConnection implements McpServerConnection {
  _StubConnection({
    this.tools = const <Map<String, Object?>>[],
    this.callResult = const <String, Object?>{},
  });

  final List<Map<String, Object?>> tools;
  final Map<String, Object?> callResult;

  String? lastCallName;
  Map<String, Object?>? lastCallArgs;

  @override
  Future<List<Map<String, Object?>>> listTools() async => tools;

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    lastCallName = name;
    lastCallArgs = args;
    return callResult;
  }

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

/// Minimal `TomBrainMemoryClient` — the MCP tools never touch it; present only
/// because [ToolContext.memory] is non-nullable.
class _StubMemoryClient implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
