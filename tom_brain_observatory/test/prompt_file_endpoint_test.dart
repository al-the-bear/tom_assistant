// Slice 3 — the externalized-prompt half of the source-authoring surface
// (`prompt_tracing.md` § 6.3, § 8.3(9), AUTH-1…AUTH-5):
// `GET`/`PUT /api/prompts/<roleId>/<part>` reads and writes a role's
// `<roleId>.persona.md` / `<roleId>.objective.md` override, so an operator can
// reshape the next call assembled for that role (the brain's file-backed role
// loader re-reads the override on next use — AUTH-5, proven in
// `tom_brain_substrate`'s `reloading_role_registry_test.dart`).
//
// What this proves:
//   - GET returns the override prose verbatim; an absent override is a clean
//     404 — the signal the UI turns into "create override" (§ 6.3).
//   - PUT writes (and materialises) the override under the containment guard
//     (AUTH-2); a non-empty body is required (AUTH-3 for prose), and a blank
//     body is refused (422) without touching disk.
//   - `part` is closed to {persona, objective}; anything else, or an id that
//     escapes the prompts root, is refused (403/404) before any write.
//   - The endpoints 404 cleanly when no prompts root is configured.
//
// Writes always target a fresh temp dir — never a committed fixture tree.

import 'dart:io';

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

import 'support/obs_harness.dart';

void main() {
  late Directory promptsRoot;

  setUp(() {
    promptsRoot = Directory.systemTemp.createTempSync('obs_prompts_');
  });

  tearDown(() {
    if (promptsRoot.existsSync()) promptsRoot.deleteSync(recursive: true);
  });

  TrailReadApi apiOver(Directory? root) => TrailReadApi(
        host: TrailHost.at(fixtureHostPath),
        promptsRoot: root,
      );

  File personaFile(String roleId) =>
      File('${promptsRoot.path}/$roleId.persona.md');

  group('GET /api/prompts/<roleId>/<part>', () {
    test('returns the override prose verbatim', () async {
      personaFile('analyser').writeAsStringSync('ANALYSER VOICE OVERRIDE');
      final res =
          await obsGet(apiOver(promptsRoot), 'api/prompts/analyser/persona');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/plain'));
      expect(await res.readAsString(), 'ANALYSER VOICE OVERRIDE');
    });

    test('404 when the override does not exist (create-override signal)',
        () async {
      final res =
          await obsGet(apiOver(promptsRoot), 'api/prompts/analyser/persona');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('404 when no prompts root is configured', () async {
      final res = await obsGet(apiOver(null), 'api/prompts/analyser/persona');
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('PUT /api/prompts/<roleId>/<part>', () {
    test('writes (materialises) the override and returns 200', () async {
      final res = await obsPut(
        apiOver(promptsRoot),
        'api/prompts/analyser/objective',
        body: 'NEW OBJECTIVE FROM THE OBSERVATORY',
      );
      expect(res.statusCode, 200);
      expect(
        File('${promptsRoot.path}/analyser.objective.md').readAsStringSync(),
        'NEW OBJECTIVE FROM THE OBSERVATORY',
      );
    });

    test('refuses a blank body (422) without touching disk', () async {
      final res = await obsPut(
        apiOver(promptsRoot),
        'api/prompts/analyser/persona',
        body: '   \n',
      );
      expect(res.statusCode, HttpStatus.unprocessableEntity);
      expect(personaFile('analyser').existsSync(), isFalse);
    });

    test('refuses an unknown part (403)', () async {
      final res = await obsPut(
        apiOver(promptsRoot),
        'api/prompts/analyser/secrets',
        body: 'whatever',
      );
      expect(res.statusCode, anyOf(HttpStatus.forbidden, HttpStatus.notFound));
      expect(
        File('${promptsRoot.path}/analyser.secrets.md').existsSync(),
        isFalse,
      );
    });

    test('refuses a roleId that escapes the prompts root (403)', () async {
      final res = await obsPut(
        apiOver(promptsRoot),
        'api/prompts/${Uri.encodeComponent('../../escape')}/persona',
        body: 'whatever',
      );
      expect(res.statusCode, anyOf(HttpStatus.forbidden, HttpStatus.notFound));
    });

    test('404 when no prompts root is configured', () async {
      final res = await obsPut(
        apiOver(null),
        'api/prompts/analyser/persona',
        body: 'whatever',
      );
      expect(res.statusCode, HttpStatus.notFound);
    });
  });
}
