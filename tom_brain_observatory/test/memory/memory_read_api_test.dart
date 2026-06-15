// PT-6 backend — the `/api/memory/*` HTTP surface (`prompt_tracing.md` § 8.4).
// The Flutter-web client cannot speak MCP and OBS-3 forbids any DB path, so the
// backend re-exposes the nine read tools over same-origin HTTP. These route
// tests drive a [TrailReadApi] with an injected [MemoryReadClient] (over the
// [FakeReadConnection]), proving each route marshals to the right read tool and
// re-serializes the typed result — and that the write tool has no door (OBS-2).
//
// The 503 group pins the deferred-connector contract: with no client wired,
// every `/api/memory/*` route answers `503 {"error": "memory unavailable"}` —
// absence is reported, never crashed.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/fake_read_connection.dart';

/// A connection whose every call throws a bare [StateError] — the shape
/// json_rpc_2 raises when the MCP session closes underneath a call ("the client
/// is closed"). Used to prove the route degrades to 503 rather than 500.
final class _ClosedSessionConnection implements McpReadConnection {
  @override
  Future<Map<String, Object?>> callTool(
          String name, Map<String, Object?> args) async =>
      throw StateError('Bad state: The client is closed.');

  @override
  Future<List<Map<String, Object?>>> listTools() async =>
      throw StateError('Bad state: The client is closed.');

  @override
  Future<void> close() async {}
}

const _fixtureHost = 'test/fixtures/trail/fixturehost';

Future<Response> _get(TrailReadApi api, String path) async =>
    api.handler(Request('GET', Uri.parse('http://localhost/$path')));

Future<Response> _post(TrailReadApi api, String path, Object body) async =>
    api.handler(Request('POST', Uri.parse('http://localhost/$path'),
        body: jsonEncode(body)));

