// Per-profile MCP read isolation against a REAL SqliteTomBrainMemory
// (memory_session_profiles_followup.md item #9 / spec § 8.4 / D-7; plan
// Deferred G-2). This is the end-to-end Done-when test for "a profile-scoped
// MCP query reads that profile's store" that neither existing test covers on
// its own:
//
//   * `profile_scoped_read_test.dart` proves the MCP read tools *route*
//     through `readInProfile`, but against in-memory fakes — it never opens a
//     second physical SQLite database, so it cannot prove the read actually
//     lands in a different store.
//   * `h27_memory_profiles_test.dart` proves real-store isolation, but by
//     opening profile-bound stores *directly* (`openProfile`) — it bypasses
//     the MCP server's `readInProfile` view-scoping seam, so it cannot prove
//     an MCP query reaches the other store.
//
// This test closes that gap end-to-end: one real parent store bound to the
// default (unbound) profile, a second profile seeded with disjoint content,
// the live `TomBrainMemoryMcpServer` over an in-isolate MCP wire, and the
// three Done-when assertions:
//
//   1. `memory.recall` with `profile: '<other>'` reads the OTHER profile's
//      physical store (returns its content, never the default's).
//   2. `memory.recall` WITHOUT `profile` reads the bound default store
//      (unchanged — the view-scope never bled back onto the bound handle).
//   3. `memory.profiles.list` still introspects across profiles (it
//      enumerates the `<root>/profiles/` directory, not the bound handle).
//
// Like h27, the recall scenarios need the packaged vec0 binary (open() refuses
// to boot without it); they are skipped, not failed, when no binary is present
// for the running platform.

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
    show MemoryConfig, NodeDraft, Scope, Vec;

const _bootstrapDims = 768;

/// A deterministic 768-dim vector keyed by [seed] (mirrors h27 `_v768`).
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// An Event draft carrying [text] as its `summary` and a [seed]-keyed
/// embedding (mirrors h27 `_eventDraft`).
NodeDraft _eventDraft(String text, {required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': text,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-07T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

/// Locates `<workspace>/tom_binaries/sqlite_vec` (mirrors h27).
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

Map<String, Object?> _decode(mcp_server.CallToolResult result) {
  final text = (result.content.first as mcp_server.TextContent).text;
  return jsonDecode(text) as Map<String, Object?>;
}

List<String> _summaries(Map<String, Object?> decoded) =>
    (decoded['nodes'] as List)
        .map((n) => (n as Map)['values'] as Map)
        .map((v) => v['summary'] as String)
        .toList()
      ..sort();

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

  const scope = Scope(producer: 'mcp_profile_isolation:test');

  group('per-profile MCP read isolation — real SqliteTomBrainMemory', () {
    test('a profile-scoped MCP recall reads the named profile\'s store; the '
        'default is unchanged; profiles.list still enumerates all profiles',
        () async {
      final root = Directory.systemTemp
          .createTempSync('tbm_mcp_profile_iso_')
          .path;
      addTearDown(() {
        final dir = Directory(root);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      // Parent store bound to the default (unbound) profile.
      final parent = SqliteTomBrainMemory();
      await parent
          .open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!));
      addTearDown(parent.close);

      // Default store gets "alpha"; profile 'eval_b' gets a disjoint "beta".
      await parent.persist(
        _eventDraft('alpha defaultword only', seed: 1),
        scope: scope,
      );
      await parent.profiles.createProfile('eval_b');
      await parent.profiles.seedProfile(
        'eval_b',
        [_eventDraft('beta profileword only', seed: 2)],
        scope: scope,
      );

      final env = _TestEnv(memory: parent);
      addTearDown(env.shutdown);
      await env.initializeHandshake();

      // (1) Profile-scoped recall reads eval_b's physical store.
      final scoped = _decode(await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: {
            'text': 'profileword',
            'modes': ['bm25'],
            'profile': 'eval_b',
          },
        ),
      ));
      expect(_summaries(scoped), equals(['beta profileword only']),
          reason: 'the profile-scoped MCP query must read eval_b\'s store');

      // The default store has no "profileword" — confirms no cross-talk.
      final scopedNeg = _decode(await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: {
            'text': 'defaultword',
            'modes': ['bm25'],
            'profile': 'eval_b',
          },
        ),
      ));
      expect(_summaries(scopedNeg), isEmpty,
          reason: 'eval_b must not see the default profile\'s content');

      // (2) Unscoped recall reads the bound default store, unchanged.
      final bound = _decode(await env.serverConnection.callTool(
        mcp_server.CallToolRequest(
          name: 'memory.recall',
          arguments: {
            'text': 'defaultword',
            'modes': ['bm25'],
          },
        ),
      ));
      expect(_summaries(bound), equals(['alpha defaultword only']),
          reason: 'the bound (default) handle is unaffected by view-scoping');

      // (3) profiles.list still introspects across profiles.
      final profiles = _decode(await env.serverConnection.callTool(
        mcp_server.CallToolRequest(name: 'memory.profiles.list'),
      ));
      expect((profiles['profiles'] as List).cast<String>(),
          contains('eval_b'),
          reason: 'memory.profiles.list enumerates the profiles directory');
    }, skip: skipNoBinary);
  });
}

/// In-isolate MCP environment — mirrors `profile_scoped_read_test.dart`.
class _TestEnv {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  late final StreamChannel<String> clientChannel;
  late final StreamChannel<String> serverChannel;
  late final mcp_client.MCPClient client;
  late final TomBrainMemoryMcpServer server;
  late final mcp_client.ServerConnection serverConnection;

  _TestEnv({required TomBrainMemory memory}) {
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
            name: 'mcp-profile-isolation-test-client',
            version: '0.0.1',
          ),
        );
}
