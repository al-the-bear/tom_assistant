// R.46 — stem → template-pair resolution in `CognitionConfigLoader`
// (prompt-restructuring plan step 8 / `prompt_configuration.md` §13.1).
//
// Step 8 makes a registered prompt's `template:` value a **stem**, not a
// filename: a `kind: prompt` resolves the `<stem>.system.md` + `<stem>.user.md`
// pair (an absent half → empty string), a `kind: fragment` the single
// `<stem>.md`. The resolved `ResolvedPrompt.template` carries the file path(s)
// and a present/empty flag per half. A `prompt` whose stem resolves to *neither*
// half — and a `fragment` whose single file is absent — is a fail-fast
// `CognitionConfigException` at load.
//
// The existence flags require I/O, so the loader takes a caller-injected
// `templateExists` probe: `loadFromDir` supplies a real `File.existsSync` probe
// (exercised here over temp dirs), while the pure `parse` defaults to
// "all present" and accepts an injected probe for the fail-fast path.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart';

const String _registryYaml = '''
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

const String _assistUserYaml = '''
llm: default

prompt_analyzer:
  prompts:
    classification:
      template: prompt_analyzer.classification

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly
    tool_catalogue:
      template: answer_with_memory.tool_catalogue
      kind: fragment
''';

/// Creates a temp cognition root with `registry.yaml` + `assist_user.yaml`, then
/// writes only the template files named in [templateFiles] under `assist_user/`.
/// Returns the root path; the directory is torn down by [addTearDown].
String _setUpRoot(List<String> templateFiles) {
  final dir = Directory.systemTemp.createTempSync('r46_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/registry.yaml').writeAsStringSync(_registryYaml);
  File('${dir.path}/assist_user.yaml').writeAsStringSync(_assistUserYaml);
  final folder = Directory('${dir.path}/assist_user')
    ..createSync(recursive: true);
  for (final name in templateFiles) {
    File('${folder.path}/$name').writeAsStringSync('body of $name\n');
  }
  return dir.path;
}

void main() {
  group('R.46 — prompt stem resolves to its system/user pair', () {
    test('both halves present → both paths, both flagged present', () {
      final root = _setUpRoot(const [
        'prompt_analyzer.classification.system.md',
        'prompt_analyzer.classification.user.md',
        'answer_with_memory.assembly.user.md',
        'answer_with_memory.tool_catalogue.md',
      ]);
      final config = CognitionConfigLoader.loadFromDir(root);

      final pair = config
          .resolve('assist_user.prompt_analyzer.classification')
          .template as PromptTemplateFiles;
      expect(pair.system.path,
          'assist_user/prompt_analyzer.classification.system.md');
      expect(pair.system.present, isTrue);
      expect(
          pair.user.path, 'assist_user/prompt_analyzer.classification.user.md');
      expect(pair.user.present, isTrue);
    });

    test('only the user half present → system half flagged empty', () {
      final root = _setUpRoot(const [
        'prompt_analyzer.classification.user.md',
        'answer_with_memory.assembly.user.md',
        'answer_with_memory.tool_catalogue.md',
      ]);
      final config = CognitionConfigLoader.loadFromDir(root);

      final pair = config
          .resolve('assist_user.prompt_analyzer.classification')
          .template as PromptTemplateFiles;
      expect(pair.system.present, isFalse, reason: 'absent → empty half');
      expect(pair.user.present, isTrue);
    });

    test('only the system half present → user half flagged empty', () {
      final root = _setUpRoot(const [
        'prompt_analyzer.classification.system.md',
        'answer_with_memory.assembly.user.md',
        'answer_with_memory.tool_catalogue.md',
      ]);
      final config = CognitionConfigLoader.loadFromDir(root);

      final pair = config
          .resolve('assist_user.prompt_analyzer.classification')
          .template as PromptTemplateFiles;
      expect(pair.system.present, isTrue);
      expect(pair.user.present, isFalse, reason: 'absent → empty half');
    });
  });

  group('R.46 — fragment resolves a single file', () {
    test('a kind: fragment resolves the single <stem>.md', () {
      final root = _setUpRoot(const [
        'prompt_analyzer.classification.user.md',
        'answer_with_memory.assembly.user.md',
        'answer_with_memory.tool_catalogue.md',
      ]);
      final config = CognitionConfigLoader.loadFromDir(root);

      final p = config.resolve('assist_user.answer_with_memory.tool_catalogue');
      expect(p.kind, PromptKind.fragment);
      final frag = p.template as FragmentTemplateFiles;
      expect(frag.file.path, 'assist_user/answer_with_memory.tool_catalogue.md');
      expect(frag.file.present, isTrue);
    });
  });

  group('R.46 — fail-fast when a stem resolves to no file', () {
    test('a prompt whose stem resolves to neither half throws at load', () {
      // The classification pair is absent; both other templates present.
      final root = _setUpRoot(const [
        'answer_with_memory.assembly.user.md',
        'answer_with_memory.tool_catalogue.md',
      ]);
      expect(
        () => CognitionConfigLoader.loadFromDir(root),
        throwsA(
          isA<CognitionConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('neither'),
                contains('prompt_analyzer.classification')),
          ),
        ),
      );
    });

    test('a fragment whose single file is absent throws at load', () {
      final root = _setUpRoot(const [
        'prompt_analyzer.classification.user.md',
        'answer_with_memory.assembly.user.md',
        // tool_catalogue.md deliberately absent
      ]);
      expect(
        () => CognitionConfigLoader.loadFromDir(root),
        throwsA(isA<CognitionConfigException>().having(
          (e) => e.message,
          'message',
          contains('answer_with_memory.tool_catalogue.md'),
        )),
      );
    });

    test('the pure parse fails fast under an injected all-absent probe', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _assistUserYaml},
          templateExists: (_) => false,
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });
  });

  group('R.46 — pure parse defaults to all-present (no disk touch)', () {
    test('every stem resolves and is flagged present without a real probe', () {
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
      );
      final pair = config
          .resolve('assist_user.prompt_analyzer.classification')
          .template as PromptTemplateFiles;
      expect(pair.system.present, isTrue);
      expect(pair.user.present, isTrue);

      final frag = config
          .resolve('assist_user.answer_with_memory.tool_catalogue')
          .template as FragmentTemplateFiles;
      expect(frag.file.present, isTrue);
    });
  });
}
