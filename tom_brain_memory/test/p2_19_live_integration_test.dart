// P2.19 — live integration roundtrip: real store + real Ollama
// embeddings + real vec0 + MCP, no doubles.
//
// prototype_implementation_plan_2.md #19:
//   "Memory: live integration roundtrip. Open a real on-disk store,
//    persist with **real Ollama embeddings**, recall through **real
//    vec0**, inspect via MCP. Verify: persist→vector-recall→MCP
//    inspect all succeed on disk with the production stack (no
//    doubles)."
//
// "No doubles" is literal: nothing in this file is a fake. The
// embeddings come from a live Ollama (`nomic-embed-text`, 768-dim),
// the vectors are indexed by the packaged vec0 extension, the store
// is a real on-disk `SqliteTomBrainMemory`, and the MCP surface is a
// real `TomBrainMemoryMcpServer` driven over a live client connection.
//
//   * Group A — store-direct: persist two semantically distant Events
//     with their real Ollama embeddings, then run a `RecallMode.vector`
//     recall whose query vector is the real embedding of a phrase close
//     to one Event. vec0 must rank that Event first.
//   * Group B — through MCP: the same persist + vector recall, but the
//     recall is issued through the `memory.recall` MCP tool (which
//     accepts a pre-computed query embedding + `modes:['vector']`), and
//     the persisted node is read back through `memory.get`.
//
// The memory package does no outbound HTTP by design (§ 1.5 — embeddings
// are owned by substrate; see `dependency_surface_test.dart`). So the
// embedding callouts here go through `dart:io`'s `HttpClient` directly
// from the test, never through the package.
//
// Two independent preconditions gate every case: the packaged vec0
// binary (group-level `skip`, like p2_16 – p2_18) and a reachable
// Ollama (per-test `markTestSkipped`). When either is absent the cases
// are skipped, not failed, so the suite stays green off-box.

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
    show NodeDraft, RecallMode, RecallQuery, Vec;

/// The bootstrap embedding model and its dimensionality.
const _embeddingModel = 'nomic-embed-text';
const _bootstrapDims = 768;

/// Ollama's embeddings endpoint on the local host.
final _ollamaEmbeddingsUri =
    Uri.parse('http://localhost:11434/api/embeddings');

