// A.77 — MCP tools conformance tests.
//
// What this file locks (the three explicit plan-line tests):
//
//   1. End-to-end MCP roundtrip in-process — each of the seven v1
//      tools registered by `registerMemoryTools` is reachable through
//      the protocol surface, the argument shapes are honoured, and
//      the result shapes round-trip through JSON.
//   2. Forbidden-write rejection (`McpWriteForbidden`) — calling
//      `memory.persistNote` with a NodeType outside
//      [allowedPersistNoteTypeNames] returns a
//      `CallToolResult(isError: true, ...)` whose text identifies the
//      rejected type AND the underlying memory store is *never*
//      called. (Defence-in-depth: the rejection happens before the
//      wrapper touches `TomBrainMemory.persist`.)
//   3. Read-only tools return correctly without auth header
//      configured for read-allowed mode — the server constructed
//      without an authenticator (anonymous mode) accepts the
//      handshake without a token AND every read-only tool returns
//      its canned result successfully.
//
// What this file additionally locks (forced by the seven tools
// landing in the same step — see Q-A.77.1):
//
//   - The skeleton-vs-wired distinction: a server constructed
//     without the optional `memory` argument continues to advertise
//     an empty tool list (preserves the A.75 contract); a server
//     constructed *with* `memory` lists exactly the seven v1 tool
//     names.
//   - Producer attribution on `memory.persistNote`:
//     `mcp:anonymous` when no authenticator is configured;
//     `mcp:<username>` when an authenticated principal is cached.
//     (Q-A.77.3 contract.)
//   - Argument-validation errors flow through `isError: true`
//     rather than raising RPC exceptions (matches dart_mcp
//     guidance; Q-A.77.2 rationale).
//
// What this file does NOT lock:
//
//   - The behaviour of the real `SqliteTomBrainMemory` store
//     (already covered by A.31 – A.74 tests); the wrapper layer is
//     a marshalling shim and is tested against an in-test fake.
//     See Q-A.77.5.
//   - Per-tool authorisation (role / entitlement checks against
//     `server.principal`) — A.77 only tags writes with the
//     principal name; A.85+ adds the entitlement table.
//
// Test driving pattern mirrors `a75_mcp_server_skeleton_test.dart`
// and `a76_bearer_auth_test.dart`: in-memory `StreamChannel<String>`
// pair so the test runs against a real `MCPClient` connection in the
// same isolate. Eager construction in the `_TestEnv` constructor
// body (NOT `late final`) is required — `late final` initialisation
// is lazy and the client can start `initialize` before the server is
// listening, causing the handshake to time out at 30 s.

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, Vec;
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomPrincipal, TomUser;

