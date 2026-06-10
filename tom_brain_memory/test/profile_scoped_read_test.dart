// Profile-scoped read routing for the MCP read tools (OBS-2 /
// observatory view-scoping — `prompt_tracing.md` §5.6, `tom_brain_completion_plan_2.md` item #4).
//
// What this file locks:
//
//   1. A read tool called with `profile: '<other>'` (≠ the bound
//      profile) is answered through `memory.profiles.readInProfile(
//      '<other>', body)` — a transient *read* handle on the named
//      profile — and the result comes from that profile's view, NOT
//      the bound handle. This is the brain-side view-scoping the
//      observatory profile switcher relies on (OBS-3: the app never
//      touches DB files, so the scoping must happen here).
//
//   2. The same tool called WITHOUT `profile` (or with `profile`
//      equal to the bound `currentProfile`) reads the bound handle
//      directly and never calls `readInProfile`.
//
//   3. View-scoping is read-only: routing goes exclusively through
//      `readInProfile` (a read seam by contract) — `memory.profile.set`
//      is never invoked (OBS-2: switching the *view* must never switch
//      the *brain*). The fake's `profiles` registry implements only
//      `readInProfile`; any `set`/write call would raise.
//
// Test driving pattern mirrors `a77_mcp_tools_test.dart`: in-memory
// `StreamChannel<String>` pair so the test runs against a real
// `MCPClient` connection in the same isolate, with eager construction
// in the `_TestEnv` constructor body (see a77 for the rationale).

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, TomBrainMemoryClient;

