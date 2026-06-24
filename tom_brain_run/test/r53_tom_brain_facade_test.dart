// R53 — the in-process embedding facade (`tom_brain_cli.md` § 10; CLI plan
// step #10). Both constructors stand the *real* production cognition up behind
// the shared `defaultServeBoot` seam (no fake boot here — the whole point is the
// facade boots the same process `tom_brain serve` does), and the two postures
// differ only in where files live and whether the Observatory is writable.
//
//   * `TomBrain.fromProjectDir` — the `--home`/`agent` directory convention. The
//     skeleton carries a real cognition tree (copied from `config/bomber/cognition`)
//     and a real `scripts/system` tree, so the boot loads its prompt resolvers.
//     The Observatory is **read-write**: a `PUT /api/templates` materialises a
//     role's persona prose on disk, and a re-read proves the edit persisted.
//     Profiles are read from `<agent>/profiles/`.
//   * `TomBrain.fromConfig` — fully programmatic, no backing files. The
//     Observatory is forced **read-only**: the three authoring `PUT` routes
//     (`/api/config`, `/api/templates`, `/api/procedures/<id>`) each return
//     `409 config_is_immutable`. The passed `profiles:` objects resolve through
//     the boot registry.
//
// Both auto-include the bundled sqlite-vec native library: a populated bundle is
// built from `tom_binaries/sqlite_vec` and injected through the `bundle` test
// seam, so each brain reports `sqliteVecOrigin == bundleExtracted`. The group is
// gated on a usable packaged vec0 binary for this platform (the on-disk store
// loads the extension at `open`).

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart'
    show
        BrainApiKey,
        BrainConfig,
        BrainEmbedding,
        BrainOverrides,
        BrainProvider,
        BrainRoute,
        BundleManifest,
        Profile,
        PromptSource,
        ScriptSource,
        SqliteVecOrigin,
        TomBrain,
        buildBundleManifest;

import 'support/live_e2e_harness.dart'
    show findSqliteVecRoot, sqliteVecSkipReason;

/// A free loopback port: bind to `0`, read the assigned port, release it. A
/// race window remains, but the serial suite makes it negligible, and the real
/// `serve` seam must bind a genuine port (the OpenAI edge socket).
Future<int> _freePort() async {
  final ServerSocket socket =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final int port = socket.port;
  await socket.close();
  return port;
}