void main() {
  group('A.77 MCP tools — registration shape', () {
    test('without memory, listTools is empty (skeleton shape preserved)',
        () async {
      final env = _TestEnv();
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final list = await env.serverConnection.listTools();
      expect(list.tools, isEmpty);
    });

    test('with memory, listTools advertises exactly the ten v1 tools',
        () async {
      final fake = _FakeMemory();
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final list = await env.serverConnection.listTools();
      final names = list.tools.map((t) => t.name).toSet();
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
      // Closed set: the spec § 3.2 contract is a closed ten-tool
      // surface (H.28 added the three profile/multi-recall read tools).
      // Any additional tool registered through `registerMemoryTools`
      // would be a silent extension and would break this assertion.
      expect(names, hasLength(10));
    });
  });

  group('A.77 MCP tools — end-to-end roundtrip (in-process)', () {
    test('memory.recall forwards arguments and decodes the result', () async {
      final canned = RecallResult(
        nodes: [_node('0001', 'Question')],
        report: const RecallReport(
          candidatesPerMode: {RecallMode.bm25: 1},
          fusionStrategy: FusionStrategy.rrf,
          diversityStrategy: DiversityStrategy.mmr,
          diversityLambda: 0.7,
          elapsedMs: 5,
        ),
      );
      final fake = _FakeMemory()..nextRecallResult = canned;
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: {
            'text': 'why does the sky shine blue',
            'modes': ['bm25'],
            'k': 5,
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final payload = _decode(result);
      expect((payload['nodes'] as List), hasLength(1));
      expect(
        (payload['report'] as Map)['fusionStrategy'],
        equals('rrf'),
      );
      // Argument shape landed on the right call.
      expect(fake.recallCalls, hasLength(1));
      expect(fake.recallCalls.single.text, equals('why does the sky shine blue'));
      expect(fake.recallCalls.single.k, equals(5));
      expect(fake.recallCalls.single.modes, equals({RecallMode.bm25}));
    });

    test('memory.get fetches nodes by id', () async {
      final fake = _FakeMemory()
        ..nextGetManyResult = [
          _node('0001', 'Claim'),
          _node('0002', 'Question'),
        ];
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.get',
          arguments: {
            'ids': [_nodeId('0001').value, _nodeId('0002').value],
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final nodes = _decode(result)['nodes'] as List;
      expect(nodes, hasLength(2));
      expect((nodes[0] as Map)['typeName'], equals('Claim'));
      expect(fake.getManyCalls.single.map((id) => id.value).toList(),
          equals([_nodeId('0001').value, _nodeId('0002').value]));
    });

    test('memory.edgesOf parses direction and edge-type filters', () async {
      final fake = _FakeMemory()
        ..nextEdgesOfResult = [
          Edge(
            id: EdgeId.fromString('e_${_ulid('0001')}'),
            from: NodeId.fromString('n_${_ulid('0001')}'),
            type: EdgeType.mentions,
            to: NodeId.fromString('n_${_ulid('0002')}'),
          ),
        ];
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.edgesOf',
          arguments: {
            'id': 'n_${_ulid('0001')}',
            'direction': 'outgoing',
            'types': ['mentions', 'derived_from'],
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final edges = _decode(result)['edges'] as List;
      expect(edges, hasLength(1));
      expect((edges[0] as Map)['type'], equals('mentions'));
      // Argument shape landed.
      final call = fake.edgesOfCalls.single;
      expect(call.id.value, equals('n_${_ulid('0001')}'));
      expect(call.direction, equals(EdgeDirection.outgoing));
      expect(
        call.types,
        equals({EdgeType.mentions, EdgeType.derivedFrom}),
      );
    });

    test('memory.stack.list returns the stack inventory', () async {
      final fake = _FakeMemory();
      fake.stacks.nextListResult = [
        const StackSummary(
          name: 'questions_open',
          size: 3,
          topPriority: 0.9,
          bootstrap: true,
        ),
      ];
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(name: 'memory.stack.list'),
      );

      expect(result.isError, isNot(isTrue));
      final stacks = _decode(result)['stacks'] as List;
      expect(stacks, hasLength(1));
      expect((stacks[0] as Map)['name'], equals('questions_open'));
      expect((stacks[0] as Map)['bootstrap'], isTrue);
      expect(fake.stacks.listCalls, equals(1));
    });

    test('memory.stack.peek forwards name and k', () async {
      final fake = _FakeMemory();
      fake.stacks.nextPeekResult = [
        StackEntry(
          id: StackEntryId.fromString('se_${_ulid('0001')}'),
          stackName: 'questions_open',
          nodeId: NodeId.fromString('n_${_ulid('0001')}'),
          priority: 0.75,
          pushedAt: DateTime.utc(2026, 5, 31, 12, 0, 0),
        ),
      ];
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.stack.peek',
          arguments: {'name': 'questions_open', 'k': 4},
        ),
      );

      expect(result.isError, isNot(isTrue));
      final entries = _decode(result)['entries'] as List;
      expect(entries, hasLength(1));
      expect((entries[0] as Map)['priority'], equals(0.75));
      final call = fake.stacks.peekCalls.single;
      expect(call.name, equals('questions_open'));
      expect(call.k, equals(4));
    });

    test('memory.classify parses target and embedding', () async {
      final fake = _FakeMemory()
        ..nextClassifyResult = const ClassificationResult(
          decision: ClassificationDecision.confident,
          bestMatch: 'Question',
          bestSimilarity: 0.92,
          secondSimilarity: 0.41,
        );
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.classify',
          arguments: {
            'embedding': [0.1, 0.2, 0.3],
            'target': 'nodeType',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final payload = _decode(result);
      expect(payload['decision'], equals('confident'));
      expect(payload['bestMatch'], equals('Question'));
      expect(fake.classifyCalls, hasLength(1));
      expect(fake.classifyCalls.single.target,
          equals(ClassificationTarget.nodeType));
      expect(fake.classifyCalls.single.embedding.dimension, equals(3));
    });

    test('memory.persistNote tags producer mcp:anonymous in anonymous mode',
        () async {
      final fake = _FakeMemory()
        ..nextPersistResult = NodeId.fromString('n_${_ulid('aaaa')}');
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.persistNote',
          arguments: {
            'typeName': 'Question',
            'values': {'text': 'why?'},
            'idempotencyKey': 'idem-1',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      expect(_decode(result)['nodeId'], equals('n_${_ulid('aaaa')}'));

      final call = fake.persistCalls.single;
      expect(call.draft.typeName, equals('Question'));
      expect(call.draft.values, equals({'text': 'why?'}));
      expect(call.scope.producer, equals('mcp:anonymous'));
      expect(call.scope.idempotencyKey, equals('idem-1'));
    });

    test('memory.persistNote tags producer mcp:<username> when authenticated',
        () async {
      final fake = _FakeMemory()
        ..nextPersistResult = NodeId.fromString('n_${_ulid('bbbb')}');
      final env = _TestEnv(
        memory: fake,
        authenticator: StaticBearerTokenAuthenticator({
          'valid-token': TomPrincipal(
            authenticated: true,
            user: TomUser(username: 'alice'),
          ),
        }),
      );
      addTearDown(env.shutdown);

      await env.initializeHandshake(bearerToken: 'valid-token');
      await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.persistNote',
          arguments: {
            'typeName': 'Claim',
            'values': {'subject': 'the sky'},
          },
        ),
      );
      expect(fake.persistCalls.single.scope.producer,
          equals('mcp:alice'));
    });
  });

  group('A.77 MCP tools — forbidden-write rejection (McpWriteForbidden)', () {
    test('persistNote with non-allowed NodeType returns isError + does not '
        'touch memory', () async {
      final fake = _FakeMemory();
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);

      await env.initializeHandshake();
      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.persistNote',
          arguments: {
            'typeName': 'Event',
            'values': {'when': 'now'},
          },
        ),
      );

      expect(result.isError, isTrue);
      final text = (result.content.first as mcp_server.TextContent).text;
      expect(text, contains('McpWriteForbidden'));
      expect(text, contains('"Event"'));
      // Listed permitted set: defence-in-depth.
      expect(text, contains('Claim'));
      expect(text, contains('Question'));
      expect(text, contains('AutomationIdea'));
      expect(text, contains('InterestItem'));
      // Hard invariant: a forbidden write must never reach the
      // underlying memory store.
      expect(fake.persistCalls, isEmpty,
          reason: 'forbidden NodeType must short-circuit before persist().');
    });

    test('all four allowed NodeType names are accepted', () async {
      for (final typeName in allowedPersistNoteTypeNames) {
        final fake = _FakeMemory()
          ..nextPersistResult = NodeId.fromString('n_${_ulid('cccc')}');
        final env = _TestEnv(memory: fake);
        addTearDown(env.shutdown);

        await env.initializeHandshake();
        final result = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(
            name: 'memory.persistNote',
            arguments: {
              'typeName': typeName,
              'values': {'k': 'v'},
            },
          ),
        );
        expect(result.isError, isNot(isTrue),
            reason: '"$typeName" must be accepted (allow-list member).');
        expect(fake.persistCalls.single.draft.typeName, equals(typeName));
        await env.shutdown();
      }
    });

    test('McpWriteForbidden + allowedPersistNoteTypeNames reach via the '
        'package barrel', () {
      // Identifier-existence check: consumers importing only
      // `package:tom_brain_memory/tom_brain_memory.dart` must be
      // able to inspect the closed set and reference the exception
      // class for custom error handling on the Dart side.
      expect(allowedPersistNoteTypeNames, hasLength(4));
      expect(
        allowedPersistNoteTypeNames,
        equals({'Claim', 'Question', 'AutomationIdea', 'InterestItem'}),
      );
      const ex = McpWriteForbidden(requestedTypeName: 'Event');
      expect(ex.toString(), contains('Event'));
      expect(ex.allowedTypeNames, equals(allowedPersistNoteTypeNames));
    });
  });

  group(
    'A.77 MCP tools — read-only tools work without auth header configured',
    () {
      // The plan-line clause is "read-only tools return correctly
      // without auth header configured for read-allowed mode". The
      // read-allowed mode is the anonymous-server shape (no
      // authenticator wired); the assertion is that every read tool
      // returns a non-error result without the client supplying a
      // bearer token.
      late _FakeMemory fake;
      late _TestEnv env;

      setUp(() async {
        fake = _FakeMemory()
          ..nextRecallResult = RecallResult(
            nodes: [_node('0001', 'Claim')],
            report: const RecallReport(
              candidatesPerMode: {RecallMode.bm25: 1},
              fusionStrategy: FusionStrategy.rrf,
              diversityStrategy: DiversityStrategy.mmr,
              diversityLambda: 0.7,
              elapsedMs: 1,
            ),
          )
          ..nextGetManyResult = [_node('0002', 'Question')]
          ..nextEdgesOfResult = const []
          ..nextClassifyResult =
              const ClassificationResult.unknown();
        fake.stacks.nextListResult = const [];
        fake.stacks.nextPeekResult = const [];

        env = _TestEnv(memory: fake);
        addTearDown(env.shutdown);
        // No bearerToken passed — read-allowed anonymous mode.
        await env.initializeHandshake();
      });

      test('memory.recall returns a result without an auth header', () async {
        final r = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(
            name: 'memory.recall',
            arguments: {'text': 'q', 'modes': ['bm25']},
          ),
        );
        expect(r.isError, isNot(isTrue));
        expect((_decode(r)['nodes'] as List), hasLength(1));
      });

      test('memory.get returns a result without an auth header', () async {
        final r = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(
            name: 'memory.get',
            arguments: {
              'ids': [_nodeId('0002').value],
            },
          ),
        );
        expect(r.isError, isNot(isTrue));
        expect((_decode(r)['nodes'] as List), hasLength(1));
      });

      test('memory.edgesOf returns a result without an auth header', () async {
        final r = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(
            name: 'memory.edgesOf',
            arguments: {'id': 'n_${_ulid('0001')}'},
          ),
        );
        expect(r.isError, isNot(isTrue));
        expect((_decode(r)['edges'] as List), isEmpty);
      });

      test('memory.stack.list returns a result without an auth header',
          () async {
        final r = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(name: 'memory.stack.list'),
        );
        expect(r.isError, isNot(isTrue));
        expect((_decode(r)['stacks'] as List), isEmpty);
      });

      test('memory.stack.peek returns a result without an auth header',
          () async {
        final r = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(
            name: 'memory.stack.peek',
            arguments: {'name': 'questions_open'},
          ),
        );
        expect(r.isError, isNot(isTrue));
        expect((_decode(r)['entries'] as List), isEmpty);
      });

      test('memory.classify returns a result without an auth header',
          () async {
        final r = await env.serverConnection.callTool(
          mcp_server.CallToolRequest(
            name: 'memory.classify',
            arguments: {
              'embedding': [0.0, 0.0, 0.0],
            },
          ),
        );
        expect(r.isError, isNot(isTrue));
        expect(_decode(r)['decision'], equals('unknown'));
      });
    },
  );

  group('A.77 MCP tools — argument-validation errors', () {
    test('memory.get with non-string id rejects via isError', () async {
      final fake = _FakeMemory();
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);
      await env.initializeHandshake();

      final r = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.get',
          arguments: {
            'ids': [42],
          },
        ),
      );
      // dart_mcp's ToolsSupport validates the inputSchema before
      // the handler runs; an integer in a string-typed array is a
      // schema violation. Either way (schema or handler), it must
      // surface as isError — never as RPC failure or silent OK.
      expect(r.isError, isTrue);
      expect(fake.getManyCalls, isEmpty);
    });

    test('memory.classify with missing embedding rejects via isError',
        () async {
      final fake = _FakeMemory();
      final env = _TestEnv(memory: fake);
      addTearDown(env.shutdown);
      await env.initializeHandshake();

      final r = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.classify',
          arguments: {},
        ),
      );
      expect(r.isError, isTrue);
      expect(fake.classifyCalls, isEmpty);
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────

