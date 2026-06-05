// Plan-2 item 11 — file-backed role loader.
//
// `loadFileBackedRoleRegistry({promptsDir})` loads the five prototype
// roles (`assistant_to_user`, `analyser`, `sub_thinker`, `recaller`,
// `evaluator`) from `<promptsDir>/<role>.system.md`, falling back to the
// in-code `bootstrapRoleRegistry()` template whenever a file is absent
// (or blank). The on-disk file overrides only the role's `personaText`
// (its voice); the structured policy — objective, allowed / forbidden
// actions, output schema, budget defaults — is always retained from the
// in-code bootstrap so a markdown file can never widen a role's
// capability surface.
//
// The `AssistantDedicationAnchor` stays injected unconditionally: a
// file-loaded role assembles a prompt through the same
// `RoleTemplate.assemble` path as a bootstrap role, so every emitted
// `WirePrompt` still starts with the anchor text and records
// `AnchorRegistry.currentHash`.
//
// Scope of this file (matching the plan's *Test* line):
//
//   - loads-from-file: a present `<role>.system.md` overrides the
//     persona; the override flows into the assembled prompt body.
//   - falls-back-when-missing: an absent file yields the bootstrap
//     persona verbatim; the role still works.
//   - anchor-always-present: every assembled prompt (file-loaded or
//     fallback) starts with `AssistantDedicationAnchor.text`.
//   - anchorHash-recorded: every assembled prompt's `anchorHash` equals
//     `AnchorRegistry.currentHash`.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  late Directory promptsDir;

  setUp(() {
    promptsDir = Directory.systemTemp.createTempSync('p2_11_prompts_');
  });

  tearDown(() {
    if (promptsDir.existsSync()) {
      promptsDir.deleteSync(recursive: true);
    }
  });

  void writeRoleFile(String roleId, String text) {
    File('${promptsDir.path}/$roleId.system.md').writeAsStringSync(text);
  }

  group('P2.11 / loadFileBackedRoleRegistry — roster', () {
    test('returns all five prototype roles in canonical order', () {
      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);
      expect(registry.ids.toList(), equals(prototypeRoleIds));
      expect(registry.length, equals(5));
    });
  });

  group('P2.11 / loads-from-file', () {
    test('a present <role>.system.md overrides the persona text', () {
      writeRoleFile('analyser', 'CUSTOM ANALYSER VOICE FROM DISK');

      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);

      expect(
        registry.get('analyser').personaText,
        equals('CUSTOM ANALYSER VOICE FROM DISK'),
      );
    });

    test('the file override flows into the assembled prompt body', () {
      writeRoleFile('assistant_to_user', 'I am the on-disk assistant voice.');

      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);
      final prompt = registry.get('assistant_to_user').assemble();

      expect(prompt.body, contains('I am the on-disk assistant voice.'));
    });

    test('file content is trimmed of surrounding whitespace', () {
      writeRoleFile('recaller', '\n\n  trimmed recaller voice  \n\n');

      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);

      expect(
        registry.get('recaller').personaText,
        equals('trimmed recaller voice'),
      );
    });

    test('only the targeted role is overridden; others fall back', () {
      writeRoleFile('analyser', 'just the analyser');

      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);
      final bootstrap = bootstrapRoleRegistry();

      expect(registry.get('analyser').personaText, equals('just the analyser'));
      // Every other role keeps its bootstrap persona.
      for (final id in prototypeRoleIds.where((r) => r != 'analyser')) {
        expect(
          registry.get(id).personaText,
          equals(bootstrap.get(id).personaText),
        );
      }
    });

    test('a file-loaded role retains the bootstrap structured policy', () {
      writeRoleFile('evaluator', 'on-disk evaluator voice');

      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);
      final base = bootstrapRoleRegistry().get('evaluator');
      final loaded = registry.get('evaluator');

      // Persona changed…
      expect(loaded.personaText, equals('on-disk evaluator voice'));
      // …but the contract did not: objective, action policy, output
      // schema and budgets are still the in-code authority.
      expect(loaded.objective, equals(base.objective));
      expect(loaded.allowedActions, equals(base.allowedActions));
      expect(loaded.forbiddenActions, equals(base.forbiddenActions));
      expect(loaded.outputSchema, equals(base.outputSchema));
      expect(loaded.budgetDefaults, equals(base.budgetDefaults));
    });
  });

  group('P2.11 / falls-back-when-missing', () {
    test('an absent file yields the bootstrap persona verbatim', () {
      // No files written at all.
      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);
      final bootstrap = bootstrapRoleRegistry();

      for (final id in prototypeRoleIds) {
        expect(
          registry.get(id).personaText,
          equals(bootstrap.get(id).personaText),
          reason: '$id should fall back to its bootstrap persona',
        );
      }
    });

    test('a deliberately missing file still yields a working role', () {
      // Verify line: a missing file must still produce an assemble-able
      // role via bootstrap.
      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);
      final prompt = registry.get('sub_thinker').assemble(
        inputs: const <String, Object?>{'sub_question': 'what is x?'},
      );
      expect(prompt.roleId, equals('sub_thinker'));
      expect(prompt.body, isNotEmpty);
    });

    test('a blank / whitespace-only file falls back to bootstrap', () {
      writeRoleFile('recaller', '   \n\t  \n');

      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);
      final bootstrap = bootstrapRoleRegistry();

      expect(
        registry.get('recaller').personaText,
        equals(bootstrap.get('recaller').personaText),
      );
    });

    test('a non-existent prompts directory yields the full bootstrap roster',
        () {
      final missingDir = Directory('${promptsDir.path}/does/not/exist');
      expect(missingDir.existsSync(), isFalse);

      final registry = loadFileBackedRoleRegistry(promptsDir: missingDir);
      final bootstrap = bootstrapRoleRegistry();

      expect(registry.ids.toList(), equals(prototypeRoleIds));
      for (final id in prototypeRoleIds) {
        expect(
          registry.get(id).personaText,
          equals(bootstrap.get(id).personaText),
        );
        // Still assemble-able.
        expect(registry.get(id).assemble().body, isNotEmpty);
      }
    });
  });

  group('P2.11 / anchor-always-present + anchorHash-recorded', () {
    test('file-loaded roles still inject the anchor + record the hash', () {
      for (final id in prototypeRoleIds) {
        writeRoleFile(id, 'on-disk voice for $id');
      }

      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);

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
      // No files written: every role is a bootstrap fallback.
      final registry = loadFileBackedRoleRegistry(promptsDir: promptsDir);

      for (final id in prototypeRoleIds) {
        final prompt = registry.get(id).assemble(
          inputs: const <String, Object?>{'k': 'v'},
        );
        expect(prompt.body, startsWith(AssistantDedicationAnchor.text));
        expect(prompt.anchorHash, equals(AnchorRegistry.currentHash));
      }
    });
  });

  group('P2.11 / barrel surface', () {
    test('loader is reachable from the top-level package barrel', () {
      // Compile-time reachability: referencing the symbol here proves it
      // is exported. A direct `package:.../src/...` import would violate
      // the lints/recommended rule.
      expect(loadFileBackedRoleRegistry, isNotNull);
    });
  });
}