/// Recursively copies the directory tree at [from] into [to].
void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entity in from.listSync(recursive: true)) {
    final String relative = entity.path.substring(from.path.length + 1);
    final String target = '${to.path}${Platform.pathSeparator}$relative';
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

/// The version-controlled cognition tree the live suites wire from.
Directory _cognitionSource() => Directory(
      '${Directory.current.absolute.path}${Platform.pathSeparator}config'
      '${Platform.pathSeparator}bomber${Platform.pathSeparator}cognition',
    );

/// The procedure `scripts/system` tree in the sibling procedure package.
Directory _scriptsSource() => Directory(
      '${Directory.current.absolute.path}${Platform.pathSeparator}..'
      '${Platform.pathSeparator}tom_brain_procedure'
      '${Platform.pathSeparator}scripts${Platform.pathSeparator}system',
    );

/// An inline substrate + access `brain.yaml` for the `fromProjectDir` skeleton.
/// The providers are never contacted at boot (the substrate is manufactured
/// lazily), so the base URLs need not be reachable. The convention supplies
/// `memory.root` / `trail.root` / `cognition.root` / `scripts.systemDir`.
String _skeletonBrainYaml() => '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: http://127.0.0.1:1/
      models:
        - test-model
    - id: ollama
      kind: ollama
      baseUrl: http://127.0.0.1:1/
      models:
        - embed-model
  roleRoutes:
    assistant_to_user:
      - providerId: omlx
        model: test-model
  embedding:
    providerId: ollama
    model: embed-model
    dims: 768
    normalize: true
access:
  openai:
    port: 8080
    basePath: /v1
  apiKeys:
    - key: facade-token
      principal: owner
      displayName: Owner
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000
''';

/// `GET <observatory><path>` → (status, decoded JSON body | raw text).
Future<({int statusCode, String body})> _get(String url) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(Uri.parse(url));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    return (statusCode: response.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

/// `PUT <url>` with [body] → (status, raw text).
Future<({int statusCode, String body})> _put(String url, String body) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.putUrl(Uri.parse(url));
    request.add(utf8.encode(body));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    return (statusCode: response.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

void main() {
  final String? vecRoot = findSqliteVecRoot();
  final String? skip = sqliteVecSkipReason(vecRoot);

  group('R53 — TomBrain embedding facade', () {
    late BundleManifest bundle;

    setUpAll(() async {
      bundle = await buildBundleManifest(
        sqliteVecBinariesRoot: Directory(vecRoot!),
      );
    });

    test('FACADE-01: fromProjectDir boots an agent skeleton, loads profiles, '
        'and a template edit persists (read-write Observatory)', () async {
      final Directory home =
          await Directory.systemTemp.createTemp('tombrain_home_');
      addTearDown(() async {
        if (home.existsSync()) await home.delete(recursive: true);
      });

      final String agent = '${home.path}${Platform.pathSeparator}agent';
      _copyTree(_cognitionSource(),
          Directory('$agent${Platform.pathSeparator}prompts'));
      _copyTree(_scriptsSource(),
          Directory('$agent${Platform.pathSeparator}scripts'));

      // A dir-sourced profile (`<agent>/profiles/research.yaml`).
      final Directory profilesDir =
          Directory('$agent${Platform.pathSeparator}profiles');
      profilesDir.createSync(recursive: true);
      File('${profilesDir.path}${Platform.pathSeparator}research.yaml')
          .writeAsStringSync('''
profiles:
  research:
    mode: cognitive
    role: researcher
''');

      File('$agent${Platform.pathSeparator}brain.yaml')
          .writeAsStringSync(_skeletonBrainYaml());

      final int port = await _freePort();
      final TomBrain brain = await TomBrain.fromProjectDir(
        home,
        overrides: BrainOverrides(openAiPort: port),
        bundle: bundle,
      );
      addTearDown(brain.stop);

      // The sqlite-vec native library came from the injected bundle.
      expect(brain.sqliteVecOrigin, SqliteVecOrigin.bundleExtracted);

      // The dir-sourced profile resolved into the boot registry.
      expect(brain.profiles.contains('research'), isTrue);
      expect(brain.profiles.profile('research')!.role, 'researcher');

      // The co-hosted memory MCP server came up: in home mode the isolate must
      // boot from the convention-merged `memory.root` (the skeleton brain.yaml
      // carries no `memory:` block — the convention fills it), not a re-read of
      // the partial on-disk file.
      expect(brain.memoryMcpUrl, isNotNull,
          reason: 'home-mode memory MCP must boot from the resolved config');

      // The read-write Observatory co-hosted.
      final String? observatory = brain.observatoryUrl;
      expect(observatory, isNotNull);

      // GET /api/meta reports the surface is writable.
      final meta = await _get('$observatory/api/meta');
      expect(meta.statusCode, 200);
      expect(jsonDecode(meta.body),
          containsPair('configWritable', true));

      // PUT a role's persona prose; it materialises on disk under the
      // cognition tree, and a re-read proves the edit persisted (AUTH-5).
      const String edited = 'edited analyser persona prose';
      final put = await _put(
        '$observatory/api/templates?id=analyser&part=persona',
        edited,
      );
      expect(put.statusCode, 200, reason: put.body);

      final File personaFile = File('$agent${Platform.pathSeparator}prompts'
          '${Platform.pathSeparator}roles'
          '${Platform.pathSeparator}analyser.persona.md');
      expect(personaFile.readAsStringSync(), edited);
    });

    test('FACADE-02: fromConfig boots with no files; the three authoring PUTs '
        'return 409; passed profiles resolve (read-only Observatory)',
        () async {
      final Directory root =
          await Directory.systemTemp.createTemp('tombrain_cfg_');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
      });

      String under(String name) =>
          '${root.path}${Platform.pathSeparator}$name';

      final int port = await _freePort();
      final BrainConfig config = BrainConfig(
        providers: const <BrainProvider>[
          BrainProvider(
            id: 'omlx',
            kind: 'openai',
            baseUrl: 'http://127.0.0.1:1/',
            models: <String>['test-model'],
          ),
          BrainProvider(
            id: 'ollama',
            kind: 'ollama',
            baseUrl: 'http://127.0.0.1:1/',
            models: <String>['embed-model'],
          ),
        ],
        routes: const <String, List<BrainRoute>>{
          'assistant_to_user': <BrainRoute>[
            BrainRoute(providerId: 'omlx', model: 'test-model'),
          ],
        },
        embedding: const BrainEmbedding(
          providerId: 'ollama',
          model: 'embed-model',
          dims: 768,
        ),
        memoryRoot: under('memory'),
        trailRoot: under('trail'),
        historyDir: under('history'),
        edgeDir: under('edge'),
        openAiPort: port,
        apiKeys: const <BrainApiKey>[
          BrainApiKey(key: 'facade-token', principal: 'owner'),
        ],
        prompts: const PromptSource.bundle(),
        scripts: const ScriptSource.bundle(),
        profiles: <Profile>[
          Profile(id: 'research', role: 'researcher'),
        ],
      );

      final TomBrain brain = await TomBrain.fromConfig(config, bundle: bundle);
      addTearDown(brain.stop);

      expect(brain.sqliteVecOrigin, SqliteVecOrigin.bundleExtracted);

      // The passed profile object resolved into the boot registry and routes.
      expect(brain.profiles.contains('research'), isTrue);
      expect(brain.profiles.profile('research')!.role, 'researcher');
      expect(brain.profiles.profile('research')!.effectiveEntryProcedure,
          'prompt_analyzer_v1');

      final String? observatory = brain.observatoryUrl;
      expect(observatory, isNotNull);

      // GET /api/meta reports the surface is read-only.
      final meta = await _get('$observatory/api/meta');
      expect(meta.statusCode, 200);
      expect(jsonDecode(meta.body),
          containsPair('configWritable', false));

      // All three authoring PUTs short-circuit `409 config_is_immutable`.
      final config409 = await _put(
        '$observatory/api/config?kind=substrate&name=substrate',
        'substrate:\n  providers: []\n',
      );
      expect(config409.statusCode, 409, reason: config409.body);
      expect(jsonDecode(config409.body),
          containsPair('error', 'config_is_immutable'));

      final template409 = await _put(
        '$observatory/api/templates?id=analyser&part=persona',
        'whatever',
      );
      expect(template409.statusCode, 409, reason: template409.body);

      final procedure409 = await _put(
        '$observatory/api/procedures/answer_with_memory_v1',
        'void main() {}',
      );
      expect(procedure409.statusCode, 409, reason: procedure409.body);
    });
  }, skip: skip);
}
