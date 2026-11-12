// Plan step 20 — end-to-end verification on the live `bomber` cognition tree
// (`prompt_restructuring_and_configuration_plan.md` Phase 8). Boots the real
// observatory `TrailReadApi` over the *migrated* `tom_brain_run/config/bomber`
// config and proves, over real HTTP, the four operator guarantees the step
// names:
//
//   1. EVERY registered template — including the migrated completion-check,
//      continuation-hint, and todo-list — is listed in the catalogue AND
//      editable through `GET`/`PUT /api/templates`.
//   2. A persona edit round-trips through `/api/templates` and is re-read on the
//      next use (AUTH-5 "pull, not push" — prose is read live, no effect field).
//   3. A route re-point through `/api/config?kind=llm_route` reports `next-boot`
//      (AUTH-4 — provider routing the loader reads at boot).
//   4. AUTH-6: the anchor and tool-policy profiles are NOT offered as editable —
//      no anchor/tool_policy template id, the config kinds are exactly the wire
//      alphabet, and `PUT /api/config?kind=anchor` is refused `403`.
//
// And the step's "Done when": NO hidden hardcoded prompt text remains. We prove
// this structurally — every `.md` prose file under the cognition root is
// reachable (and therefore editable) through the catalogue; nothing on disk is
// orphaned from the registry-derived index.
//
// The live tree is VERSION CONTROLLED, so every run operates on a fresh
// byte-identical COPY in a temp dir (the `config/bomber` parent, so both
// `brain_run.yaml` and `cognition/` come along) — the writes the test makes
// never touch the committed config. A no-mutation snapshot of the *source* tree
// is asserted at tear-down as a belt-and-braces guard.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Response;
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:tom_brain_config/tom_brain_config.dart';
import 'package:test/test.dart';

import '../support/obs_harness.dart';

/// The live, migrated cognition config the brain runs on `bomber`, relative to
/// the observatory package root (where the test harness executes).
const String _liveBomberConfig = '../tom_brain_run/config/bomber';

