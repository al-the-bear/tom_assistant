// Plan step 15 — the unified template-authoring surface
// (`prompt_tracing.md` § 6.3, § 8.3(9), AUTH-1…AUTH-5):
// `GET`/`PUT /api/templates?id=<promptId>&part=<part>` reads and writes any
// registered template file — a prompt pair's `system` / `user` half, a
// `fragment`'s single file, or a role's `persona` / `objective` prose. The
// registered file set comes from the cognition catalogue (route 12, plan
// step 14), so the route subsumes — and replaces — the old
// `/api/prompts/<roleId>/<part>` persona/objective route (principle 1).
//
// What this proves:
//   - GET returns a present file's text verbatim (a prompt half, a role's
//     persona prose).
//   - a registered-but-absent half is the empty-override signal: an empty body
//     200, not a 404 — the editor turns it into "create override" (§ 6.3).
//   - PUT + re-GET round-trips a write; the brain re-reads it on next use
//     (AUTH-5, proven downstream in `tom_brain_substrate`).
//   - AUTH-3: a malformed (unterminated) `${…}` is 422 and the file is left
//     byte-for-byte untouched; an empty system/user half is allowed, a fragment
//     must be non-empty.
//   - AUTH-2: an unregistered id/part, and an id that escapes the cognition
//     root, are refused 403 before any write.
//   - the route 503s "config unavailable" when no cognition config is wired,
//     mirroring the catalogue route (the route always exists; the UI degrades
//     cleanly, never a 404).
//
// The catalogue is derived from a minimal temp cognition tree (mirrors
// `catalogue_endpoint_test.dart`). Writes always target a fresh temp dir —
// never a committed fixture tree.

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
    cognitionDir = Directory.systemTemp.createTempSync('obs_templates_');
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

  Future<Response> getTemplate(TrailReadApi api, String id, String part) =>
      obsGet(api, 'api/templates?id=${Uri.encodeQueryComponent(id)}'
          '&part=${Uri.encodeQueryComponent(part)}');

  Future<Response> putTemplate(
    TrailReadApi api,
    String id,
    String part, {
    required String body,
  }) =>
      obsPut(
        api,
        'api/templates?id=${Uri.encodeQueryComponent(id)}'
            '&part=${Uri.encodeQueryComponent(part)}',
        body: body,
      );

  group('GET /api/templates — wired cognition config', () {
    test('returns a present prompt half verbatim', () async {
      final res = await getTemplate(
          wired(), 'assist_user.answer_with_memory.assembly', 'system');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/plain'));
      expect(await res.readAsString(), 'system framing\n');
    });

    test('returns a present fragment verbatim', () async {
      final res = await getTemplate(
          wired(), 'assist_user.answer_with_memory.tool_catalogue', 'fragment');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), 'fragment body\n');
    });

    test('returns a present role persona verbatim', () async {
      final res = await getTemplate(wired(), 'analyser', 'persona');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), 'ANALYSER VOICE\n');
    });

    test('a registered-but-absent half is an empty body 200', () async {
      // `analysis` has only its user half on disk; the system half is
      // registered (catalogue lists it present:false) but absent.
      final res = await getTemplate(
          wired(), 'assist_user.answer_with_thinking.analysis', 'system');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), isEmpty);
    });

    test('a not-yet-created role objective is an empty body 200', () async {
      final res = await getTemplate(wired(), 'analyser', 'objective');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), isEmpty);
    });

    test('an unregistered template id is 403', () async {
      final res =
          await getTemplate(wired(), 'no.such.template', 'system');
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('a missing query parameter is 400', () async {
      final res = await obsGet(wired(), 'api/templates?id=analyser');
      expect(res.statusCode, HttpStatus.badRequest);
    });
  });

  group('PUT /api/templates — wired cognition config', () {
    test('write + re-read round-trips a prompt half', () async {
      final api = wired();
      final put = await putTemplate(
          api, 'assist_user.answer_with_memory.assembly', 'user',
          body: 'REWRITTEN USER BODY');
      expect(put.statusCode, 200);
      expect(
        at('assist_user/answer_with_memory.assembly.user.md').readAsStringSync(),
        'REWRITTEN USER BODY',
      );

      final get = await getTemplate(
          api, 'assist_user.answer_with_memory.assembly', 'user');
      expect(await get.readAsString(), 'REWRITTEN USER BODY');
    });

    test('materialises an absent role persona on write', () async {
      final api = wired();
      final put = await putTemplate(api, 'analyser', 'objective',
          body: 'A FRESH OBJECTIVE');
      expect(put.statusCode, 200);
      expect(at('roles/analyser.objective.md').readAsStringSync(),
          'A FRESH OBJECTIVE');
    });

    test('a malformed \${…} is 422 and the file is untouched', () async {
      final before =
          at('assist_user/answer_with_memory.assembly.system.md')
              .readAsStringSync();
      final res = await putTemplate(
          wired(), 'assist_user.answer_with_memory.assembly', 'system',
          body: 'Hello \${name and then nothing closes it');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(
        at('assist_user/answer_with_memory.assembly.system.md')
            .readAsStringSync(),
        before,
      );
    });

    test('an empty system/user half is allowed (the empty-override signal)',
        () async {
      final res = await putTemplate(
          wired(), 'assist_user.answer_with_memory.assembly', 'system',
          body: '');
      expect(res.statusCode, 200);
      expect(
        at('assist_user/answer_with_memory.assembly.system.md')
            .readAsStringSync(),
        isEmpty,
      );
    });

    test('a blank fragment is refused 422 without touching disk', () async {
      final before =
          at('assist_user/answer_with_memory.tool_catalogue.md')
              .readAsStringSync();
      final res = await putTemplate(
          wired(), 'assist_user.answer_with_memory.tool_catalogue', 'fragment',
          body: '   \n');
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(
        at('assist_user/answer_with_memory.tool_catalogue.md')
            .readAsStringSync(),
        before,
      );
    });

    test('a traversal id is 403', () async {
      final res = await putTemplate(wired(), '../../escape', 'system',
          body: 'whatever');
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('a well-formed \${name} / \${{ expr }} round-trips (not malformed)',
        () async {
      final res = await putTemplate(
          wired(), 'assist_user.answer_with_memory.assembly', 'user',
          body: 'Hi \${name}, sum is \${{ 1 + {2: 3}.length }} done.');
      expect(res.statusCode, 200);
    });
  });

  group('GET/PUT /api/templates — deferred config (no cognition wired)', () {
    test('GET answers 503 {"error":"config unavailable"}', () async {
      final res = await getTemplate(apiOver(null, null), 'x', 'system');
      expect(res.statusCode, 503);
    });

    test('PUT answers 503 without writing', () async {
      final res =
          await putTemplate(apiOver(null, null), 'x', 'system', body: 'y');
      expect(res.statusCode, 503);
    });
  });
}

/// Writes a minimal cognition tree (mirrors `catalogue_endpoint_test.dart`):
/// `registry.yaml`, `assist_user.yaml`, the `assist_user/` template files (one
/// full pair, one user-only pair, one fragment), `llm/default.yaml`, and a
/// `roles/` folder with the `analyser` persona present and its objective absent
/// (so persona reads and an absent-objective write are both exercised). The
/// `analysis` prompt sets `role: analyser` so the role is referenced.
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
  // `assembly`: both halves present.
  File('${folder.path}/answer_with_memory.assembly.system.md')
      .writeAsStringSync('system framing\n');
  File('${folder.path}/answer_with_memory.assembly.user.md')
      .writeAsStringSync('user body\n');
  // `analysis`: only the user half present — the system half is empty.
  File('${folder.path}/answer_with_thinking.analysis.user.md')
      .writeAsStringSync('analysis body\n');
  // `tool_catalogue`: the single fragment file.
  File('${folder.path}/answer_with_memory.tool_catalogue.md')
      .writeAsStringSync('fragment body\n');

  Directory('${root.path}/llm').createSync();
  File('${root.path}/llm/default.yaml').writeAsStringSync('''
route:
  - provider: ollama
    model: gemma3:27b
''');

  // The analyser persona is present; its objective is deliberately absent.
  Directory('${root.path}/roles').createSync();
  File('${root.path}/roles/analyser.persona.md')
      .writeAsStringSync('ANALYSER VOICE\n');
}