Map<String, Object?> _decode(mcp_server.CallToolResult result) {
  final text = (result.content.first as mcp_server.TextContent).text;
  return jsonDecode(text) as Map<String, Object?>;
}

Node _node(String tail, String typeName) {
  return Node(
    id: _nodeId(tail),
    typeName: typeName,
    values: const {'k': 'v'},
    createdAt: DateTime.utc(2026, 5, 31, 12, 0, 0),
  );
}

/// Builds a deterministic [NodeId] of the form
/// `n_<22-char filler><4-char sanitised tail>`. The tail is upper-cased,
/// stripped of any character outside the Crockford base-32 alphabet,
/// right-padded with `0`s to four characters, and prepended with a
/// 22-char filler so the payload is exactly 26 characters long
/// (the ULID length the shared validator enforces).
NodeId _nodeId(String tail) => NodeId.fromString('n_${_ulid(tail)}');

String _ulid(String tail) {
  const filler = '0000000000000000000000';
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  final upper = tail.toUpperCase();
  final buf = StringBuffer();
  for (var i = 0; i < upper.length && buf.length < 4; i++) {
    final ch = upper[i];
    if (alphabet.contains(ch)) buf.write(ch);
  }
  final safeTail = buf.toString().padLeft(4, '0');
  return filler + safeTail;
}