/// Obtains a real embedding for [text] from a live Ollama, or `null`
/// when Ollama is unreachable / errors. Uses `dart:io` directly so the
/// package's no-outbound-HTTP contract is never crossed.
Future<Vec?> _ollamaEmbed(String text) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(_ollamaEmbeddingsUri);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(
      jsonEncode(<String, Object?>{'model': _embeddingModel, 'prompt': text}),
    ));
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as Map<String, Object?>;
    final raw = decoded['embedding'];
    if (raw is! List || raw.isEmpty) return null;
    final values = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      values[i] = (raw[i] as num).toDouble();
    }
    return Vec(values);
  } on Object {
    // Connection refused, timeout, malformed body — treated as
    // "Ollama not available", which the caller turns into a skip.
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors p2_16 – p2_18.
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

/// Builds an Event [NodeDraft] carrying [text] and a real [embedding].
NodeDraft _eventDraft({required String text, required Vec embedding}) =>
    NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': text,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-05T10:00:00.000Z',
      },
      embedding: embedding,
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
    final root = Directory.systemTemp.createTempSync('tbm_p2_19_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  // Two semantically distant Events plus a query phrase close to the
  // first. With real embeddings + real vec0 the cosine-nearest of the
  // two persisted vectors must be the feline Event, never the finance
  // one.
  const felineText = 'A cat dozed on the warm windowsill in the afternoon sun.';
  const financeText =
      'The stock market fell sharply after the central bank raised rates.';
  const queryText = 'a sleepy kitten resting in the sunshine';

  group('SqliteTomBrainMemory — live store + real Ollama + real vec0 '
      '(needs vec0)', () {
    test('persist with real embeddings, vector-recall through vec0', () async {
      final queryVec = await _ollamaEmbed(queryText);
      if (queryVec == null) {
        markTestSkipped('Ollama not reachable on localhost:11434.');
        return;
      }
      final felineVec = await _ollamaEmbed(felineText);
      final financeVec = await _ollamaEmbed(financeText);
      expect(queryVec.values, hasLength(_bootstrapDims),
          reason: 'nomic-embed-text returns 768-dim vectors');

      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      addTearDown(store.close);

      final felineId = await store.persist(
        _eventDraft(text: felineText, embedding: felineVec!),
        scope: const Scope(producer: 'p2.19:test', idempotencyKey: 'feline'),
      );
      await store.persist(
        _eventDraft(text: financeText, embedding: financeVec!),
        scope: const Scope(producer: 'p2.19:test', idempotencyKey: 'finance'),
      );

      final result = await store.recall(RecallQuery(
        modes: const <RecallMode>{RecallMode.vector},
        embedding: queryVec,
        k: 10,
      ));

      expect(result.nodes, isNotEmpty);
      expect(result.nodes.first.id, equals(felineId),
          reason: 'real vec0 ranks the semantically-nearest Event first');
      expect(result.report.degraded, isFalse);

      // The recall result carries the real persisted node, on disk.
      final top = result.nodes.first;
      expect(top.typeName, equals('Event'));
      expect(top.values['summary'], equals(felineText));
    });
  }, skip: skipNoBinary);

  group('TomBrainMemoryMcpServer — live store + real Ollama + real vec0 '
      'over MCP (needs vec0)', () {
    test('persist with real embeddings, vector-recall + get through MCP',
        () async {
      final queryVec = await _ollamaEmbed(queryText);
      if (queryVec == null) {
        markTestSkipped('Ollama not reachable on localhost:11434.');
        return;
      }
      final felineVec = await _ollamaEmbed(felineText);
      final financeVec = await _ollamaEmbed(financeText);

      final store = SqliteTomBrainMemory();
      await store.open(freshConfig());
      final env = _McpEnv(memory: store);
      addTearDown(() async {
        await env.shutdown();
        await store.close();
      });

      final felineId = await store.persist(
        _eventDraft(text: felineText, embedding: felineVec!),
        scope: const Scope(producer: 'p2.19:test', idempotencyKey: 'mcp-feline'),
      );
      await store.persist(
        _eventDraft(text: financeText, embedding: financeVec!),
        scope:
            const Scope(producer: 'p2.19:test', idempotencyKey: 'mcp-finance'),
      );

      await env.initializeHandshake();

      // Vector recall through the MCP boundary: the tool accepts a
      // pre-computed query embedding + modes:['vector'].
      final recall = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: <String, Object?>{
            'embedding': queryVec.values.toList(growable: false),
            'modes': <String>['vector'],
            'k': 10,
          },
        ),
      );
      expect(recall.isError, isNot(isTrue));
      final recalledNodes = _decode(recall)['nodes'] as List<Object?>;
      expect(recalledNodes, isNotEmpty);
      final firstId =
          (recalledNodes.first as Map<String, Object?>)['id'];
      expect(firstId, equals(felineId.value),
          reason: 'vec0 over the real store ranks the feline Event first, '
              'marshalled back through the MCP read tool');

      // Inspect the same node through memory.get.
      final got = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.get',
          arguments: <String, Object?>{
            'ids': <String>[felineId.value],
          },
        ),
      );
      expect(got.isError, isNot(isTrue));
      final gotNodes = _decode(got)['nodes'] as List<Object?>;
      expect(gotNodes, hasLength(1));
      final node = gotNodes.single as Map<String, Object?>;
      expect(node['id'], equals(felineId.value));
      expect(node['typeName'], equals('Event'));
      expect((node['values'] as Map)['summary'], equals(felineText));
    });
  }, skip: skipNoBinary);
}

// ─── MCP harness ────────────────────────────────────────────────────
//
// Mirrors p2_18 / a77: an in-memory `StreamChannel<String>` pair drives
// a live MCPClient ↔ TomBrainMemoryMcpServer connection in the same
// isolate. Eager construction in the constructor body (NOT `late final`
// lazy init) is required so the server is listening before the client
// starts the `initialize` handshake.

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
    client = _P219McpClient();
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

base class _P219McpClient extends mcp_client.MCPClient {
  _P219McpClient()
      : super(
          mcp_client.Implementation(name: 'p2-19-test-client', version: '0.0.1'),
        );
}
