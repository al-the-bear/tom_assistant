// H.27 — memory profiles: registry + open(profile) + admin surface.
//
// prototype_tools_mcp_extension_plan.md step 27 (Extension H):
//   "Memory profiles — registry + open(profile) + admin surface. Add the
//    <memory-root>/profiles/<name>/ tier (spec memory § 2.5): a
//    MemoryProfileRegistry (list / exists / createProfile / dropProfile /
//    seedProfile), a profile field on MemoryConfig, and
//    open(MemoryConfig{ root, profile }) scoping the whole handle (recall,
//    classify, persist, trails, stacks, MCP) to one profile. Emit
//    ProfileCreated / ProfileDropped events (memory § 16). dropProfile is a
//    whole-store delete (reset-to-zero), distinct from per-event forget, and
//    is not on the read-only MCP server."
//
// What this file locks (the plan-line *Test* + *Verify* clauses):
//
//   1. createProfile → seedProfile → recall → dropProfile → recreate →
//      recall yields identical results on the recreated profile
//      (reset-to-zero is exact).
//   2. Two profiles queried concurrently never cross-talk.
//   3. Within a profile no event is lost (every seeded node survives recall).
//   4. The registry emits ProfileCreated on create and ProfileDropped on drop
//      onto the store's `events()` feed (memory § 16).
//   5. *Verify:* the read-only MCP server exposes no create/drop/seed tool —
//      its advertised surface is exactly the closed seven read tools.
//
// Profile scoping is single-point: `MemoryDirectory.openOrCreate` resolves
// the effective root from `config.dataDir` (= `<root>` when profile is null,
// `<root>/profiles/<name>` when a profile is bound), so the whole handle —
// memory.db, vectors.db, trails/, tombstones/, checkpoints/ — lands inside
// the profile directory.
//
// The recall scenarios (1–3) need the packaged vec0 binary (open() refuses
// to boot without it — P1.1) and are skipped, not failed, when the running
// platform has no binary under tom_binaries/sqlite_vec/<platform>/. The MCP
// *Verify* scenario (4) needs no store and runs unconditionally.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeDraft, RecallMode, RecallQuery, Scope, SymbolicFilter, Vec;

/// The bootstrap embedding model dimensionality (mirrors p2_15 / p2_16).
const _bootstrapDims = 768;

/// A deterministic 768-dim vector keyed by [seed] (mirrors p2_16 `_v768`).
Vec _v768({required int seed}) {
  final values = Float32List(_bootstrapDims);
  for (var i = 0; i < _bootstrapDims; i++) {
    values[i] = ((seed * 31 + i) % 1000) / 1000.0;
  }
  return Vec(values);
}

/// Builds an Event draft carrying [text] as its `summary` and a [seed]-keyed
/// embedding. A fresh draft list is built per seed/per call so a re-seed
/// after `dropProfile` mints brand-new nodes (reset-to-zero).
NodeDraft _eventDraft(String text, {required int seed}) => NodeDraft(
      typeName: 'Event',
      values: <String, Object?>{
        'summary': text,
        'payload': const <String, Object?>{},
        'occurred_at': '2026-06-07T10:00:00.000Z',
      },
      embedding: _v768(seed: seed),
    );

