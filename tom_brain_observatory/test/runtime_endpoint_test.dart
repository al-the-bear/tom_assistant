// The Runtime tab's two read/write surfaces (`prompt_tracing.md` § 6.4,
// § 8.3(10) `run` kind, § 8.3(13) `GET /api/runtime`):
//
//   * `GET /api/runtime` — the *currently-running* values the live brain bound
//     (gateway ports + base paths, the Telegram toggle, the resolved roots),
//     threaded in by `brain_serve` via `ObservatoryOptions.runtime`. Standalone
//     (no live brain to ask) it 503s "runtime unavailable" — the tab then shows
//     only the on-disk config, never a wrong "running" value.
//
//   * `GET`/`PUT /api/config?kind=run&name=brain_run` — the *on-disk* whole
//     `brain_run.yaml` run config (the runtime sections: `access:` / `memory:` /
//     `trail:` / `tools:` / `mcpServers:` alongside `substrate:`). A write is
//     validated by the full `BrainRunConfigLoader` — the same fail-fast the
//     brain applies at boot — so a config the brain would reject at boot is
//     rejected `422` here with the file untouched (AUTH-3), and the effect is
//     reported `next-boot` (AUTH-4: ports/roots only re-bind on restart).
//
// What this proves:
//   - the runtime snapshot round-trips its JSON shape when wired, and the route
//     503s when it is not (standalone).
//   - the `run` kind reads `brain_run.yaml` verbatim, round-trips a complete
//     valid run config, reports `next-boot`, and the brain re-reads it (AUTH-5,
//     proven downstream).
//   - AUTH-3: a run config the brain would reject at boot (a bad access port,
//     a missing memory root) is `422` with the file byte-for-byte untouched.
//   - AUTH-2: a `name` other than `brain_run`, and a traversal `name`, are `403`
//     before any read/write.

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' show Response;
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