// ─── Fakes ────────────────────────────────────────────────────────

class _RecallCall {
  final String? text;
  final int k;
  final Set<RecallMode> modes;
  _RecallCall(this.text, this.k, this.modes);
}

class _EdgesOfCall {
  final NodeId id;
  final EdgeDirection direction;
  final Set<EdgeType>? types;
  _EdgesOfCall(this.id, this.direction, this.types);
}

class _ClassifyCall {
  final Vec embedding;
  final ClassificationTarget target;
  _ClassifyCall(this.embedding, this.target);
}

class _PersistCall {
  final NodeDraft draft;
  final Scope scope;
  _PersistCall(this.draft, this.scope);
}

class _PeekCall {
  final String name;
  final int k;
  _PeekCall(this.name, this.k);
}

/// Hand-rolled fake implementing every `TomBrainMemory` method —
/// the seven tool handlers cover the read+persist surface; every
/// other method throws `UnimplementedError` because the wrapper
/// layer must not reach for them. See Q-A.77.5 for the rationale
/// (test-pyramid: wrapper layer gets a fake; store layer gets the
/// real SQLite implementation in A.31 – A.74).
class _FakeMemory implements TomBrainMemory {
  final recallCalls = <_RecallCall>[];
  RecallResult? nextRecallResult;