/// Locates `<workspace>/tom_binaries/sqlite_vec` by walking up from the test
/// runner's CWD (mirrors p2_13 – p2_16).
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

  /// Creates a fresh memory root under the system temp dir, registers it for
  /// teardown, and returns its absolute path.
  String freshRoot() {
    final root = Directory.systemTemp.createTempSync('tbm_profiles_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return root.path;
  }

  /// Opens the profile-unbound parent store at [root] and registers teardown.
  /// Its `profiles` getter is the [MemoryProfileRegistry] under test.
  Future<SqliteTomBrainMemory> openParent(String root) async {
    final store = SqliteTomBrainMemory();
    addTearDown(store.close);
    await store.open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!));
    return store;
  }

  /// Opens a profile-bound store at `<root>/profiles/<profile>` and registers
  /// teardown. This exercises `open(MemoryConfig{ root, profile })`.
  Future<SqliteTomBrainMemory> openProfile(String root, String profile) async {
    final store = SqliteTomBrainMemory();
    addTearDown(store.close);
    await store.open(MemoryConfig.forTesting(root: root, binariesRoot: vecRoot!)
        .withProfile(profile));
    return store;
  }

  /// Opens [profile], runs a BM25 text recall, returns the matched node
  /// summaries (sorted for order-independent comparison), and closes.
  Future<List<String>> recallSummaries(
    String root,
    String profile,
    String text,
  ) async {
    final store = await openProfile(root, profile);
    final result = await store.recall(RecallQuery(
      modes: const <RecallMode>{RecallMode.bm25},
      text: text,
      k: 100,
    ));
    final summaries = result.nodes
        .map((n) => n.values['summary'] as String)
        .toList()
      ..sort();
    await store.close();
    return summaries;
  }

  const scope = Scope(producer: 'h27:test');

  group('H.27 — profile registry (reset-to-zero, isolation, no loss)', () {
    test('createProfile → seed → recall → drop → recreate → recall is '
        'identical (reset-to-zero)', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      await reg.createProfile('eval_a');
      await reg.seedProfile(
        'eval_a',
        [
          _eventDraft('alpha unique zeta', seed: 1),
          _eventDraft('beta gamma delta', seed: 2),
        ],
        scope: scope,
      );
      final first = await recallSummaries(root, 'eval_a', 'unique');
      expect(first, isNotEmpty);

      await reg.dropProfile('eval_a');
      expect(await reg.exists('eval_a'), isFalse);

      await reg.createProfile('eval_a');
      await reg.seedProfile(
        'eval_a',
        [
          _eventDraft('alpha unique zeta', seed: 1),
          _eventDraft('beta gamma delta', seed: 2),
        ],
        scope: scope,
      );
      final second = await recallSummaries(root, 'eval_a', 'unique');

      expect(second, equals(first),
          reason: 'a recreated profile is reset-to-zero and reproduces the '
              'same recall content');
    }, skip: skipNoBinary);

    test('two profiles queried concurrently never cross-talk', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      await reg.createProfile('p1');
      await reg.createProfile('p2');
      await reg.seedProfile(
        'p1',
        [_eventDraft('alpha distinctive one', seed: 10)],
        scope: scope,
      );
      await reg.seedProfile(
        'p2',
        [_eventDraft('beta distinctive two', seed: 20)],
        scope: scope,
      );

      final results = await Future.wait(<Future<List<String>>>[
        recallSummaries(root, 'p1', 'distinctive'),
        recallSummaries(root, 'p2', 'distinctive'),
      ]);

      expect(results[0], contains('alpha distinctive one'));
      expect(results[0], isNot(contains('beta distinctive two')));
      expect(results[1], contains('beta distinctive two'));
      expect(results[1], isNot(contains('alpha distinctive one')));
    }, skip: skipNoBinary);

    test('within a profile no seeded event is lost', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      await reg.createProfile('p3');
      final drafts = List.generate(
        12,
        (i) => _eventDraft('item number $i carriesword', seed: 100 + i),
      );
      await reg.seedProfile('p3', drafts, scope: scope);

      final store = await openProfile(root, 'p3');
      final result = await store.recall(const RecallQuery(
        modes: <RecallMode>{RecallMode.symbolic},
        filter: SymbolicFilter(typeNames: <String>{'Event'}),
        k: 100,
      ));

      expect(result.nodes, hasLength(12),
          reason: 'every seeded node survives within the profile');
      final summaries =
          result.nodes.map((n) => n.values['summary'] as String).toSet();
      for (var i = 0; i < 12; i++) {
        expect(summaries, contains('item number $i carriesword'));
      }
    }, skip: skipNoBinary);

    test('exists / list reflect the created profiles', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      expect(await reg.list(), isEmpty);
      expect(await reg.exists('nope'), isFalse);

      await reg.createProfile('one');
      await reg.createProfile('two');
      expect((await reg.list())..sort(), equals(<String>['one', 'two']));
      expect(await reg.exists('one'), isTrue);

      await reg.dropProfile('one');
      expect(await reg.list(), equals(<String>['two']));
    }, skip: skipNoBinary);

    test('createProfile is idempotent; dropProfile of an absent profile is a '
        'no-op', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      await reg.createProfile('again');
      await reg.createProfile('again'); // must not throw
      expect(await reg.exists('again'), isTrue);

      await reg.dropProfile('ghost'); // absent: no-op, must not throw
      expect(await reg.exists('ghost'), isFalse);
    }, skip: skipNoBinary);

    test('a path-traversing profile name is rejected', () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      expect(() => reg.createProfile('../escape'),
          throwsA(isA<ArgumentError>()));
      expect(() => reg.createProfile('a/b'), throwsA(isA<ArgumentError>()));
      expect(() => reg.createProfile(''), throwsA(isA<ArgumentError>()));
    }, skip: skipNoBinary);

    test('ProfileCreated / ProfileDropped land on the store events() feed',
        () async {
      final root = freshRoot();
      final parent = await openParent(root);
      final reg = parent.profiles;

      final created = <String>[];
      final dropped = <String>[];
      final sub = parent.events().listen((e) {
        if (e is ProfileCreated) created.add(e.profileName);
        if (e is ProfileDropped) dropped.add(e.profileName);
      });
      addTearDown(sub.cancel);

      await reg.createProfile('events_a');
      await reg.dropProfile('events_a');

      // The bus is asynchronous (sync: false); let the microtask/event loop
      // drain before asserting.
      await Future<void>.delayed(Duration.zero);

      expect(created, contains('events_a'));
      expect(dropped, contains('events_a'));
    }, skip: skipNoBinary);
  });

  group('H.27 — *Verify*: read-only MCP server exposes no profile admin', () {
    test('the advertised tool surface is exactly the closed seven read tools '
        '— no create/drop/seed', () async {
      final env = _McpEnv(memory: _ProfilelessFakeMemory());
      addTearDown(env.shutdown);

      await env.initialize();
      final list = await env.connection.listTools();
      final names = list.tools.map((t) => t.name).toSet();

      // No profile-admin tool is reachable over the read-only surface.
      final adminLike = names.where((n) {
        final lower = n.toLowerCase();
        return lower.contains('profile') ||
            lower.contains('create') ||
            lower.contains('drop') ||
            lower.contains('seed');
      });
      expect(adminLike, isEmpty,
          reason: 'profile create/drop/seed must never be on the read-only '
              'MCP server (memory § 2.5 / § 3.2)');

      // And the surface is exactly the closed seven read tools.
      expect(
        names,
        equals(<String>{
          'memory.recall',
          'memory.get',
          'memory.edgesOf',
          'memory.stack.list',
          'memory.stack.peek',
          'memory.classify',
          'memory.persistNote',
        }),
      );
    });
  });
}