Future<Map<String, Object?>> _jsonMap(Response res) async =>
    (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();

void main() {
  final host = TrailHost.at(_fixtureHost);

  group('PT-6 — /api/memory/* with a wired client', () {
    late FakeReadConnection conn;
    late TrailReadApi api;

    setUp(() {
      conn = FakeReadConnection(allReadToolStubs());
      api = TrailReadApi(host: host, memory: MemoryReadClient(conn));
    });

    test('GET /api/memory/nodes?type=Question browses and filters by type',
        () async {
      final res = await _get(api, 'api/memory/nodes?type=Question');
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      expect(body['typeName'], 'Question');
      expect(body['exhaustive'], isFalse);
      final nodes = (body['nodes'] as List).cast<Map>();
      expect(nodes.map((n) => n['id']), <String>['n_question1']);
      expect(conn.calledTools, contains('memory.recall'));
      expect(conn.calledArgs.first['text'], 'Question');
    });

    test('GET /api/memory/nodes without ?type= is a 400', () async {
      final res = await _get(api, 'api/memory/nodes');
      expect(res.statusCode, 400);
    });

    test('GET /api/memory/nodes/<id> returns one node with its embedding',
        () async {
      final res = await _get(api, 'api/memory/nodes/n_question1');
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      expect(body['id'], 'n_question1');
      expect(body['embedding'], <Object?>[0.1, 0.2, 0.3]);
      expect(conn.calledTools, <String>['memory.get']);
      expect(conn.calledArgs.single['ids'], <String>['n_question1']);
    });

    test('GET /api/memory/nodes/<unknown> is a 404', () async {
      // A store with no node for the id: memory.get returns an empty node list.
      final emptyConn = FakeReadConnection(<String, Map<String, Object?>>{
        'memory.get': <String, Object?>{'nodes': <Object?>[]},
      });
      final emptyApi =
          TrailReadApi(host: host, memory: MemoryReadClient(emptyConn));
      final res = await _get(emptyApi, 'api/memory/nodes/n_missing');
      expect(res.statusCode, 404);
    });

    test('GET /api/memory/edges?id= returns the incident edges', () async {
      final res = await _get(
          api, 'api/memory/edges?id=n_question1&direction=both');
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      final edges = (body['edges'] as List).cast<Map>();
      expect(edges.single['type'], 'satisfied_by');
      expect(conn.calledTools, <String>['memory.edgesOf']);
      expect(conn.calledArgs.single['direction'], 'both');
    });

    test('POST /api/memory/recall returns the fused list and cost report',
        () async {
      final res = await _post(
          api, 'api/memory/recall', <String, Object?>{'text': 'backup', 'k': 5});
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      expect((body['nodes'] as List), hasLength(2));
      expect((body['report'] as Map)['fusionStrategy'], 'rrf');
      expect(conn.calledTools, <String>['memory.recall']);
      expect(conn.calledArgs.single['text'], 'backup');
      expect(conn.calledArgs.single['k'], 5);
    });

    test('POST /api/memory/recall/multi carries per-node provenance', () async {
      final res = await _post(api, 'api/memory/recall/multi', <String, Object?>{
        'seeds': <Object?>[
          <String, Object?>{'mode': 'bm25', 'text': 'backup', 'weight': 1.0},
        ],
      });
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      expect((body['provenance'] as List), hasLength(1));
      expect(conn.calledTools, <String>['memory.recall.multi']);
      expect((conn.calledArgs.single['seeds'] as List), hasLength(1));
    });

    test('GET /api/memory/stacks lists the stack inventory', () async {
      final res = await _get(api, 'api/memory/stacks');
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      final stacks = (body['stacks'] as List).cast<Map>();
      expect(stacks.single['name'], 'working');
      expect(conn.calledTools, <String>['memory.stack.list']);
    });

    test('GET /api/memory/stacks/<name>?k= peeks the top-K', () async {
      final res = await _get(api, 'api/memory/stacks/working?k=5');
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      final entries = (body['entries'] as List).cast<Map>();
      expect(entries.single['nodeId'], 'n_question1');
      expect(conn.calledTools, <String>['memory.stack.peek']);
      expect(conn.calledArgs.single['name'], 'working');
      expect(conn.calledArgs.single['k'], 5);
    });

    test('POST /api/memory/classify probes the centroid classifier', () async {
      final res = await _post(api, 'api/memory/classify', <String, Object?>{
        'embedding': <double>[0.1, 0.2, 0.3],
        'target': 'nodeType',
      });
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      expect(body['decision'], 'confident');
      expect(body['bestMatch'], 'Question');
      expect(conn.calledTools, <String>['memory.classify']);
      expect(conn.calledArgs.single['target'], 'nodeType');
    });

    test('GET /api/memory/profiles lists profiles and the current binding',
        () async {
      final res = await _get(api, 'api/memory/profiles');
      expect(res.statusCode, 200);
      final body = await _jsonMap(res);
      expect(body['profiles'], <String>['default', 'eval']);
      expect(body['current'], 'default');
      expect(conn.calledTools,
          <String>['memory.profiles.list', 'memory.profile.current']);
    });

    test('OBS-2: exercising every route never calls the write tool', () async {
      await _get(api, 'api/memory/nodes?type=Question');
      await _get(api, 'api/memory/nodes/n_question1');
      await _get(api, 'api/memory/edges?id=n_question1');
      await _post(api, 'api/memory/recall', <String, Object?>{'text': 'x'});
      await _get(api, 'api/memory/stacks');
      await _get(api, 'api/memory/profiles');
      expect(conn.calledTools, isNot(contains(MemoryReadClient.writeToolName)));
      expect(conn.calledTools.toSet().difference(MemoryReadClient.readToolNames),
          isEmpty);
    });
  });

  group('PT-6 — view-scoping profile (OBS-2)', () {
    late FakeReadConnection conn;
    late TrailReadApi api;

    setUp(() {
      conn = FakeReadConnection(allReadToolStubs());
      api = TrailReadApi(host: host, memory: MemoryReadClient(conn));
    });

    test('GET /api/memory/nodes?profile= forwards the profile to every '
        'composed read', () async {
      final res = await _get(
          api, 'api/memory/nodes?type=Question&traverseEdges=true&profile=eval');
      expect(res.statusCode, 200);
      // The browse composes recall + edgesOf + get; every one carries the
      // named profile so the whole view is scoped to it (brain-side, OBS-3).
      for (final args in conn.calledArgs) {
        expect(args['profile'], 'eval');
      }
    });

    test('GET /api/memory/edges?profile= forwards the profile', () async {
      await _get(api, 'api/memory/edges?id=n_question1&profile=eval');
      expect(conn.calledTools, <String>['memory.edgesOf']);
      expect(conn.calledArgs.single['profile'], 'eval');
    });

    test('POST /api/memory/recall with a "profile" body field forwards it',
        () async {
      await _post(api, 'api/memory/recall',
          <String, Object?>{'text': 'backup', 'profile': 'eval'});
      expect(conn.calledArgs.single['profile'], 'eval');
    });

    test('GET /api/memory/stacks/<name>?profile= forwards the profile',
        () async {
      await _get(api, 'api/memory/stacks/working?k=5&profile=eval');
      expect(conn.calledArgs.single['profile'], 'eval');
    });

    test('a read without ?profile= carries no profile argument', () async {
      await _get(api, 'api/memory/edges?id=n_question1');
      expect(conn.calledArgs.single.containsKey('profile'), isFalse);
    });

    test('view-scoping never reaches the write tool (OBS-2)', () async {
      await _get(api, 'api/memory/nodes?type=Question&profile=eval');
      await _post(api, 'api/memory/recall',
          <String, Object?>{'text': 'x', 'profile': 'eval'});
      expect(conn.calledTools, isNot(contains(MemoryReadClient.writeToolName)));
    });
  });

  group('PT-6 — deferred connector (no client wired)', () {
    final api = TrailReadApi(host: host); // memory: null

    Future<void> expectUnavailable(Response res) async {
      expect(res.statusCode, 503);
      final body = await _jsonMap(res);
      expect(body['error'], 'memory unavailable');
    }

    test('every /api/memory route answers 503 memory unavailable', () async {
      await expectUnavailable(await _get(api, 'api/memory/nodes?type=Question'));
      await expectUnavailable(await _get(api, 'api/memory/nodes/n_question1'));
      await expectUnavailable(await _get(api, 'api/memory/edges?id=n1'));
      await expectUnavailable(
          await _post(api, 'api/memory/recall', <String, Object?>{'text': 'x'}));
      await expectUnavailable(await _post(
          api, 'api/memory/recall/multi', <String, Object?>{'seeds': <Object?>[]}));
      await expectUnavailable(await _get(api, 'api/memory/stacks'));
      await expectUnavailable(await _get(api, 'api/memory/stacks/working'));
      await expectUnavailable(await _post(
          api, 'api/memory/classify', <String, Object?>{'embedding': <double>[]}));
      await expectUnavailable(await _get(api, 'api/memory/profiles'));
    });

    test('the Module-1 trail surface still works without memory', () async {
      final res = await _get(api, 'api/traces');
      expect(res.statusCode, 200);
    });
  });

  group('PT-6 — a closed MCP session degrades to 503, never 500', () {
    // The route contract (§ 8.4): /api/memory/* never 500s. A bare StateError
    // from a closed json_rpc_2 client (the session dropping under a call) must
    // still surface as "memory unavailable", not a raw Internal Server Error.
    final api = TrailReadApi(
      host: host,
      memory: MemoryReadClient(_ClosedSessionConnection()),
    );

    Future<void> expectDegraded(Response res) async {
      expect(res.statusCode, 503);
      final body = await _jsonMap(res);
      expect(body['error'], startsWith('memory read failed'));
    }

    test('GET /api/memory/profiles on a closed session is a 503', () async {
      await expectDegraded(await _get(api, 'api/memory/profiles'));
    });

    test('GET /api/memory/stacks on a closed session is a 503', () async {
      await expectDegraded(await _get(api, 'api/memory/stacks'));
    });

    test('POST /api/memory/recall on a closed session is a 503', () async {
      await expectDegraded(
          await _post(api, 'api/memory/recall', <String, Object?>{'text': 'x'}));
    });
  });
}
