// P2.18 — wire the real store into the isolate transport and MCP server.
//
// prototype_implementation_plan_2.md #18:
//   "Memory: wire the real store into the isolate transport and MCP
//    server. Provide the top-level `MemoryFactory` returning
//    `SqliteTomBrainMemory()`; drive `open(config)` via
//    `OpenMemoryRequest` inside the worker; back the MCP server v1
//    (7 read tools + `memory.persistNote`) with the real store.
//    Test: isolate host/client round-trip against the real store; MCP
//    `memory.recall`/`get` over the real store. Verify: MCP read tools
//    return real persisted nodes across the isolate boundary."
//
// The earlier a79/a82/a89 isolate suites and the a77 MCP-tools suite
// drove the wire against in-memory *fakes*. This file proves the same
// two transports carry the *real* `SqliteTomBrainMemory` store:
//
//   * Group A — spawn an isolate over the production
//     `createSqliteTomBrainMemory` factory, open a real on-disk store
//     inside the worker via `OpenMemoryRequest`, then persist and read
//     back through `TomBrainMemoryIsolateClient`. The node that comes
//     back is the one persisted, having crossed the isolate boundary.
//   * Group B — back a `TomBrainMemoryMcpServer` with a real in-process
//     store, persist nodes, then call `memory.get` / `memory.recall`
//     over a live MCP client connection. The tool results carry the
//     real persisted nodes.
//
// Like p2_13 – p2_17 these cases need the packaged vec0 binary (the
// real store refuses to boot without it — P1.1) and are skipped, not
// failed, when the running platform has no binary under
// tom_binaries/sqlite_vec.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, NodeId, RecallMode, RecallQuery, Vec;

/// The bootstrap embedding model dimensionality (768, nomic-embed-text).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector. Mirrors p2_16 / p2_17 `_v768`.
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 / p2_17.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Builds an Event [NodeDraft] carrying [text] / `_v768(seed:)`.
NodeDraft _eventDraft({required String text, required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': text,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-05T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  /// A fresh real-store config rooted in a unique temp dir, with
  /// teardown registered for the directory.
  MemoryConfig freshConfig() {
    final root = Directory.systemTemp.createTempSync('tbm_p2_18_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  group('SqliteTomBrainMemory — real store over the isolate transport '
      '(needs vec0)', () {
    test('persist + get round-trip through the isolate client', () async {
      final host =
          TomBrainMemoryIsolateHost(factory: createSqliteTomBrainMemory);
      await host.spawn();
      final client = TomBrainMemoryIsolateClient(host);
      addTearDown(host.shutdown);

      // Drives memory.open(config) inside the worker via
      // OpenMemoryRequest — the real SqliteTomBrainMemory boots on disk.
      await client.open(freshConfig());

      final id = await client.persist(
        _eventDraft(text: 'isolate round-trip', seed: 1),
        scope: const Scope(producer: 'p2.18:test', idempotencyKey: 'a'),
      );
      expect(id, isA<NodeId>());

      final node = await client.get(id);
      expect(node, isNotNull,
          reason: 'the node persisted inside the worker must read back '
              'across the isolate boundary');
      expect(node!.id, equals(id));
      expect(node.typeName, equals('Event'));
      expect(node.values['summary'], equals('isolate round-trip'));
    });

    test('recall returns the real persisted node across the boundary',
        () async {
      final host =
          TomBrainMemoryIsolateHost(factory: createSqliteTomBrainMemory);
      await host.spawn();
      final client = TomBrainMemoryIsolateClient(host);
      addTearDown(host.shutdown);

      await client.open(freshConfig());

      final hit = await client.persist(
        _eventDraft(text: 'alpha distinctive needle', seed: 2),
        scope: const Scope(producer: 'p2.18:test', idempotencyKey: 'hit'),
      );
      await client.persist(
        _eventDraft(text: 'completely unrelated chaff', seed: 3),
        scope: const Scope(producer: 'p2.18:test', idempotencyKey: 'miss'),
      );

      final result = await client.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.bm25},
        text: 'distinctive',
        k: 10,
      ));

      expect(result.nodes, isNotEmpty);
      expect(result.nodes.first.id, equals(hit),
          reason: 'BM25 over the real store returns the matching node, '
              'marshalled back across the isolate boundary');
    });
  }, skip: skipNoBinary);

  group('TomBrainMemoryMcpServer — backed by the real store (needs vec0)',
      () {
    test('memory.get returns the real persisted node', () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      final env = _McpEnv(memory: store);
      addTearDown(() async {
        await env.shutdown();
        await store.close();
      });

      final id = await store.persist(
        _eventDraft(text: 'mcp get target', seed: 4),
        scope: const Scope(producer: 'p2.18:test', idempotencyKey: 'g'),
      );

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.get',
          arguments: <String, Object?>{
            'ids': <String>[id.value],
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final nodes = _decode(result)['nodes'] as List<Object?>;
      expect(nodes, hasLength(1));
      final node = nodes.single as Map<String, Object?>;
      expect(node['id'], equals(id.value));
      expect(node['typeName'], equals('Event'));
      expect((node['values'] as Map)['summary'], equals('mcp get target'));
    });

    test('memory.recall returns the real persisted node', () async {
      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      final env = _McpEnv(memory: store);
      addTearDown(() async {
        await env.shutdown();
        await store.close();
      });

      final hit = await store.persist(
        _eventDraft(text: 'beacon singular landmark', seed: 5),
        scope: const Scope(producer: 'p2.18:test', idempotencyKey: 'r-hit'),
      );
      await store.persist(
        _eventDraft(text: 'ambient background filler', seed: 6),
        scope: const Scope(producer: 'p2.18:test', idempotencyKey: 'r-miss'),
      );

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: <String, Object?>{
            'text': 'landmark',
            'modes': <String>['bm25'],
            'k': 10,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final nodes = _decode(result)['nodes'] as List<Object?>;
      expect(nodes, isNotEmpty);
      final ids = nodes
          .map((n) => (n as Map<String, Object?>)['id'])
          .toList(growable: false);
      expect(ids.first, equals(hit.value),
          reason: 'BM25 over the real store surfaces the matching node '
              'through the MCP read tool');
    });
  }, skip: skipNoBinary);
}

