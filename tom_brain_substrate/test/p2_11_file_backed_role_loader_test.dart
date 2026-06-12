// File-backed role loader (`prompt_configuration.md` §7.1 / §10 / §11,
// increment 8).
//
// `loadFileBackedRoleRegistry({base, rolesDir})` overlays each role's
// prose onto an arbitrary base roster: `personaText` from
// `<rolesDir>/<role>.persona.md` and `objective` from
// `<rolesDir>/<role>.objective.md`, falling back to the in-code template
// for any role (or half) whose file is absent or blank. The on-disk files
// override only the prose; the capability surface — allowed / forbidden
// actions, output schema, budget defaults — is always retained from the
// in-code base so a markdown file can never widen a role's capability
// surface.
//
// The `AssistantDedicationAnchor` stays injected unconditionally: a
// file-loaded role assembles a prompt through the same
// `RoleTemplate.assemble` path as an in-code role, so every emitted
// `WirePrompt` still starts with the anchor text and records
// `AnchorRegistry.currentHash`.
//
// Scope of this file:
//
//   - roster: the loader preserves the base roster (same ids, same order).
//   - loads-persona: a present `<role>.persona.md` overrides the persona;
//     the override flows into the assembled prompt body.
//   - loads-objective: a present `<role>.objective.md` overrides the
//     objective while leaving the persona on the in-code fallback.
//   - falls-back-when-missing: an absent file (or half) keeps the in-code
//     value; the role still works.
//   - capability-surface-retained: a prose file never changes the
//     allowed / forbidden actions, output schema, or budgets.
//   - anchor-always-present / anchorHash-recorded: every assembled prompt
//     (file-loaded or fallback) starts with `AssistantDedicationAnchor.text`
//     and records `AnchorRegistry.currentHash`.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  late Directory rolesDir;

  setUp(() {
    rolesDir = Directory.systemTemp.createTempSync('p2_11_roles_');
  });

  tearDown(() {
    if (rolesDir.existsSync()) {
      rolesDir.deleteSync(recursive: true);
    }
  });

  void writePersona(String roleId, String text) {
    File('${rolesDir.path}/$roleId.persona.md').writeAsStringSync(text);
  }

  void writeObjective(String roleId, String text) {
    File('${rolesDir.path}/$roleId.objective.md').writeAsStringSync(text);
  }

  group('loadFileBackedRoleRegistry — roster', () {
    test('preserves the base roster (the prototype five plus researcher, '
        '§ 6.2b) in canonical order', () {
      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      expect(registry.ids.toList(), equals(prototypeRoleIds));
      expect(registry.length, equals(6));
    });
  });

  group('loadFileBackedRoleRegistry — loads-persona', () {
    test('a present <role>.persona.md overrides the persona text', () {
      writePersona('analyser', 'CUSTOM ANALYSER VOICE FROM DISK');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );

      expect(
        registry.get('analyser').personaText,
        equals('CUSTOM ANALYSER VOICE FROM DISK'),
      );
    });

    test('the persona override flows into the assembled prompt body', () {
      writePersona('assistant_to_user', 'I am the on-disk assistant voice.');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final prompt = registry.get('assistant_to_user').assemble();

      expect(prompt.body, contains('I am the on-disk assistant voice.'));
    });

    test('file content is trimmed of surrounding whitespace', () {
      writePersona('recaller', '\n\n  trimmed recaller voice  \n\n');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );

      expect(
        registry.get('recaller').personaText,
        equals('trimmed recaller voice'),
      );
    });

    test('only the targeted role is overridden; others fall back', () {
      writePersona('analyser', 'just the analyser');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final bootstrap = bootstrapRoleRegistry();

      expect(registry.get('analyser').personaText, equals('just the analyser'));
      // Every other role keeps its in-code persona.
      for (final id in prototypeRoleIds.where((r) => r != 'analyser')) {
        expect(
          registry.get(id).personaText,
          equals(bootstrap.get(id).personaText),
        );
      }
    });
  });

  group('loadFileBackedRoleRegistry — loads-objective', () {
    test('a present <role>.objective.md overrides the objective text', () {
      writeObjective('analyser', 'CUSTOM ANALYSER OBJECTIVE FROM DISK');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );

      expect(
        registry.get('analyser').objective,
        equals('CUSTOM ANALYSER OBJECTIVE FROM DISK'),
      );
    });

    test('the objective half can be overridden while the persona falls back',
        () {
      writeObjective('evaluator', 'on-disk evaluator objective');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final base = bootstrapRoleRegistry().get('evaluator');
      final loaded = registry.get('evaluator');

      expect(loaded.objective, equals('on-disk evaluator objective'));
      // Persona was not written → in-code fallback.
      expect(loaded.personaText, equals(base.personaText));
    });

    test('persona and objective can both be sourced from disk together', () {
      writePersona('sub_thinker', 'on-disk sub_thinker voice');
      writeObjective('sub_thinker', 'on-disk sub_thinker objective');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final loaded = registry.get('sub_thinker');

      expect(loaded.personaText, equals('on-disk sub_thinker voice'));
      expect(loaded.objective, equals('on-disk sub_thinker objective'));
    });
  });

  group('loadFileBackedRoleRegistry — capability-surface-retained', () {
    test('a file-loaded role retains the in-code capability surface', () {
      writePersona('evaluator', 'on-disk evaluator voice');
      writeObjective('evaluator', 'on-disk evaluator objective');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final base = bootstrapRoleRegistry().get('evaluator');
      final loaded = registry.get('evaluator');

      // Prose changed…
      expect(loaded.personaText, equals('on-disk evaluator voice'));
      expect(loaded.objective, equals('on-disk evaluator objective'));
      // …but the capability surface did not: action policy, output schema
      // and budgets are still the in-code authority.
      expect(loaded.allowedActions, equals(base.allowedActions));
      expect(loaded.forbiddenActions, equals(base.forbiddenActions));
      expect(loaded.outputSchema, equals(base.outputSchema));
      expect(loaded.budgetDefaults, equals(base.budgetDefaults));
    });
  });

  group('loadFileBackedRoleRegistry — falls-back-when-missing', () {
    test('an absent file yields the in-code prose verbatim', () {
      // No files written at all.
      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final bootstrap = bootstrapRoleRegistry();

      for (final id in prototypeRoleIds) {
        expect(
          registry.get(id).personaText,
          equals(bootstrap.get(id).personaText),
          reason: '$id should fall back to its in-code persona',
        );
        expect(
          registry.get(id).objective,
          equals(bootstrap.get(id).objective),
          reason: '$id should fall back to its in-code objective',
        );
      }
    });

    test('a deliberately missing file still yields a working role', () {
      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final prompt = registry.get('sub_thinker').assemble(
        inputs: const <String, Object?>{'sub_question': 'what is x?'},
      );
      expect(prompt.roleId, equals('sub_thinker'));
      expect(prompt.body, isNotEmpty);
    });

    test('a blank / whitespace-only file falls back to the in-code value', () {
      writePersona('recaller', '   \n\t  \n');
      writeObjective('recaller', '   \n\t  \n');

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );
      final bootstrap = bootstrapRoleRegistry();

      expect(
        registry.get('recaller').personaText,
        equals(bootstrap.get('recaller').personaText),
      );
      expect(
        registry.get('recaller').objective,
        equals(bootstrap.get('recaller').objective),
      );
    });

    test('a non-existent roles directory yields a registry identical to base',
        () {
      final missingDir = Directory('${rolesDir.path}/does/not/exist');
      expect(missingDir.existsSync(), isFalse);

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: missingDir,
      );
      final bootstrap = bootstrapRoleRegistry();

      expect(registry.ids.toList(), equals(prototypeRoleIds));
      for (final id in prototypeRoleIds) {
        expect(
          registry.get(id).personaText,
          equals(bootstrap.get(id).personaText),
        );
        expect(registry.get(id).assemble().body, isNotEmpty);
      }
    });

    test('the full live roster is preserved when overlaid file-backed', () {
      // The run wires the loader over the full thirty-role roster; an
      // empty roles dir must leave every role intact and assemble-able.
      final base = bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream();
      final registry = loadFileBackedRoleRegistry(base: base, rolesDir: rolesDir);

      expect(registry.ids.toList(), equals(base.ids.toList()));
      for (final id in base.ids) {
        expect(
          registry.get(id).personaText,
          equals(base.get(id).personaText),
        );
      }
    });
  });

  group('loadFileBackedRoleRegistry — anchor', () {
    test('file-loaded roles still inject the anchor + record the hash', () {
      for (final id in prototypeRoleIds) {
        writePersona(id, 'on-disk voice for $id');
      }

      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );

      for (final id in prototypeRoleIds) {
        final prompt = registry.get(id).assemble();
        expect(
          prompt.body,
          startsWith(AssistantDedicationAnchor.text),
          reason: '$id (file-loaded) must start with the anchor',
        );
        expect(prompt.anchorHash, equals(AnchorRegistry.currentHash));
        // The overridden persona must still be present after the anchor.
        expect(prompt.body, contains('on-disk voice for $id'));
      }
    });

    test('fallback roles also inject the anchor + record the hash', () {
      // No files written: every role is an in-code fallback.
      final registry = loadFileBackedRoleRegistry(
        base: bootstrapRoleRegistry(),
        rolesDir: rolesDir,
      );

      for (final id in prototypeRoleIds) {
        final prompt = registry.get(id).assemble(
          inputs: const <String, Object?>{'k': 'v'},
        );
        expect(prompt.body, startsWith(AssistantDedicationAnchor.text));
        expect(prompt.anchorHash, equals(AnchorRegistry.currentHash));
      }
    });
  });

  group('loadFileBackedRoleRegistry — barrel surface', () {
    test('loader is reachable from the top-level package barrel', () {
      // Compile-time reachability: referencing the symbol here proves it
      // is exported.
      expect(loadFileBackedRoleRegistry, isNotNull);
    });
  });
}