void main() {
  late Directory cognitionDir;
  late CognitionConfig cognition;

  setUp(() {
    cognitionDir = Directory.systemTemp.createTempSync('obs_runtime_');
    writeMinimalCognitionTree(cognitionDir);
    cognition = CognitionConfigLoader.loadFromDir(cognitionDir.path);
  });

  tearDown(() {
    if (cognitionDir.existsSync()) cognitionDir.deleteSync(recursive: true);
  });

  TrailReadApi wired({RuntimeSnapshot? runtime}) => TrailReadApi(
        host: TrailHost.at(fixtureHostPath),
        cognition: cognition,
        cognitionRoot: cognitionDir,
        runtime: runtime,
      );

  File at(String relative) => File('${cognitionDir.path}/$relative');

  Future<Response> getConfig(TrailReadApi api, String kind, String name) =>
      obsGet(api, 'api/config?kind=${Uri.encodeQueryComponent(kind)}'
          '&name=${Uri.encodeQueryComponent(name)}');

  Future<Response> putConfig(
    TrailReadApi api,
    String kind,
    String name, {
    required String body,
  }) =>
      obsPut(
        api,
        'api/config?kind=${Uri.encodeQueryComponent(kind)}'
            '&name=${Uri.encodeQueryComponent(name)}',
        body: body,
      );

  Future<Map<String, Object?>> jsonBody(Response res) async =>
      (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();

  // A complete, loader-accepted whole-process run config: a valid `substrate:`
  // block (one stub provider, one role route, an embedding model) plus the two
  // other required sections `BrainRunConfigLoader` demands — `memory:` (a root +
  // a sqlite-vec binary path) and `access:` (the OpenAI port + the rate-limit /
  // quota edge policies).
  const String validRunConfig = '''
substrate:
  providers:
    - id: local
      kind: stub
  roleRoutes:
    assistant_to_user:
      - {providerId: local, model: base-model}
  embedding:
    providerId: local
    model: embed
    dims: 1
memory:
  root: /tmp/obs_runtime_store
  sqliteVec:
    extensionPath: /tmp/vec0.so
access:
  openai:
    port: 8841
  rateLimit:
    capacity: 60
    refillTokens: 1.0
    refillPeriodSeconds: 1.0
  quota:
    dailyCap: 1000
''';

  group('GET /api/runtime — the live snapshot', () {
    test('503 "runtime unavailable" when no snapshot is wired (standalone)',
        () async {
      final res = await obsGet(wired(), 'api/runtime');
      expect(res.statusCode, HttpStatus.serviceUnavailable);
      expect((await jsonBody(res))['error'], 'runtime unavailable');
    });

    test('returns the bound gateways, telegram toggle, and roots when wired',
        () async {
      final api = wired(
        runtime: const RuntimeSnapshot(
          openAiPort: 8841,
          openAiBasePath: '/v1',
          ollamaPort: 11434,
          anthropicPort: 8842,
          telegramEnabled: true,
          memoryRoot: '/srv/brain/mem',
          trailRoot: '/srv/brain/trail',
          cognitionRoot: '/srv/brain/cognition',
        ),
      );
      final res = await obsGet(api, 'api/runtime');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('application/json'));
      final body = await jsonBody(res);
      final gateways = (body['gateways'] as Map).cast<String, Object?>();
      expect((gateways['openai'] as Map)['port'], 8841);
      expect((gateways['openai'] as Map)['basePath'], '/v1');
      expect((gateways['ollama'] as Map)['port'], 11434);
      expect((gateways['anthropic'] as Map)['port'], 8842);
      expect(body['telegramEnabled'], true);
      final roots = (body['roots'] as Map).cast<String, Object?>();
      expect(roots['memory'], '/srv/brain/mem');
      expect(roots['trail'], '/srv/brain/trail');
      expect(roots['cognition'], '/srv/brain/cognition');
    });

    test('omits an absent optional channel from the gateways map', () async {
      final api = wired(
        runtime: const RuntimeSnapshot(openAiPort: 9001, openAiBasePath: '/v1'),
      );
      final body = await jsonBody(await obsGet(api, 'api/runtime'));
      final gateways = (body['gateways'] as Map).cast<String, Object?>();
      expect(gateways.containsKey('openai'), isTrue);
      expect(gateways.containsKey('ollama'), isFalse);
      expect(gateways.containsKey('anthropic'), isFalse);
      expect(body['telegramEnabled'], false);
    });
  });

  group('GET /api/config?kind=run — the on-disk run config', () {
    test('reads brain_run.yaml verbatim', () async {
      final res = await getConfig(wired(), 'run', 'brain_run');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/plain'));
      expect(await res.readAsString(), at('brain_run.yaml').readAsStringSync());
    });

    test('a name other than the run-config stem is 403', () async {
      final res = await getConfig(wired(), 'run', 'registry');
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('a traversal name is 403', () async {
      final res = await getConfig(wired(), 'run', '../../escape');
      expect(res.statusCode, HttpStatus.forbidden);
    });
  });

  group('PUT /api/config?kind=run — a loader-accepted write round-trips', () {
    test('a complete valid run config saves and reports next-boot', () async {
      final api = wired();
      final put = await putConfig(api, 'run', 'brain_run', body: validRunConfig);
      expect(put.statusCode, 200);
      final body = await jsonBody(put);
      expect(body['effect'], 'next-boot');
      expect(body['kind'], 'run');
      expect(at('brain_run.yaml').readAsStringSync(), validRunConfig);

      final get = await getConfig(api, 'run', 'brain_run');
      expect(await get.readAsString(), validRunConfig);
    });
  });

  group('PUT /api/config?kind=run — AUTH-3: a rejected write leaves the file '
      'untouched', () {
    test('a bad access port is 422 (the access loader rejects it)', () async {
      final before = at('brain_run.yaml').readAsStringSync();
      final res = await putConfig(wired(), 'run', 'brain_run', body: '''
substrate:
  providers:
    - id: local
      kind: stub
  roleRoutes:
    assistant_to_user:
      - {providerId: local, model: base-model}
  embedding:
    providerId: local
    model: embed
    dims: 1
memory:
  root: /tmp/obs_runtime_store
  sqliteVec:
    extensionPath: /tmp/vec0.so
access:
  openai:
    port: 0
  rateLimit:
    capacity: 60
    refillTokens: 1.0
    refillPeriodSeconds: 1.0
  quota:
    dailyCap: 1000
''');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(at('brain_run.yaml').readAsStringSync(), before);
    });

    test('a missing required section (memory) is 422', () async {
      final before = at('brain_run.yaml').readAsStringSync();
      final res = await putConfig(wired(), 'run', 'brain_run', body: '''
substrate:
  providers:
    - id: local
      kind: stub
  roleRoutes:
    assistant_to_user:
      - {providerId: local, model: base-model}
  embedding:
    providerId: local
    model: embed
    dims: 1
access:
  openai:
    port: 8841
  rateLimit:
    capacity: 60
    refillTokens: 1.0
    refillPeriodSeconds: 1.0
  quota:
    dailyCap: 1000
''');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(at('brain_run.yaml').readAsStringSync(), before);
    });

    test('a traversal name is 403 (before any write)', () async {
      final res = await putConfig(wired(), 'run', '../../escape',
          body: validRunConfig);
      expect(res.statusCode, HttpStatus.forbidden);
    });
  });
}
