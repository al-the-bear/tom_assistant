// todo #35 — cross-process MCP conformance.
//
// Proves the literal "callable from a **second process**" facet of
// `memory_specification.md` § 20 item 5, the residual E.55 / E.57 left
// open (Q-E.55.1 / Q-E.57.2): E.55 drove the v1 tool surface over the
// *in-process* transport (the direct-`TomBrainMemory` MCP server cannot
// read an isolate-hosted store), so cross-process invocation was never
// demonstrated. This test closes that gap.
//
// The proof is genuinely two OS processes:
//
//   - A child Dart process (`test/fixtures/mcp_http_server_fixture.dart`)
//     hosts `TomBrainMemoryMcpServer` over the Streamable-HTTP server
//     transport (`McpHttpServer`, todo #3) backed by a deterministic
//     seeded `TomBrainMemory`. It prints its OS-assigned port and stays
//     alive on stdin.
//   - This (parent) test process is the MCP client. It speaks raw
//     JSON-RPC over HTTP with `dart:io`'s `HttpClient` (no new
//     dependency — the package forbids an HTTP-client dep; the SDK
//     client is fine, same as `mcp_http_transport_test.dart`) and drives
//     the full v1 surface: the `initialize` handshake, `tools/list`, and
//     every one of the seven v1 tools.
//
// Because the server's `TomBrainMemory` lives in a different process, a
// returned value can only have arrived by crossing the process boundary
// over the wire — which is exactly the claim under test. The seeded
// values are deterministic so the assertions pin the round-trip end to
// end, not merely "a 200 came back".
//
// Scope note: this exercises the *transport / process boundary* against
// a seeded in-memory store, not the concrete `SqliteTomBrainMemory`
// (§ 20 item 1's separate carry-forward). Standing sqlite-vec up in a
// child process is orthogonal to proving cross-process callability.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:test/test.dart';