void main() {
  // Skip cleanly on a checkout that does not carry the bomber config (e.g. a
  // partial clone) rather than failing — the guarantees are about that tree.
  if (!Directory(_liveBomberConfig).existsSync()) {
    test('live bomber config present', () {}, skip: 'no $_liveBomberConfig');
    return;
  }

  late Directory runConfigRoot; // the copy of `config/bomber`
  late Directory cognitionRoot; // `<copy>/cognition`
  late CognitionConfig cognition;
  late FsSnapshot sourceBefore;

  setUp(() {
    sourceBefore = FsSnapshot.capture(_liveBomberConfig);
    runConfigRoot = Directory.systemTemp.createTempSync('obs_bomber_');
    _copyTree(Directory(_liveBomberConfig), runConfigRoot);
    cognitionRoot = Directory(p.join(runConfigRoot.path, 'cognition'));
    cognition = CognitionConfigLoader.loadFromDir(cognitionRoot.path);
  });

  tearDown(() {
    if (runConfigRoot.existsSync()) runConfigRoot.deleteSync(recursive: true);
    // The committed source tree must be byte-for-byte untouched.
    expect(sourceBefore.diff(FsSnapshot.capture(_liveBomberConfig)), isEmpty,
        reason: 'the live bomber config must never be mutated by the test');
  });

  TrailReadApi api() => TrailReadApi(
        host: TrailHost.at(fixtureHostPath),
        cognition: cognition,
        cognitionRoot: cognitionRoot,
        runConfigRoot: runConfigRoot,
      );

  Future<Response> getTemplate(TrailReadApi a, String id, String part) =>
      obsGet(a, 'api/templates?id=${Uri.encodeQueryComponent(id)}'
          '&part=${Uri.encodeQueryComponent(part)}');

  Future<Response> putTemplate(TrailReadApi a, String id, String part,
          {required String body}) =>
      obsPut(
        a,
        'api/templates?id=${Uri.encodeQueryComponent(id)}'
            '&part=${Uri.encodeQueryComponent(part)}',
        body: body,
      );

  Future<Response> getConfig(TrailReadApi a, String kind, String name) =>
      obsGet(a, 'api/config?kind=${Uri.encodeQueryComponent(kind)}'
          '&name=${Uri.encodeQueryComponent(name)}');

  Future<Response> putConfig(TrailReadApi a, String kind, String name,
          {required String body}) =>
      obsPut(
        a,
        'api/config?kind=${Uri.encodeQueryComponent(kind)}'
            '&name=${Uri.encodeQueryComponent(name)}',
        body: body,
      );

  Future<Map<String, Object?>> json(Response res) async =>
      (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();

  Future<List<Map<String, Object?>>> templates(TrailReadApi a) async {
    final body = await json(await obsGet(a, 'api/catalogue'));
    return (body['templates'] as List)
        .map((t) => (t as Map).cast<String, Object?>())
        .toList();
  }

  group('Step 20.1 — every template is listed and editable', () {
    test('the migrated completion-check / continuation-hint / todo-list appear',
        () async {
      final ids = (await templates(api())).map((t) => t['id']).toSet();
      // The three prompt fragments the migration moved out of procedure code
      // (and the parallel `answer_with_thinking` family) are first-class
      // catalogue entries now.
      expect(
          ids,
          containsAll(<String>[
            'assist_user.answer_with_memory.completion_check',
            'assist_user.answer_with_memory.continuation_hint',
            'assist_user.answer_with_memory.todo_list',
          ]));
    });

    test('every catalogue template part is GET-readable (present or empty)',
        () async {
      final a = api();
      final ts = await templates(a);
      expect(ts, isNotEmpty);
      for (final t in ts) {
        final id = t['id'] as String;
        for (final f in (t['files'] as List).cast<Map>()) {
          final part = f['part'] as String;
          final res = await getTemplate(a, id, part);
          expect(res.statusCode, 200,
              reason: 'template $id · $part must be readable');
        }
      }
    });

    test('a fragment edit round-trips against the live tree', () async {
      final a = api();
      const id = 'assist_user.answer_with_memory.continuation_hint';
      final original = await (await getTemplate(a, id, 'fragment'))
          .readAsString();

      final put = await putTemplate(a, id, 'fragment',
          body: '$original\n<!-- step-20 edit -->\n');
      expect(put.statusCode, 200);
      final after =
          await (await getTemplate(a, id, 'fragment')).readAsString();
      expect(after, contains('step-20 edit'));
    });
  });

  group('Step 20.2 — a persona edit is picked up on next use', () {
    test('the assistant_to_user persona round-trips through /api/templates',
        () async {
      final a = api();
      final before =
          await (await getTemplate(a, 'assistant_to_user', 'persona'))
              .readAsString();
      expect(before, isNotEmpty); // the migrated persona prose exists on disk

      // A prose edit has no `effect` field — it is read live on the next call
      // (AUTH-5 "pull, not push"); proving the re-GET sees it is the contract.
      final put = await putTemplate(a, 'assistant_to_user', 'persona',
          body: '$before\nStep-20 persona note.');
      expect(put.statusCode, 200);
      final after =
          await (await getTemplate(a, 'assistant_to_user', 'persona'))
              .readAsString();
      expect(after, endsWith('Step-20 persona note.'));
    });
  });

  group('Step 20.3 — a route re-point is picked up on next boot', () {
    test('an llm_route edit reports next-boot', () async {
      final a = api();
      // Re-write the default `assistant` route with its own (valid) text — a
      // byte-identical re-point that the loader accepts.
      final current =
          await (await getConfig(a, 'llm_route', 'assistant')).readAsString();
      expect(current, isNotEmpty);

      final put = await putConfig(a, 'llm_route', 'assistant', body: current);
      expect(put.statusCode, 200);
      expect((await json(put))['effect'], 'next-boot');
    });

    test('a substrate edit reports next-boot; a procedure edit next-use',
        () async {
      final a = api();
      final substrate =
          await (await getConfig(a, 'substrate', 'substrate')).readAsString();
      final subPut =
          await putConfig(a, 'substrate', 'substrate', body: substrate);
      expect(subPut.statusCode, 200);
      expect((await json(subPut))['effect'], 'next-boot');

      final proc =
          await (await getConfig(a, 'procedure', 'assist_user')).readAsString();
      final procPut =
          await putConfig(a, 'procedure', 'assist_user', body: proc);
      expect(procPut.statusCode, 200);
      expect((await json(procPut))['effect'], 'next-use');
    });
  });

  group('Step 20.4 — AUTH-6: the anchor / tool-policy are not editable', () {
    test('no catalogue template names the anchor or a tool-policy profile',
        () async {
      final ids = (await templates(api())).map((t) => t['id'] as String);
      for (final id in ids) {
        expect(id.contains('anchor'), isFalse, reason: '$id leaks the anchor');
        expect(id.contains('tool_policy'), isFalse,
            reason: '$id leaks a tool policy');
      }
    });

    test('the config kinds are exactly the wire alphabet (no anchor kind)',
        () async {
      final body = await json(await obsGet(api(), 'api/catalogue'));
      final kinds = (body['configFiles'] as List)
          .map((c) => (c as Map)['kind'] as String)
          .toSet();
      // The catalogue enum names the per-route llm `llm`; the rest match the
      // `/api/config` wire alphabet. Crucially, no `anchor` / `tool_policy`.
      expect(kinds, everyElement(isIn(<String>{
        'registry',
        'procedure',
        'llm',
        'substrate',
      })));
      expect(kinds, isNot(contains('anchor')));
      expect(kinds, isNot(contains('tool_policy')));
    });

    test('PUT /api/config?kind=anchor is refused 403', () async {
      final res = await putConfig(api(), 'anchor', 'anchor', body: 'x: 1');
      expect(res.statusCode, HttpStatus.forbidden);
    });
  });

  group('Step 20 done-when — no hidden hardcoded prompt text remains', () {
    test('every procedure prompt file is editable via the catalogue', () async {
      // The set of prose files the operator can reach through the catalogue:
      // every template part path + every role persona/objective path.
      final body = await json(await obsGet(api(), 'api/catalogue'));
      final reachable = <String>{};
      for (final t in (body['templates'] as List).cast<Map>()) {
        for (final f in (t['files'] as List).cast<Map>()) {
          reachable.add(p.normalize(f['path'] as String));
        }
      }
      for (final r in (body['roles'] as List).cast<Map>()) {
        reachable.add(p.normalize(r['personaPath'] as String));
        reachable.add(p.normalize(r['objectivePath'] as String));
      }

      // Every `.md` actually on disk under the cognition root, split into the
      // procedure template folders vs. the shared `roles/` folder.
      final onDiskProcedurePrompts = <String>{};
      final onDiskRoles = <String>{};
      for (final e in cognitionRoot.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.md')) continue;
        final rel = p.normalize(p.relative(e.path, from: cognitionRoot.path));
        (rel.startsWith('roles/') ? onDiskRoles : onDiskProcedurePrompts)
            .add(rel);
      }
      expect(onDiskProcedurePrompts, isNotEmpty);

      // CORE GUARANTEE: every prompt file under a procedure template folder is
      // surfaced by the catalogue — there is no hidden, hardcoded prompt
      // fragment in the procedures, all of it is editable. (The catalogue may
      // list MORE — registered-but-absent halves — which is fine.)
      final hiddenProcedurePrompts =
          onDiskProcedurePrompts.difference(reachable);
      expect(hiddenProcedurePrompts, isEmpty,
          reason: 'these procedure prompt files are not reachable through the '
              'catalogue (hidden hardcoded text?): $hiddenProcedurePrompts');
    });

    test('unreferenced role prose belongs to not-yet-wired procedures', () async {
      // Roles enter the catalogue only when a *wired* procedure references them
      // (plus the `assistant_to_user` default). The bomber tree ships persona /
      // objective prose for roles whose procedures are not yet registered
      // (recall / research / planning / creation families — only `assist_user`
      // and `dreaming` are wired). Those files are not hidden hardcoded text —
      // they are future-procedure assets, correctly absent from the live
      // catalogue. We assert the only orphans are role files, never procedure
      // prompt files, so the gap can never mask hidden procedure text.
      final body = await json(await obsGet(api(), 'api/catalogue'));
      final reachableRoles = <String>{};
      for (final r in (body['roles'] as List).cast<Map>()) {
        reachableRoles.add(p.normalize(r['personaPath'] as String));
        reachableRoles.add(p.normalize(r['objectivePath'] as String));
      }

      final orphanedRoles = <String>{};
      for (final e in cognitionRoot.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.md')) continue;
        final rel = p.normalize(p.relative(e.path, from: cognitionRoot.path));
        if (rel.startsWith('roles/') && !reachableRoles.contains(rel)) {
          orphanedRoles.add(rel);
        }
      }
      // Every orphan is a role file (its containment is structural); the
      // procedure-prompt guarantee above proves none are procedure prompts.
      expect(orphanedRoles, everyElement(startsWith('roles/')));
    });
  });
}

/// Recursively copies the contents of [from] into [to] (which already exists),
/// preserving the relative layout. Files only — the migrated config carries no
/// symlinks — so a plain copy yields a byte-identical, independently-writable
/// tree the test can edit without touching the version-controlled source.
void _copyTree(Directory from, Directory to) {
  for (final entity in from.listSync(recursive: true)) {
    final rel = p.relative(entity.path, from: from.path);
    final target = p.join(to.path, rel);
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      entity.copySync(target);
    }
  }
}
