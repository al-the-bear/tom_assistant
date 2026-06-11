// Extension F step 8 — the `mcp.servers` / `mcp.list` / `mcp.call` bridged
// primitives (`tom_brain_procedure_specification.md` § 21.3,
// § 21.10; `prototype_tools_mcp_extension_plan.md` step 8).
//
// `McpBridge` is a plain Dart class bridged exactly like `MemoryBridge` /
// `SubstrateBridge` / `ToolBridge`. It exposes three d4rt-facing methods
// over an `McpClient` (a per-server-id connection pool) and the run's
// `ToolContext`:
//
//   mcp.servers()           → List<Map> of {id, transport, description}
//                             (the configured servers; no effect cost).
//   mcp.list(server)        → List<Map> of {name, description, input_schema}
//                             (the remote server's advertised tools). An
//                             unreachable server raises `McpFailure`
//                             (propagates — there is no {ok} envelope on a
//                             list).
//   mcp.call(server, tool, args) → {ok: true, result} on success;
//                             {ok: false, error} when the server is unknown
//                             or the call fails. Charges one `toolCalls`
//                             unit *before* the wire call (PE-8); an
//                             attempted-but-failed call is still charged
//                             ("counts the call", § 21.10).
//
// What this suite locks:
//
//   F.8-1  — the catalog knows `mcp.servers` / `mcp.list` / `mcp.call`,
//            with the dotted→camel call tokens.
//   F.8-2  — the effort accountant scores `mcp.call` as one toolCall (so
//            the budget gate can pre-charge it) and `mcp.servers` /
//            `mcp.list` as zero.
//   F.8-3  — servers() returns {id, transport, description} per config.
//   F.8-4  — list happy path: {name, description, input_schema} per tool.
//   F.8-5  — call happy path: {ok: true, result} + one toolCall charged.
//   F.8-6  — call unknown server → {ok: false} (no budget charge).
//   F.8-7  — call unreachable (connector/call throws) → {ok: false, error},
//            the call IS charged (counts the call).
//   F.8-8  — list unreachable raises McpFailure (propagates, no envelope).
//   F.8-9  — budget pre-charge refuses the call over the toolCalls cap with
//            ProcedureBudgetExceeded, before the wire call.
//   F.8-10 — the connection pool reuses one connection per server id and
//            closes them all on McpClient.close().
//   F.8-11 — a d4rt script calls mcp.servers / mcp.list / mcp.call through
//            the interpreter (the generator-output round-trip).
//   F.8-12 — D4rtDcliHost injects the bridge as the `mcp` global.
//   F.8-13 — integration: a real `dart_mcp` client reaches a real
//            `TomBrainMemoryMcpServer` over an in-memory channel; mcp.list
//            sees the memory server's advertised tools.

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:tom_d4rt/d4rt.dart';
import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemory, TomBrainMemoryClient, TomBrainMemoryMcpServer;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('F.8-1 catalog membership', () {
    test('mcp.servers / mcp.list / mcp.call are recognised primitives', () {
      expect(BridgedPrimitiveCatalog.isKnown('mcp.servers'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('mcp.list'), isTrue);
      expect(BridgedPrimitiveCatalog.isKnown('mcp.call'), isTrue);
      expect(
        BridgedPrimitiveCatalog.all,
        containsAll(<String>['mcp.servers', 'mcp.list', 'mcp.call']),
      );
    });

    test('the dotted call tokens carry their camelCase spelling', () {
      expect(BridgedPrimitiveCatalog.callTokensFor('mcp.servers'),
          <String>{'mcp.servers', 'mcpServers'});
      expect(BridgedPrimitiveCatalog.callTokensFor('mcp.list'),
          <String>{'mcp.list', 'mcpList'});
      expect(BridgedPrimitiveCatalog.callTokensFor('mcp.call'),
          <String>{'mcp.call', 'mcpCall'});
    });
  });

  group('F.8-2 effort accounting', () {
    const accountant = EffortAccountant();

    test('mcp.call scores one toolCall (dotted and camel spelling)', () {
      expect(accountant.classify('mcp.call').toolCalls, 1);
      expect(accountant.classify('mcpCall').toolCalls, 1);
    });

    test('mcp.servers / mcp.list score no effort — they only enumerate', () {
      expect(accountant.classify('mcp.servers'), EffortMetrics.zero);
      expect(accountant.classify('mcp.list'), EffortMetrics.zero);
    });
  });

  group('F.8-3 servers — configured registry', () {
    test('servers() returns {id, transport, description} per config', () async {
      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(
            id: 'memory',
            transport: McpTransport.http,
            description: 'the memory MCP server',
          ),
          McpServerConfig(id: 'external', transport: McpTransport.stdio),
        ],
      );

      final listed = await bridge.servers();

      expect(listed, hasLength(2));
      final memory = listed.firstWhere((s) => s['id'] == 'memory');
      expect(memory['transport'], 'http');
      expect(memory['description'], 'the memory MCP server');
      final external = listed.firstWhere((s) => s['id'] == 'external');
      expect(external['transport'], 'stdio');
    });
  });

  group('F.8-4 list — advertised tools', () {
    test('list returns {name, description, input_schema} per tool', () async {
      final connection = _StubConnection(
        tools: const <Map<String, Object?>>[
          <String, Object?>{
            'name': 'echo',
            'description': 'echoes',
            'input_schema': <String, Object?>{'type': 'object'},
          },
        ],
      );
      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(id: 'stub', transport: McpTransport.stdio),
        ],
        connector: _StubConnector(connection),
      );

      final listed = await bridge.list('stub');

      expect(listed, hasLength(1));
      expect(listed.single['name'], 'echo');
      expect(listed.single['description'], 'echoes');
      expect(listed.single['input_schema'], isA<Map<String, Object?>>());
    });
  });

  group('F.8-5 call — happy path', () {
    test('a configured server call returns {ok: true, result} + charges 1',
        () async {
      final ledger = _ledger(toolCalls: 1);
      final connection = _StubConnection(
        callResult: const <String, Object?>{'answer': 42},
      );
      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(id: 'stub', transport: McpTransport.stdio),
        ],
        connector: _StubConnector(connection),
        budget: ledger,
      );

      final result =
          await bridge.call('stub', 'compute', const <String, Object?>{'x': 1});

      expect(result['ok'], isTrue);
      expect(result['result'], const <String, Object?>{'answer': 42});
      expect(connection.lastCallName, 'compute');
      expect(connection.lastCallArgs, const <String, Object?>{'x': 1});
      expect(ledger.consumed.toolCalls, 1,
          reason: 'a successful MCP call charges one toolCall (PE-8)');
    });
  });

  group('F.8-6 call — unknown server', () {
    test('an unconfigured server returns {ok: false}, no budget charge',
        () async {
      final ledger = _ledger(toolCalls: 1);
      final bridge = _bridge(
        servers: const <McpServerConfig>[],
        budget: ledger,
      );

      final result =
          await bridge.call('missing', 'tool', const <String, Object?>{});

      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(ledger.consumed.toolCalls, 0,
          reason: 'an unknown server never reaches the budget pre-charge');
    });
  });

  group('F.8-7 call — unreachable (PE-6)', () {
    test('a wire failure returns {ok: false, error} and charges the call',
        () async {
      final ledger = _ledger(toolCalls: 2);
      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(id: 'stub', transport: McpTransport.stdio),
        ],
        connector: _StubConnector(null, throwOnConnect: true),
        budget: ledger,
      );

      final result =
          await bridge.call('stub', 'tool', const <String, Object?>{});

      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(ledger.consumed.toolCalls, 1,
          reason: 'an attempted-but-failed call still counts (§ 21.10)');
    });
  });

  group('F.8-8 list — unreachable propagates', () {
    test('an unreachable server raises McpFailure (no {ok} envelope)',
        () async {
      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(id: 'stub', transport: McpTransport.stdio),
        ],
        connector: _StubConnector(null, throwOnConnect: true),
      );

      await expectLater(
        bridge.list('stub'),
        throwsA(isA<McpFailure>()),
      );
    });
  });

  group('F.8-9 call — budget pre-charge (PE-8)', () {
    test('a call over the toolCalls cap is refused before the wire call',
        () async {
      final ledger = _ledger(toolCalls: 1);
      final connection = _StubConnection(
        callResult: const <String, Object?>{'ok': 1},
      );
      final connector = _StubConnector(connection);
      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(id: 'stub', transport: McpTransport.stdio),
        ],
        connector: connector,
        budget: ledger,
      );

      final first =
          await bridge.call('stub', 'a', const <String, Object?>{});
      expect(first['ok'], isTrue);
      expect(ledger.consumed.toolCalls, 1);

      final before = connection.callCount;
      await expectLater(
        bridge.call('stub', 'b', const <String, Object?>{}),
        throwsA(isA<ProcedureBudgetExceeded>()),
      );
      expect(connection.callCount, before,
          reason: 'the refused call never reaches the wire (pre-charge gate)');
    });
  });

  group('F.8-10 connection pool', () {
    test('one connection per server id is reused and closed on close()',
        () async {
      final connection = _StubConnection(
        callResult: const <String, Object?>{'ok': 1},
      );
      final connector = _StubConnector(connection);
      final client = McpClient(
        const <McpServerConfig>[
          McpServerConfig(id: 'stub', transport: McpTransport.stdio),
        ],
        connector,
      );

      await client.listTools('stub');
      await client.callTool('stub', 't', const <String, Object?>{});

      expect(connector.connectCount, 1,
          reason: 'the pool reuses the single connection across calls');

      await client.close();
      expect(connection.closeCount, 1);
    });
  });

  group('F.8-11 d4rt round-trip through the interpreter', () {
    test('a script calls mcp.servers / mcp.list / mcp.call', () async {
      final connection = _StubConnection(
        tools: const <Map<String, Object?>>[
          <String, Object?>{'name': 'echo', 'description': 'e'},
        ],
        callResult: const <String, Object?>{'value': 'streamed'},
      );
      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(id: 'stub', transport: McpTransport.stdio),
        ],
        connector: _StubConnector(connection),
      );
      final interpreter = D4rt();
      BrainBridges.register(interpreter);

      final result = await interpreter.execute(
        source: '''
import '${BridgeLibraries.mcpLibrary}';

Future<Map<String, Object?>> main(McpBridge mcp) async {
  final servers = await mcp.servers();
  final tools = await mcp.list('stub');
  final called = await mcp.call('stub', 'echo', {'x': 1});
  return {
    'serverCount': servers.length,
    'firstServer': servers[0]['id'],
    'toolCount': tools.length,
    'ok': called['ok'],
    'result': called['result'],
  };
}
''',
        positionalArgs: <Object?>[bridge],
      );

      final out = (result as Map).cast<String, Object?>();
      expect(out['serverCount'], 1);
      expect(out['firstServer'], 'stub');
      expect(out['toolCount'], 1);
      expect(out['ok'], isTrue);
      expect(out['result'], const <String, Object?>{'value': 'streamed'});
    });
  });

  group('F.8-12 host injects the `mcp` global', () {
    test('D4rtDcliHost binds the bridge as `mcp` and a script reaches it',
        () async {
      final connection = _StubConnection(
        callResult: const <String, Object?>{'value': 'wired'},
      );
      final host = D4rtDcliHost(
        memoryBridge: MemoryBridge(_StubMemoryClient()),
        substrateBridge: SubstrateBridge(_StubSubstrateClient()),
        mcpBridge: _bridge(
          servers: const <McpServerConfig>[
            McpServerConfig(id: 'stub', transport: McpTransport.stdio),
          ],
          connector: _StubConnector(connection),
        ),
      );

      final result = await host.run(
        '''
import '${BridgeLibraries.mcpLibrary}';

Future<Object?> run(Object? inputs) async {
  final called = await mcp.call('stub', 'echo', {});
  return called['result'];
}
''',
        inputs: const <Object?>[null],
      );

      expect(result, const <String, Object?>{'value': 'wired'});
    });
  });

  group('F.8-13 integration — real dart_mcp client ↔ memory MCP server', () {
    test('mcp.list reaches the memory server and sees its advertised tools',
        () async {
      // Bridge a real TomBrainMemoryMcpServer to a real dart_mcp client over
      // an in-memory channel: controller.foreign → server, controller.local
      // → client. No HTTP, no subprocess — proves real interop.
      final controller = StreamChannelController<String>(allowForeignErrors: false);
      final server = TomBrainMemoryMcpServer(
        controller.foreign,
        memory: _StubMemory(),
      );
      addTearDown(server.shutdown);

      final bridge = _bridge(
        servers: const <McpServerConfig>[
          McpServerConfig(
            id: 'memory',
            transport: McpTransport.http,
            description: 'the memory MCP server',
          ),
        ],
        connector: DartMcpConnector(
          channelFactory: (config) async => controller.local,
        ),
      );

      final tools = await bridge.list('memory');
      final names = tools.map((t) => t['name']).toSet();

      expect(names, containsAll(<String>['memory.recall', 'memory.get']),
          reason: 'the memory server advertises its seven-tool read surface');
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// Builds an [McpBridge] over a [McpClient] seeded with [servers], an
/// optional [connector] (default one that never connects), and a
/// [ToolContext] over [budget] (default an uncapped ledger).
McpBridge _bridge({
  required List<McpServerConfig> servers,
  McpConnector? connector,
  BudgetLedger? budget,
}) {
  final client = McpClient(
    servers,
    connector ?? _StubConnector(null, throwOnConnect: true),
  );
  final context = ToolContext(
    budget: budget ?? _ledger(),
    memory: _StubMemoryClient(),
    fileScope: FileScope.fromPriorityList(const <String>['/tom-brain-engine']),
  );
  return McpBridge(client, context);
}

/// A ledger over a budget that caps [toolCalls] (or no cap when omitted).
BudgetLedger _ledger({int? toolCalls}) => BudgetLedger(
      ProcedureBudget(<String, int>{'toolCalls': ?toolCalls}),
    );

/// A stub MCP connection: records calls and returns canned tool/result data.
final class _StubConnection implements McpServerConnection {
  _StubConnection({
    this.tools = const <Map<String, Object?>>[],
    this.callResult = const <String, Object?>{},
  });

  final List<Map<String, Object?>> tools;
  final Map<String, Object?> callResult;

  int callCount = 0;
  int closeCount = 0;
  String? lastCallName;
  Map<String, Object?>? lastCallArgs;

  @override
  Future<List<Map<String, Object?>>> listTools() async => tools;

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    callCount++;
    lastCallName = name;
    lastCallArgs = args;
    return callResult;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

/// A stub connector that hands back a single [_StubConnection], or throws to
/// simulate an unreachable server.
final class _StubConnector implements McpConnector {
  _StubConnector(this._connection, {this.throwOnConnect = false});

  final McpServerConnection? _connection;
  final bool throwOnConnect;
  int connectCount = 0;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async {
    connectCount++;
    if (throwOnConnect || _connection == null) {
      throw const McpFailure(
        mcpUnreachableCode,
        serverId: 'stub',
        message: 'unreachable',
      );
    }
    return _connection;
  }
}

/// Minimal `TomBrainMemoryClient` — the MCP tools never touch it; present
/// only because [ToolContext.memory] is non-nullable.
class _StubMemoryClient implements TomBrainMemoryClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Minimal `TomBrainSubstrateClient` for the host-wiring test.
class _StubSubstrateClient implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Minimal `TomBrainMemory` for the integration test — the memory server
/// registers its seven tools whenever `memory` is non-null; `tools/list`
/// never invokes a handler, so no method is exercised here.
class _StubMemory implements TomBrainMemory {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