void main() {
  group('todo #35 cross-process MCP (HTTP, second OS process)', () {
    late io.Process serverProcess;
    late int port;
    late io.HttpClient client;
    final stderrBuffer = StringBuffer();

    setUp(() async {
      final fixturePath = _fixturePath();
      serverProcess = await io.Process.start(
        io.Platform.resolvedExecutable,
        ['run', fixturePath],
        // CWD is the package root under the test runner, so the child
        // resolves `package:tom_brain_memory` from the same package
        // config. Pass it through explicitly for robustness.
        workingDirectory: io.Directory.current.path,
      );
      // Keep stderr for diagnostics if the child fails to start.
      serverProcess.stderr
          .transform(utf8.decoder)
          .listen(stderrBuffer.write);

      port = await _awaitPort(serverProcess).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw StateError(
          'child MCP server never reported a port. stderr:\n$stderrBuffer',
        ),
      );
      client = io.HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      // Closing stdin triggers the fixture's clean shutdown; kill is the
      // backstop.
      try {
        await serverProcess.stdin.close();
      } catch (_) {/* already gone */}
      serverProcess.kill();
      await serverProcess.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () => -1,
      );
    });

    Uri url() => Uri.parse('http://127.0.0.1:$port/mcp');

    // Establishes a session and returns its id — the parent and child
    // are now talking MCP across the process boundary.
    Future<String> openSession() async {
      final init = await _post(client, url(), _initRequest(1));
      expect(init.status, equals(200),
          reason: 'initialize must succeed cross-process');
      final sessionId = init.headers['mcp-session-id'];
      expect(sessionId, isNotNull);
      final body = jsonDecode(init.body) as Map<String, Object?>;
      final serverInfo =
          (body['result'] as Map)['serverInfo'] as Map<String, Object?>;
      expect(serverInfo['name'], equals('tom_brain_memory'));

      final ack = await _post(
        client,
        url(),
        _notification('notifications/initialized'),
        sessionId: sessionId,
      );
      expect(ack.status, equals(202));
      return sessionId!;
    }

    test('initialize + tools/list advertise the ten v1 tools cross-process',
        () async {
      final sessionId = await openSession();

      final tools = await _post(
        client,
        url(),
        _request(2, 'tools/list'),
        sessionId: sessionId,
      );
      expect(tools.status, equals(200));
      final result = jsonDecode(tools.body)['result'] as Map<String, Object?>;
      final names = (result['tools'] as List)
          .map((t) => (t as Map)['name'] as String)
          .toSet();
      expect(
        names,
        equals({
          'memory.recall',
          'memory.recall.multi',
          'memory.get',
          'memory.edgesOf',
          'memory.stack.list',
          'memory.stack.peek',
          'memory.classify',
          'memory.profiles.list',
          'memory.profile.current',
          'memory.persistNote',
        }),
      );
    });

    test('memory.recall round-trips the seeded node across the process boundary',
        () async {
      final sessionId = await openSession();
      final payload = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.recall',
        arguments: {
          'text': 'why is the sky blue',
          'modes': ['bm25'],
          'k': 5,
        },
      );
      final nodes = payload['nodes'] as List;
      expect(nodes, hasLength(1));
      final node = nodes.single as Map<String, Object?>;
      expect(node['typeName'], equals('Question'));
      expect((node['values'] as Map)['text'], equals('why is the sky blue'));
      expect((node['id'] as String), startsWith('n_'));
      expect((payload['report'] as Map)['fusionStrategy'], equals('rrf'));
    });

    test('memory.get fetches the seeded node by id cross-process', () async {
      final sessionId = await openSession();
      // Discover the seeded id through recall, then fetch it by id — both
      // calls cross the process boundary.
      final recall = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.recall',
        arguments: {'text': 'q', 'modes': ['bm25']},
      );
      final seedId =
          ((recall['nodes'] as List).single as Map)['id'] as String;

      final got = await _callTool(
        client,
        url(),
        sessionId,
        id: 4,
        name: 'memory.get',
        arguments: {
          'ids': [seedId],
        },
      );
      final nodes = got['nodes'] as List;
      expect(nodes, hasLength(1));
      expect((nodes.single as Map)['id'], equals(seedId));
      expect((nodes.single as Map)['typeName'], equals('Question'));
    });

    test('memory.edgesOf returns the seeded edge cross-process', () async {
      final sessionId = await openSession();
      final recall = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.recall',
        arguments: {'text': 'q', 'modes': ['bm25']},
      );
      final seedId =
          ((recall['nodes'] as List).single as Map)['id'] as String;

      final payload = await _callTool(
        client,
        url(),
        sessionId,
        id: 4,
        name: 'memory.edgesOf',
        arguments: {'id': seedId, 'direction': 'outgoing'},
      );
      final edges = payload['edges'] as List;
      expect(edges, hasLength(1));
      final edge = edges.single as Map<String, Object?>;
      expect(edge['type'], equals('mentions'));
      expect(edge['from'], equals(seedId));
    });

    test('memory.stack.list + memory.stack.peek round-trip cross-process',
        () async {
      final sessionId = await openSession();

      final listed = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.stack.list',
      );
      final stacks = listed['stacks'] as List;
      expect(stacks, hasLength(1));
      expect((stacks.single as Map)['name'], equals('questions_open'));
      expect((stacks.single as Map)['bootstrap'], isTrue);

      final peeked = await _callTool(
        client,
        url(),
        sessionId,
        id: 4,
        name: 'memory.stack.peek',
        arguments: {'name': 'questions_open', 'k': 4},
      );
      final entries = peeked['entries'] as List;
      expect(entries, hasLength(1));
      expect((entries.single as Map)['priority'], equals(0.75));
      expect((entries.single as Map)['stackName'], equals('questions_open'));
    });

    test('memory.classify round-trips the centroid decision cross-process',
        () async {
      final sessionId = await openSession();
      final payload = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.classify',
        arguments: {
          'embedding': [0.1, 0.2, 0.3],
          'target': 'nodeType',
        },
      );
      expect(payload['decision'], equals('confident'));
      expect(payload['bestMatch'], equals('Question'));
    });

    test('memory.recall.multi fuses seeds + provenance cross-process '
        '(no substrate call)', () async {
      final sessionId = await openSession();
      final payload = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.recall.multi',
        arguments: {
          'seeds': [
            {'mode': 'bm25', 'text': 'why is the sky blue', 'weight': 2.0},
            {'mode': 'bm25', 'text': 'rayleigh scattering', 'weight': 1.0},
          ],
          'k': 10,
        },
      );
      // The fused node crossed the boundary with its node payload …
      final nodes = payload['nodes'] as List;
      expect(nodes, hasLength(1));
      expect((nodes.single as Map)['typeName'], equals('Question'));
      // … and its provenance, index-aligned with the node list, naming
      // the two surfacing seeds and carrying the fused score.
      final provenance = payload['provenance'] as List;
      expect(provenance, hasLength(1));
      final entry = provenance.single as Map<String, Object?>;
      expect(entry['seedIndexes'], equals([0, 1]));
      expect(entry['fusedScore'], equals(0.5));
      expect((payload['report'] as Map)['fusionStrategy'], equals('rrf'));
    });

    test('memory.profiles.list returns the real profile names cross-process',
        () async {
      final sessionId = await openSession();
      final payload = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.profiles.list',
      );
      expect(payload['profiles'], equals(['eval_a', 'eval_b']));
    });

    test('memory.profile.current returns the bound profile cross-process',
        () async {
      final sessionId = await openSession();
      final payload = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.profile.current',
      );
      expect(payload['profile'], equals('eval_a'));
    });

    test('memory.persistNote (the one v1 write) round-trips cross-process',
        () async {
      final sessionId = await openSession();
      final payload = await _callTool(
        client,
        url(),
        sessionId,
        id: 3,
        name: 'memory.persistNote',
        arguments: {
          'typeName': 'Question',
          'values': {'text': 'a question persisted over the wire'},
          'idempotencyKey': 'xproc-1',
        },
      );
      expect((payload['nodeId'] as String), startsWith('n_'));
    });

    test('a non-allowed persistNote type is refused cross-process (isError)',
        () async {
      final sessionId = await openSession();
      final res = await _post(
        client,
        url(),
        _toolCall(3, 'memory.persistNote', {
          'typeName': 'Event',
          'values': {'when': 'now'},
        }),
        sessionId: sessionId,
      );
      expect(res.status, equals(200));
      final result = jsonDecode(res.body)['result'] as Map<String, Object?>;
      expect(result['isError'], isTrue);
      final text = ((result['content'] as List).first as Map)['text'] as String;
      expect(text, contains('McpWriteForbidden'));
    });
  });
}