  final getManyCalls = <List<NodeId>>[];
  List<Node> nextGetManyResult = const [];

  final edgesOfCalls = <_EdgesOfCall>[];
  List<Edge> nextEdgesOfResult = const [];

  final classifyCalls = <_ClassifyCall>[];
  ClassificationResult nextClassifyResult =
      const ClassificationResult.unknown();

  final persistCalls = <_PersistCall>[];
  NodeId? nextPersistResult;

  @override
  final _FakeStackApi stacks = _FakeStackApi();

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallCalls.add(_RecallCall(query.text, query.k, query.modes));
    return nextRecallResult ??
        RecallResult(
          nodes: const [],
          report: const RecallReport(
            candidatesPerMode: {},
            fusionStrategy: FusionStrategy.rrf,
            diversityStrategy: DiversityStrategy.mmr,
            elapsedMs: 0,
          ),
        );
  }

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async {
    getManyCalls.add(ids);
    return nextGetManyResult;
  }

  @override
  Future<List<Edge>> edgesOf(
    NodeId id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<EdgeType>? types,
  }) async {
    edgesOfCalls.add(_EdgesOfCall(id, direction, types));
    return nextEdgesOfResult;
  }

  @override
  Future<ClassificationResult> classify(
    Vec embedding, {
    ClassificationTarget target = ClassificationTarget.nodeType,
  }) async {
    classifyCalls.add(_ClassifyCall(embedding, target));
    return nextClassifyResult;
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    persistCalls.add(_PersistCall(draft, scope));
    return nextPersistResult ??
        NodeId.fromString('n_${_ulid('0000')}');
  }

  // Every other method is out of A.77's contract surface; the tests
  // never reach for them, so they raise to make the boundary explicit.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeMemory does not implement ${invocation.memberName}; '
      'A.77 tools only exercise recall / getMany / edgesOf / classify / '
      'persist + the stacks getter.',
    );
  }
}

