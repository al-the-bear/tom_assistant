// CognitionConfig.catalogue — increment/plan step 13 of
// `prompt_configuration.md` (§13.4 *The registry is the manifest — every
// template is observatory-discoverable*).
//
// `catalogue()` exposes, from a parsed `CognitionConfig` and with no further
// I/O, the data the observatory catalogue route (plan step 14) serves:
//
//   • every registered template — its full ID, kind (prompt / fragment), and
//     resolved file path(s) with per-half present/empty flags (the flags the
//     loader already resolved against the on-disk tree, §8 step 8);
//   • the role prose files — persona/objective paths under the registry roles
//     folder, one entry per role referenced by any prompt plus the foundational
//     `assistant_to_user` default;
//   • the config-file inventory — `registry.yaml`, each `<proc>.yaml`, each
//     loaded `llm/<name>.yaml`, and the `substrate:` block location.
//
// ── What this suite proves ───────────────────────────────────────────
//
//   Group A — templates: every registered prompt + fragment is listed, in ID
//   order; a prompt lists its system+user pair, a fragment its single file; an
//   absent pair half is reported `present == false` while its sibling is
//   `present == true`.
//
//   Group B — roles: the distinct prompt roles plus the `assistant_to_user`
//   default are listed (in name order) with persona/objective paths under the
//   roles folder.
//
//   Group C — config inventory: registry.yaml, every procedure config, every
//   loaded llm route, and the substrate block are all present; the substrate
//   entry carries the run-config file + the `substrate` within-file location.

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_run/tom_brain_run.dart';

void main() {
  late CognitionConfig config;

  setUp(() {
    final Directory dir = Directory.systemTemp.createTempSync('cognition_cat_');
    addTearDown(() => dir.deleteSync(recursive: true));
    _writeTree(dir);
    config = CognitionConfigLoader.loadFromDir(dir.path);
  });

  group('catalogue — templates (§13.4 step 13)', () {
    test('lists every registered template incl. the fragment, in ID order', () {
      final catalogue = config.catalogue();
      expect(
        catalogue.templates.map((t) => t.id).toList(),
        <String>[
          'assist_user.answer_with_memory.assembly',
          'assist_user.answer_with_memory.tool_catalogue',
          'assist_user.answer_with_thinking.analysis',
        ],
        reason: 'every prompt + fragment, sorted by full ID',
      );

      final kinds = <String, PromptKind>{
        for (final t in catalogue.templates) t.id: t.kind,
      };
      expect(kinds['assist_user.answer_with_memory.assembly'], PromptKind.prompt);
      expect(kinds['assist_user.answer_with_memory.tool_catalogue'],
          PromptKind.fragment);
    });

    test('a prompt lists its system+user pair; a fragment its single file', () {
      final catalogue = config.catalogue();

      final assembly = catalogue.templates
          .firstWhere((t) => t.id == 'assist_user.answer_with_memory.assembly');
      expect(assembly.files.map((f) => f.part).toList(),
          <CataloguePart>[CataloguePart.system, CataloguePart.user]);
      expect(assembly.files[0].path,
          'assist_user/answer_with_memory.assembly.system.md');
      expect(assembly.files[1].path,
          'assist_user/answer_with_memory.assembly.user.md');

      final fragment = catalogue.templates.firstWhere(
          (t) => t.id == 'assist_user.answer_with_memory.tool_catalogue');
      expect(fragment.files, hasLength(1));
      expect(fragment.files.single.part, CataloguePart.fragment);
      expect(fragment.files.single.path,
          'assist_user/answer_with_memory.tool_catalogue.md');
      expect(fragment.files.single.present, isTrue);
    });

    test('an absent pair half is reported empty, its sibling present', () {
      // `analysis` ships only the `.user.md` half — the `.system.md` is absent.
      final analysis = config.catalogue().templates
          .firstWhere((t) => t.id == 'assist_user.answer_with_thinking.analysis');
      final system =
          analysis.files.firstWhere((f) => f.part == CataloguePart.system);
      final user =
          analysis.files.firstWhere((f) => f.part == CataloguePart.user);
      expect(system.present, isFalse, reason: 'the absent half is empty');
      expect(user.present, isTrue, reason: 'the present half is reported present');
    });
  });

  group('catalogue — role prose files (§13.4 step 13)', () {
    test('lists distinct prompt roles + the assistant_to_user default', () {
      final roles = config.catalogue().roles;
      // `analysis` sets `role: analyser`; every other prompt inherits the
      // default. So both `analyser` and the foundational default appear.
      expect(roles.map((r) => r.name).toList(),
          <String>['analyser', 'assistant_to_user']);

      final analyser = roles.firstWhere((r) => r.name == 'analyser');
      expect(analyser.personaPath, 'roles/analyser.persona.md');
      expect(analyser.objectivePath, 'roles/analyser.objective.md');
    });

    test('the default role is always listed even if no prompt names it', () {
      // A config where every prompt inherits the default: the default is still
      // present (it is the anchor-bearing role, always editable).
      final Directory dir =
          Directory.systemTemp.createTempSync('cognition_cat_dflt_');
      addTearDown(() => dir.deleteSync(recursive: true));
      _writeTree(dir, omitExplicitRole: true);
      final c = CognitionConfigLoader.loadFromDir(dir.path);

      expect(c.catalogue().roles.map((r) => r.name).toList(),
          <String>['assistant_to_user']);
    });
  });

  group('catalogue — config inventory (§13.4 step 13)', () {
    test('lists registry, each procedure config, each loaded llm route', () {
      final configs = config.catalogue().configFiles;

      final registry =
          configs.firstWhere((c) => c.kind == CatalogueConfigKind.registry);
      expect(registry.path, 'registry.yaml');

      final proc =
          configs.firstWhere((c) => c.kind == CatalogueConfigKind.procedure);
      expect(proc.name, 'assist_user');
      expect(proc.path, 'assist_user.yaml');

      final route = configs.firstWhere((c) => c.kind == CatalogueConfigKind.llm);
      expect(route.name, 'default');
      expect(route.path, 'llm/default.yaml');
    });

    test('the substrate block carries the run-config file + within-file location',
        () {
      final substrate = config
          .catalogue()
          .configFiles
          .firstWhere((c) => c.kind == CatalogueConfigKind.substrate);
      expect(substrate.path, 'brain_run.yaml');
      expect(substrate.location, 'substrate');
    });

    test('the substrate run-config file is caller-overridable', () {
      final substrate = config
          .catalogue(substrateConfigFile: 'bomber.brain.yaml')
          .configFiles
          .firstWhere((c) => c.kind == CatalogueConfigKind.substrate);
      expect(substrate.path, 'bomber.brain.yaml');
    });
  });
}

/// Writes a minimal cognition tree: `registry.yaml`, `assist_user.yaml`, the
/// `assist_user/` template files (one full pair, one user-only pair, one
/// fragment) and `llm/default.yaml`. When [omitExplicitRole] is set, the
/// `analysis` prompt does not set `role:` (so every prompt inherits the
/// default).
void _writeTree(Directory root, {bool omitExplicitRole = false}) {
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

  final String roleLine = omitExplicitRole ? '' : '      role: analyser\n';
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
$roleLine''');

  final Directory folder = Directory('${root.path}/assist_user')
    ..createSync();
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