void main() {
  group('profile-scoped MCP reads — view-scoping via readInProfile', () {
    test('memory.recall with profile routes through readInProfile and reads '
        'the named profile', () async {
      final profiledView = _ProfileFakeMemory(label: 'ProfiledAnswer');
      final base = _ProfileFakeMemory(
        label: 'BaseAnswer',
        profiledView: profiledView,
      );
      final env = _TestEnv(memory: base);
      addTearDown(env.shutdown);
      await env.initializeHandshake();

      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: {
            'text': 'q',
            'modes': ['bm25'],
            'profile': 'other',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final nodes = _decode(result)['nodes'] as List;
      // The answer came from the profile-scoped view, not the bound handle.
      expect((nodes.single as Map)['typeName'], equals('ProfiledAnswer'));
      // The brain-side view-scoping seam was used with the named profile.
      expect(base.registry.readInProfileNames, equals(['other']));
      // The bound handle's recall was bypassed; the profiled view answered.
      expect(base.recallCalls, isEmpty);
      expect(profiledView.recallCalls, hasLength(1));
    });

    test('memory.recall without profile reads the bound handle directly',
        () async {
      final profiledView = _ProfileFakeMemory(label: 'ProfiledAnswer');
      final base = _ProfileFakeMemory(
        label: 'BaseAnswer',
        profiledView: profiledView,
      );
      final env = _TestEnv(memory: base);
      addTearDown(env.shutdown);
      await env.initializeHandshake();

      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: {
            'text': 'q',
            'modes': ['bm25'],
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final nodes = _decode(result)['nodes'] as List;
      expect((nodes.single as Map)['typeName'], equals('BaseAnswer'));
      expect(base.registry.readInProfileNames, isEmpty);
      expect(base.recallCalls, hasLength(1));
      expect(profiledView.recallCalls, isEmpty);
    });

    test('memory.recall with profile equal to the bound profile does not '
        're-scope', () async {
      final profiledView = _ProfileFakeMemory(label: 'ProfiledAnswer');
      final base = _ProfileFakeMemory(
        label: 'BaseAnswer',
        boundProfile: 'main',
        profiledView: profiledView,
      );
      final env = _TestEnv(memory: base);
      addTearDown(env.shutdown);
      await env.initializeHandshake();

      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: {
            'text': 'q',
            'modes': ['bm25'],
            'profile': 'main',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final nodes = _decode(result)['nodes'] as List;
      expect((nodes.single as Map)['typeName'], equals('BaseAnswer'));
      expect(base.registry.readInProfileNames, isEmpty);
      expect(base.recallCalls, hasLength(1));
    });

    test('memory.get with profile fetches from the named profile', () async {
      final profiledView = _ProfileFakeMemory(label: 'ProfiledNode');
      final base = _ProfileFakeMemory(
        label: 'BaseNode',
        profiledView: profiledView,
      );
      final env = _TestEnv(memory: base);
      addTearDown(env.shutdown);
      await env.initializeHandshake();

      final result = await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.get',
          arguments: {
            'ids': [_nodeId('0001').value],
            'profile': 'other',
          },
        ),
      );

      expect(result.isError, isNot(isTrue));
      final nodes = _decode(result)['nodes'] as List;
      expect((nodes.single as Map)['typeName'], equals('ProfiledNode'));
      expect(base.registry.readInProfileNames, equals(['other']));
      expect(base.getManyCalls, isEmpty);
      expect(profiledView.getManyCalls, hasLength(1));
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────

Map<String, Object?> _decode(mcp_server.CallToolResult result) {
  final text = (result.content.first as mcp_server.TextContent).text;
  return jsonDecode(text) as Map<String, Object?>;
}

Node _node(String tail, String typeName) => Node(
      id: _nodeId(tail),
      typeName: typeName,
      values: const {'k': 'v'},
      createdAt: DateTime.utc(2026, 5, 31, 12, 0, 0),
    );

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
  return filler + buf.toString().padLeft(4, '0');
}

RecallResult _recallResultLabelled(String label) => RecallResult(
      nodes: [_node('0001', label)],
      report: const RecallReport(
        candidatesPerMode: {RecallMode.bm25: 1},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.mmr,
        diversityLambda: 0.7,
        elapsedMs: 1,
      ),
    );

// ─── Fakes ────────────────────────────────────────────────────────

/// A `TomBrainMemory` fake whose read methods tag their answers with
/// [label] so a test can tell which handle (bound vs. profile-scoped)
/// served a call. Its [profiles] registry records `readInProfile`
/// names and delegates the body to [_profiledView], standing in for a
/// transient read handle on the named profile.
class _ProfileFakeMemory implements TomBrainMemory {
  _ProfileFakeMemory({
    required this.label,
    String? boundProfile,
    TomBrainMemory? profiledView,
  }) : _boundProfile = boundProfile {
    registry = _RecordingProfileRegistry(profiledView ?? this);
  }

  final String label;
  final String? _boundProfile;
  late final _RecordingProfileRegistry registry;

  final recallCalls = <RecallQuery>[];
  final getManyCalls = <List<NodeId>>[];

  @override
  String? get currentProfile => _boundProfile;

  @override
  MemoryProfileRegistry get profiles => registry;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallCalls.add(query);
    return _recallResultLabelled(label);
  }

  @override
  Future<List<Node>> getMany(List<NodeId> ids) async {
    getManyCalls.add(ids);
    return [_node('0001', label)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_ProfileFakeMemory does not implement ${invocation.memberName}; '
        'this fake only exercises recall / getMany + currentProfile / '
        'profiles for the view-scoping routing test.',
      );
}

/// Records `readInProfile` names and runs the body against
/// [_profiledView]. It implements *only* `readInProfile` — any other
/// registry call (e.g. a write path) raises, proving the read tools
/// never reach for a write seam (OBS-2).
class _RecordingProfileRegistry implements MemoryProfileRegistry {
  _RecordingProfileRegistry(this._profiledView);

  final TomBrainMemory _profiledView;
  final readInProfileNames = <String>[];

  @override
  Future<T> readInProfile<T>(
    String name,
    Future<T> Function(TomBrainMemoryClient body) body,
  ) async {
    readInProfileNames.add(name);
    return body(_profiledView);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_RecordingProfileRegistry does not implement '
        '${invocation.memberName}; view-scoping must use readInProfile only '
        '(OBS-2: never switch the bound profile).',
      );
}

/// In-isolate test environment — mirrors `a77_mcp_tools_test.dart`.
class _TestEnv {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  late final StreamChannel<String> clientChannel;
  late final StreamChannel<String> serverChannel;
  late final mcp_client.MCPClient client;
  late final TomBrainMemoryMcpServer server;
  late final mcp_client.ServerConnection serverConnection;

  _TestEnv({TomBrainMemory? memory}) {
    clientChannel = StreamChannel<String>.withCloseGuarantee(
      serverController.stream,
      clientController.sink,
    );
    serverChannel = StreamChannel<String>.withCloseGuarantee(
      clientController.stream,
      serverController.sink,
    );
    client = _TestMcpClient();
    server = TomBrainMemoryMcpServer(serverChannel, memory: memory);
    serverConnection = client.connectServer(clientChannel);
  }

  Future<mcp_server.InitializeResult> initializeHandshake() async {
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
          mcp_client.Implementation(
            name: 'profile-scoped-test-client',
            version: '0.0.1',
          ),
        );
}