class _FakeStackApi implements StackApi {
  int listCalls = 0;
  List<StackSummary> nextListResult = const [];

  final peekCalls = <_PeekCall>[];
  List<StackEntry> nextPeekResult = const [];

  @override
  Future<List<StackSummary>> list() async {
    listCalls++;
    return nextListResult;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    peekCalls.add(_PeekCall(name, k));
    return nextPeekResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeStackApi does not implement ${invocation.memberName}; '
      'A.77 only exercises list and peek.',
    );
  }
}

/// In-isolate test environment. Mirrors A.75 / A.76 — eager
/// construction in the constructor body (NOT `late final`) is
/// required so the server is listening before the client starts
/// the handshake.
class _TestEnv {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  late final StreamChannel<String> clientChannel;
  late final StreamChannel<String> serverChannel;
  late final mcp_client.MCPClient client;
  late final TomBrainMemoryMcpServer server;
  late final mcp_client.ServerConnection serverConnection;

  _TestEnv({
    BearerTokenAuthenticator? authenticator,
    TomBrainMemory? memory,
  }) {
    clientChannel = StreamChannel<String>.withCloseGuarantee(
      serverController.stream,
      clientController.sink,
    );
    serverChannel = StreamChannel<String>.withCloseGuarantee(
      clientController.stream,
      serverController.sink,
    );
    client = _TestMcpClient();
    server = TomBrainMemoryMcpServer(
      serverChannel,
      authenticator: authenticator,
      memory: memory,
    );
    serverConnection = client.connectServer(clientChannel);
  }

  Future<mcp_server.InitializeResult> initializeHandshake({
    mcp_server.ProtocolVersion protocolVersion =
        mcp_server.ProtocolVersion.latestSupported,
    String? bearerToken,
  }) async {
    final meta = bearerToken == null
        ? null
        : mcp_server.MetaWithProgressToken.fromMap({
            bearerTokenMetaKey: bearerToken,
          });
    final result = await serverConnection.initialize(
      mcp_server.InitializeRequest(
        protocolVersion: protocolVersion,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
        meta: meta,
      ),
    );
    if (result.protocolVersion?.isSupported == true) {
      serverConnection.notifyInitialized(mcp_server.InitializedNotification());
      await server.initialized;
    }
    return result;
  }

  Future<void> shutdown() async {
    await client.shutdown();
    await server.shutdown();
  }
}

base class _TestMcpClient extends mcp_client.MCPClient {
  _TestMcpClient()
      : super(
          mcp_client.Implementation(name: 'a77-test-client', version: '0.0.1'),
        );
}