// ─── Process / port discovery ─────────────────────────────────────────

/// Resolves the fixture path relative to the package root (the test
/// runner's working directory).
String _fixturePath() {
  const relative = 'test/fixtures/mcp_http_server_fixture.dart';
  final file = io.File(relative);
  if (!file.existsSync()) {
    throw StateError(
      'fixture not found at ${file.absolute.path}; the test must run from '
      'the tom_brain_memory package root.',
    );
  }
  return relative;
}

/// The marker the fixture prints; mirrors `portMarker` in the fixture.
const String _portMarker = 'MCP_HTTP_PORT=';

/// Watches the child's stdout for the `MCP_HTTP_PORT=<n>` line and
/// resolves with the parsed port. Non-marker lines (e.g. MemoryLog
/// output) are ignored.
Future<int> _awaitPort(io.Process process) {
  final completer = Completer<int>();
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    if (completer.isCompleted) return;
    final trimmed = line.trim();
    if (trimmed.startsWith(_portMarker)) {
      final value = int.tryParse(trimmed.substring(_portMarker.length));
      if (value != null) completer.complete(value);
    }
  }, onError: (Object e) {
    if (!completer.isCompleted) completer.completeError(e);
  });
  return completer.future;
}

// ─── JSON-RPC over HTTP helpers (mirror mcp_http_transport_test.dart) ──

/// Calls a tool and returns the decoded tool payload (the JSON object the
/// tool encoded into its single `TextContent`). Asserts the call was not
/// an error.
Future<Map<String, Object?>> _callTool(
  io.HttpClient client,
  Uri url,
  String sessionId, {
  required int id,
  required String name,
  Map<String, Object?>? arguments,
}) async {
  final res = await _post(
    client,
    url,
    _toolCall(id, name, arguments),
    sessionId: sessionId,
  );
  expect(res.status, equals(200), reason: '$name must answer 200');
  final result = jsonDecode(res.body)['result'] as Map<String, Object?>;
  expect(result['isError'], isNot(isTrue),
      reason: '$name must not be a tool error');
  final text = ((result['content'] as List).first as Map)['text'] as String;
  return jsonDecode(text) as Map<String, Object?>;
}

String _toolCall(int id, String name, Map<String, Object?>? arguments) =>
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {
        'name': name,
        'arguments': ?arguments,
      },
    });

String _initRequest(int id) => jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'xproc-test-client', 'version': '0.0.1'},
      },
    });

String _request(int id, String method) => jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': <String, Object?>{},
    });

String _notification(String method) => jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
    });

typedef _HttpResult = ({
  int status,
  Map<String, String> headers,
  String body,
});

Future<_HttpResult> _post(
  io.HttpClient client,
  Uri url,
  String body, {
  String? sessionId,
}) async {
  final req = await client.postUrl(url);
  req.headers.contentType = io.ContentType.json;
  if (sessionId != null) req.headers.set('Mcp-Session-Id', sessionId);
  req.write(body);
  final resp = await req.close();
  final text = await utf8.decoder.bind(resp).join();
  final headers = <String, String>{};
  resp.headers.forEach((name, values) => headers[name] = values.join(','));
  return (status: resp.statusCode, headers: headers, body: text);
}