/// Minimal in-isolate MCP environment (mirrors a77's `_TestEnv`) used only to
/// list the advertised tool surface. Eager construction in the constructor
/// body is required so the server is listening before the handshake starts.
class _McpEnv {
  final _clientController = StreamController<String>();
  final _serverController = StreamController<String>();

  late final mcp_client.MCPClient client;
  late final TomBrainMemoryMcpServer server;
  late final mcp_client.ServerConnection connection;

  _McpEnv({required TomBrainMemory memory}) {
    final clientChannel = StreamChannel<String>.withCloseGuarantee(
      _serverController.stream,
      _clientController.sink,
    );
    final serverChannel = StreamChannel<String>.withCloseGuarantee(
      _clientController.stream,
      _serverController.sink,
    );
    client = _BareMcpClient();
    server = TomBrainMemoryMcpServer(serverChannel, memory: memory);
    connection = client.connectServer(clientChannel);
  }

  Future<void> initialize() async {
    final result = await connection.initialize(
      mcp_client.InitializeRequest(
        protocolVersion: mcp_client.ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    if (result.protocolVersion?.isSupported == true) {
      connection.notifyInitialized(mcp_client.InitializedNotification());
      await server.initialized;
    }
  }

  Future<void> shutdown() async {
    await client.shutdown();
    await server.shutdown();
  }
}

base class _BareMcpClient extends mcp_client.MCPClient {
  _BareMcpClient()
      : super(mcp_client.Implementation(name: 'h27-client', version: '0.0.1'));
}

/// A fake memory exposing only what `registerMemoryTools` reads at
/// registration time (nothing) — `listTools` never invokes a handler, so
/// every member, including `profiles`, raises to keep the boundary explicit.
class _ProfilelessFakeMemory implements TomBrainMemory {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_ProfilelessFakeMemory does not implement ${invocation.memberName}; '
        'the H.27 verify only lists the advertised tool surface.',
      );
}
