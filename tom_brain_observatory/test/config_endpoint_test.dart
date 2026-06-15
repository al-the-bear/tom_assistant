// Plan step 16 — the config-authoring surface (`prompt_tracing.md` § 6.3,
// § 8.3(10), AUTH-2…AUTH-4): `GET`/`PUT /api/config?kind=<kind>&name=<name>`
// reads and writes a registered config file — `kind ∈ {registry, procedure,
// llm_route, substrate}`. The registered set comes from the cognition catalogue
// (route 12), and each kind resolves against its containment root: the cognition
// root for registry/procedure/llm_route, the run-config root for substrate
// (defaulting to the cognition root here).
//
// What this proves:
//   - GET returns each kind's file text verbatim.
//   - an unregistered kind/name, and a name that escapes the root, are refused
//     `403` before any read/write (AUTH-2).
//   - PUT + re-GET round-trips a write the owning loader accepts; the brain
//     re-reads it (AUTH-5, proven downstream).
//   - AUTH-3: a config the brain would reject at boot is rejected `422` with the
//     file byte-for-byte untouched — an unknown setting key, a registry whose
//     `llm.default` is not among the routes, a prompt referencing an unknown llm
//     route (all via `CognitionConfigLoader`), and an invalid `substrate:` block
//     (via `SubstrateConfigLoader`).
//   - AUTH-4: the response reports the per-kind effect — a `procedure` edit is
//     `next-use`; `registry` / `llm_route` / `substrate` are `next-boot`.
//   - the route 503s "config unavailable" when no cognition config is wired
//     (the route always exists; the UI degrades cleanly, never a 404).
//
// The catalogue is derived from a minimal temp cognition tree (mirrors
// `templates_endpoint_test.dart`) plus a `brain_run.yaml` carrying a valid
// `substrate:` block. Writes always target a fresh temp dir.

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
    cognitionDir = Directory.systemTemp.createTempSync('obs_config_');
    _writeTree(cognitionDir);
    cognition = CognitionConfigLoader.loadFromDir(cognitionDir.path);
  });

  tearDown(() {
    if (cognitionDir.existsSync()) cognitionDir.deleteSync(recursive: true);
  });

  TrailReadApi apiOver(CognitionConfig? config, Directory? root) => TrailReadApi(
        host: TrailHost.at(fixtureHostPath),
        cognition: config,
        cognitionRoot: root,
      );

  TrailReadApi wired() => apiOver(cognition, cognitionDir);

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

  group('GET /api/config — wired cognition config', () {
    test('reads the registry verbatim', () async {
      final res = await getConfig(wired(), 'registry', 'registry');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/plain'));
      expect(await res.readAsString(), at('registry.yaml').readAsStringSync());
    });

    test('reads a procedure config verbatim', () async {
      final res = await getConfig(wired(), 'procedure', 'assist_user');
      expect(res.statusCode, 200);
      expect(
          await res.readAsString(), at('assist_user.yaml').readAsStringSync());
    });

    test('reads an llm_route config verbatim', () async {
      final res = await getConfig(wired(), 'llm_route', 'default');
      expect(res.statusCode, 200);
      expect(
          await res.readAsString(), at('llm/default.yaml').readAsStringSync());
    });

    test('reads the substrate config verbatim', () async {
      final res = await getConfig(wired(), 'substrate', 'substrate');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), at('brain_run.yaml').readAsStringSync());
    });

    test('an unregistered kind is 403', () async {
      final res = await getConfig(wired(), 'bogus', 'registry');
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('a registered kind with an unknown name is 403', () async {
      final res = await getConfig(wired(), 'procedure', 'no_such_procedure');
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('a missing query parameter is 400', () async {
      final res = await obsGet(wired(), 'api/config?kind=registry');
      expect(res.statusCode, HttpStatus.badRequest);
    });
  });

  group('PUT /api/config — a loader-accepted write round-trips', () {
    test('a procedure edit saves and reports next-use', () async {
      final api = wired();
      const edited = '''
temperature: 0.5
llm: default

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly
      tools: all
    tool_catalogue:
      template: answer_with_memory.tool_catalogue
      kind: fragment

answer_with_thinking:
  prompts:
    analysis:
      template: answer_with_thinking.analysis
      role: analyser
''';
      final put = await putConfig(api, 'procedure', 'assist_user', body: edited);
      expect(put.statusCode, 200);
      final body = await jsonBody(put);
      expect(body['effect'], 'next-use');
      expect(at('assist_user.yaml').readAsStringSync(), edited);

      final get = await getConfig(api, 'procedure', 'assist_user');
      expect(await get.readAsString(), edited);
    });

    test('a registry edit saves and reports next-boot', () async {
      final api = wired();
      const edited = '''
procedures:
  assist_user:
    config: assist_user.yaml
    folder: assist_user
roles:
  folder: roles
llm:
  folder: llm
  default: default
''';
      final put = await putConfig(api, 'registry', 'registry', body: edited);
      expect(put.statusCode, 200);
      expect((await jsonBody(put))['effect'], 'next-boot');
      expect(at('registry.yaml').readAsStringSync(), edited);
    });

    test('an llm_route edit saves and reports next-boot', () async {
      final api = wired();
      const edited = '''
route:
  - provider: ollama
    model: gemma3:12b
''';
      final put = await putConfig(api, 'llm_route', 'default', body: edited);
      expect(put.statusCode, 200);
      expect((await jsonBody(put))['effect'], 'next-boot');
      expect(at('llm/default.yaml').readAsStringSync(), edited);
    });

    test('a substrate edit saves and reports next-boot', () async {
      final api = wired();
      const edited = '''
substrate:
  providers:
    - id: local
      kind: stub
  roleRoutes:
    assistant_to_user:
      - {providerId: local, model: changed-model}
  embedding:
    providerId: local
    model: embed
    dims: 1
''';
      final put = await putConfig(api, 'substrate', 'substrate', body: edited);
      expect(put.statusCode, 200);
      expect((await jsonBody(put))['effect'], 'next-boot');
      expect(at('brain_run.yaml').readAsStringSync(), edited);
    });
  });

  group('PUT /api/config — AUTH-3: rejected writes leave the file untouched',
      () {
    test('an unknown setting key in a procedure config is 422', () async {
      final before = at('assist_user.yaml').readAsStringSync();
      final res = await putConfig(wired(), 'procedure', 'assist_user', body: '''
answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly
      not_a_real_key: 1
''');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(at('assist_user.yaml').readAsStringSync(), before);
    });

    test('a registry whose llm.default is not a loaded route is 422', () async {
      final before = at('registry.yaml').readAsStringSync();
      final res = await putConfig(wired(), 'registry', 'registry', body: '''
procedures:
  assist_user:
    config: assist_user.yaml
    folder: assist_user
roles:
  folder: roles
llm:
  folder: llm
  default: nonexistent
''');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(at('registry.yaml').readAsStringSync(), before);
    });

    test('a prompt referencing an unknown llm route is 422', () async {
      final before = at('assist_user.yaml').readAsStringSync();
      final res = await putConfig(wired(), 'procedure', 'assist_user', body: '''
llm: default

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly
      llm: no_such_route
    tool_catalogue:
      template: answer_with_memory.tool_catalogue
      kind: fragment

answer_with_thinking:
  prompts:
    analysis:
      template: answer_with_thinking.analysis
''');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(at('assist_user.yaml').readAsStringSync(), before);
    });

    test('an invalid substrate block (empty providers) is 422', () async {
      final before = at('brain_run.yaml').readAsStringSync();
      final res = await putConfig(wired(), 'substrate', 'substrate', body: '''
substrate:
  providers: []
  roleRoutes:
    assistant_to_user:
      - {providerId: local, model: m}
  embedding:
    providerId: local
    model: embed
    dims: 1
''');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(at('brain_run.yaml').readAsStringSync(), before);
    });

    test('a traversal name is 403', () async {
      final res = await putConfig(wired(), 'procedure', '../../escape',
          body: 'whatever');
      expect(res.statusCode, HttpStatus.forbidden);
    });
  });

  group('GET/PUT /api/config — deferred config (no cognition wired)', () {
    test('GET answers 503', () async {
      final res = await getConfig(apiOver(null, null), 'registry', 'registry');
      expect(res.statusCode, 503);
    });

    test('PUT answers 503 without writing', () async {
      final res = await putConfig(apiOver(null, null), 'registry', 'registry',
          body: 'x');
      expect(res.statusCode, 503);
    });
  });
}

/// Writes a minimal cognition tree (mirrors `templates_endpoint_test.dart`)
/// plus a `brain_run.yaml` carrying a valid `substrate:` block, so all four
/// config kinds — `registry`, `procedure`, `llm_route`, `substrate` — resolve.
void _writeTree(Directory root) {
  File('${root.path}/registry.yaml').writeAsStringSync('''
procedures:
  assist_user:
    config: assist_user.yaml
    folder: assist_user
roles:
  folder: roles
llm:
  folder: llm
  default: default
''');

  File('${root.path}/assist_user.yaml').writeAsStringSync('''
temperature: 1.0
llm: default

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly
      tools: all
    tool_catalogue:
      template: answer_with_memory.tool_catalogue
      kind: fragment

answer_with_thinking:
  prompts:
    analysis:
      template: answer_with_thinking.analysis
      role: analyser
''');

  final Directory folder = Directory('${root.path}/assist_user')..createSync();
  File('${folder.path}/answer_with_memory.assembly.system.md')
      .writeAsStringSync('system framing\n');
  File('${folder.path}/answer_with_memory.assembly.user.md')
      .writeAsStringSync('user body\n');
  File('${folder.path}/answer_with_thinking.analysis.user.md')
      .writeAsStringSync('analysis body\n');
  File('${folder.path}/answer_with_memory.tool_catalogue.md')
      .writeAsStringSync('fragment body\n');

  Directory('${root.path}/llm').createSync();
  File('${root.path}/llm/default.yaml').writeAsStringSync('''
route:
  - provider: ollama
    model: gemma3:27b
''');

  Directory('${root.path}/roles').createSync();
  File('${root.path}/roles/analyser.persona.md')
      .writeAsStringSync('ANALYSER VOICE\n');

  // The whole-process run config the `substrate` kind resolves against
  // (run-config root defaults to the cognition root here). A minimal but valid
  // `substrate:` block — one stub provider, one role route, an embedding model.
  File('${root.path}/brain_run.yaml').writeAsStringSync('''
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
''');
}