// ─── MCP harness ────────────────────────────────────────────────────
//
// Mirrors a77's `_TestEnv`: an in-memory `StreamChannel<String>` pair
// drives a live `MCPClient` ↔ `TomBrainMemoryMcpServer` connection in
// the same isolate. Eager construction in the constructor body (NOT
// `late final` lazy init) is required so the server is listening before
// the client starts the `initialize` handshake.

Map<String, Object?> _decode(mcp_server.CallToolResult result) {
  final text = (result.content.first as mcp_server.TextContent).text;
  return jsonDecode(text) as Map<String, Object?>;
}

class _McpEnv {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  late final StreamChannel<String> clientChannel;
  late final StreamChannel<String> serverChannel;
  late final mcp_client.MCPClient client;
  late final TomBrainMemoryMcpServer server;
  late final mcp_client.ServerConnection serverConnection;

  _McpEnv({required TomBrainMemory memory}) {
    clientChannel = StreamChannel<String>.withCloseGuarantee(
      serverController.stream,
      clientController.sink,
    );
    serverChannel = StreamChannel<String>.withCloseGuarantee(
      clientController.stream,
      serverController.sink,
    );
    client = _P218McpClient();
    server = TomBrainMemoryMcpServer(serverChannel, memory: memory);
    serverConnection = client.connectServer(clientChannel);
  }

  Future<void> initializeHandshake() async {
    final result = await serverConnection.initialize(
      mcp_server.InitializeRequest(
        protocolVersion: mcp_server.ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    if (result.protocolVersion?.isSupported == true) {
      serverConnection.notifyInitialized(mcp_server.InitializedNotification());
      await server.initialized;
    }
  }

  Future<void> shutdown() async {
    await client.shutdown();
    await server.shutdown();
  }
}

base class _P218McpClient extends mcp_client.MCPClient {
  _P218McpClient()
      : super(
          mcp_client.Implementation(name: 'p2-18-test-client', version: '0.0.1'),
        );
}
