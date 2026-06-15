// Plan step 14 — the `/api/catalogue` route (`prompt_tracing.md` § 8.3,
// `prompt_configuration.md` § 13.4). It re-exposes the `CognitionConfig`
// catalogue (plan step 13) — every registered template with its resolved
// file path(s) + present flags, the role prose files, and the config-file
// inventory — as the registry-derived index the gear configuration editor
// (plan step 19) browses.
//
// What this proves:
//   - GET /api/catalogue returns the registry-derived index: the templates
//     (incl. the fragment) in ID order, each with its kind + resolved files;
//     the roles; the config-file inventory.
//   - an absent pair half is reported `present == false`, its sibling present
//     (the empty-document signal the editor turns into "create override").
//   - absent cognition config → 503 {"error":"config unavailable"}, mirroring
//     the memory-unavailable pattern (the route always exists; the UI degrades
//     cleanly, never a 404).
//
// The catalogue is derived from a minimal temp cognition tree loaded via
// `CognitionConfigLoader.loadFromDir` (the same tree shape proven directly in
// `tom_brain_run`'s `cognition_catalogue_test.dart`).

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
    cognitionDir = Directory.systemTemp.createTempSync('obs_catalogue_');
    _writeTree(cognitionDir);
    cognition = CognitionConfigLoader.loadFromDir(cognitionDir.path);
  });

  tearDown(() {
    if (cognitionDir.existsSync()) cognitionDir.deleteSync(recursive: true);
  });

  TrailReadApi apiOver(CognitionConfig? config) => TrailReadApi(
        host: TrailHost.at(fixtureHostPath),
        cognition: config,
      );

  Future<Map<String, Object?>> jsonBody(Response res) async =>
      (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();

  group('GET /api/catalogue — wired cognition config', () {
    test('returns the registry-derived template index in ID order', () async {
      final res = await obsGet(apiOver(cognition), 'api/catalogue');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('application/json'));

      final body = await jsonBody(res);
      final templates = (body['templates'] as List).cast<Map>();
      expect(templates.map((t) => t['id']).toList(), <String>[
        'assist_user.answer_with_memory.assembly',
        'assist_user.answer_with_memory.tool_catalogue',
        'assist_user.answer_with_thinking.analysis',
      ]);

      final kinds = <String, Object?>{
        for (final t in templates) t['id'] as String: t['kind'],
      };
      expect(kinds['assist_user.answer_with_memory.assembly'], 'prompt');
      expect(kinds['assist_user.answer_with_memory.tool_catalogue'], 'fragment');
    });

    test('a prompt lists its system+user pair; a fragment its single file',
        () async {
      final body = await jsonBody(await obsGet(apiOver(cognition), 'api/catalogue'));
      final templates = (body['templates'] as List).cast<Map>();

      final assembly = templates.firstWhere(
          (t) => t['id'] == 'assist_user.answer_with_memory.assembly');
      final files = (assembly['files'] as List).cast<Map>();
      expect(files.map((f) => f['part']).toList(), <String>['system', 'user']);
      expect(files[0]['path'],
          'assist_user/answer_with_memory.assembly.system.md');
      expect(files[1]['path'],
          'assist_user/answer_with_memory.assembly.user.md');

      final fragment = templates.firstWhere(
          (t) => t['id'] == 'assist_user.answer_with_memory.tool_catalogue');
      final fragFiles = (fragment['files'] as List).cast<Map>();
      expect(fragFiles, hasLength(1));
      expect(fragFiles.single['part'], 'fragment');
      expect(fragFiles.single['present'], isTrue);
    });

    test('an absent pair half is reported present:false, its sibling present',
        () async {
      final body = await jsonBody(await obsGet(apiOver(cognition), 'api/catalogue'));
      final analysis = (body['templates'] as List).cast<Map>().firstWhere(
          (t) => t['id'] == 'assist_user.answer_with_thinking.analysis');
      final files = (analysis['files'] as List).cast<Map>();
      final system = files.firstWhere((f) => f['part'] == 'system');
      final user = files.firstWhere((f) => f['part'] == 'user');
      expect(system['present'], isFalse);
      expect(user['present'], isTrue);
    });

    test('lists the distinct prompt roles + the assistant_to_user default',
        () async {
      final body = await jsonBody(await obsGet(apiOver(cognition), 'api/catalogue'));
      final roles = (body['roles'] as List).cast<Map>();
      expect(roles.map((r) => r['name']).toList(),
          <String>['analyser', 'assistant_to_user']);
      final analyser = roles.firstWhere((r) => r['name'] == 'analyser');
      expect(analyser['personaPath'], 'roles/analyser.persona.md');
      expect(analyser['objectivePath'], 'roles/analyser.objective.md');
    });

    test('lists the complete config-file inventory', () async {
      final body = await jsonBody(await obsGet(apiOver(cognition), 'api/catalogue'));
      final configs = (body['configFiles'] as List).cast<Map>();

      final registry = configs.firstWhere((c) => c['kind'] == 'registry');
      expect(registry['path'], 'registry.yaml');

      final proc = configs.firstWhere((c) => c['kind'] == 'procedure');
      expect(proc['name'], 'assist_user');
      expect(proc['path'], 'assist_user.yaml');

      final route = configs.firstWhere((c) => c['kind'] == 'llm');
      expect(route['name'], 'default');
      expect(route['path'], 'llm/default.yaml');

      final substrate = configs.firstWhere((c) => c['kind'] == 'substrate');
      expect(substrate['path'], 'brain_run.yaml');
      expect(substrate['location'], 'substrate');
    });
  });

  group('GET /api/catalogue — deferred config (no cognition wired)', () {
    test('answers 503 {"error":"config unavailable"}', () async {
      final res = await obsGet(apiOver(null), 'api/catalogue');
      expect(res.statusCode, 503);
      final body = await jsonBody(res);
      expect(body['error'], 'config unavailable');
    });

    test('the Module-1 trail surface still works without a cognition config',
        () async {
      final res = await obsGet(apiOver(null), 'api/traces');
      expect(res.statusCode, 200);
    });
  });
}

/// Writes a minimal cognition tree (mirrors `tom_brain_run`'s
/// `cognition_catalogue_test.dart`): `registry.yaml`, `assist_user.yaml`, the
/// `assist_user/` template files (one full pair, one user-only pair, one
/// fragment) and `llm/default.yaml`. The `analysis` prompt sets `role: analyser`
/// so a distinct role plus the `assistant_to_user` default both appear.
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
}
