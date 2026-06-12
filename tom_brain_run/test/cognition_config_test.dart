// Cognition registry + config loader — increment 3 of `prompt_configuration.md`
// (§4 *The registry*, §5 *Main-procedure config & hierarchical IDs* + §5.5
// *Realisation*, §12 step 3).
//
// `CognitionConfigLoader` parses `registry.yaml` plus the main-procedure config
// files it references into a `CognitionConfig`: a `CognitionRegistry` (the index
// of procedures + role/llm folders) and a flat map of `ResolvedPrompt`s keyed by
// the full `<main>.<sub>.<prompt>` ID, each carrying a fully-inherited
// `PromptSettings`.
//
// ── What this suite proves ───────────────────────────────────────────
//
//   Group A — registry parse: the `procedures` map (name → config + folder),
//   the roles folder, the llm folder + default route name.
//
//   Group B — flattening / hierarchy lookup: every `<main>.<sub>.<prompt>` ID is
//   registered; `resolve` returns the parts + folder-relative template path +
//   kind.
//
//   Group C — inheritance precedence: prompt → sub-procedure → main-procedure,
//   with the `llm` route falling back to the registry default when unset.
//
//   Group D — fail-fast validation: unregistered ID → `UnregisteredPromptException`;
//   missing `template` key → `CognitionConfigException`; a duplicate YAML mapping
//   key (duplicate sub/prompt) → `CognitionConfigException`; an unknown setting
//   key → located `CognitionConfigException`.
//
//   Group E — `loadFromDir`: reads `registry.yaml` + each referenced config off
//   disk and produces the same flattened config.

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_run/tom_brain_run.dart';

void main() {
  group('CognitionRegistry — registry.yaml parse', () {
    test('reads procedures, roles folder, and llm folder + default', () {
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
      );
      final registry = config.registry;
      expect(registry.procedures.keys, contains('assist_user'));
      final proc = registry.procedures['assist_user']!;
      expect(proc.name, 'assist_user');
      expect(proc.configFile, 'assist_user.yaml');
      expect(proc.folder, 'assist_user');
      expect(registry.rolesFolder, 'roles');
      expect(registry.llmFolder, 'llm');
      expect(registry.llmDefault, 'default');
    });
  });

  group('CognitionConfig — flattening + hierarchy lookup', () {
    late CognitionConfig config;
    setUp(() {
      config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
      );
    });

    test('registers every full <main>.<sub>.<prompt> ID', () {
      expect(
        config.promptIds.toSet(),
        <String>{
          'assist_user.prompt_analyzer.classification',
          'assist_user.answer_with_thinking.analysis',
          'assist_user.answer_with_thinking.synthesis',
          'assist_user.answer_with_memory.assembly',
          'assist_user.answer_with_memory.tool_catalogue',
        },
      );
    });

    test('resolve returns the ID parts, template path, and kind', () {
      final p = config.resolve('assist_user.prompt_analyzer.classification');
      expect(p.id, 'assist_user.prompt_analyzer.classification');
      expect(p.mainProcedure, 'assist_user');
      expect(p.subProcedure, 'prompt_analyzer');
      expect(p.promptName, 'classification');
      expect(p.templatePath, 'assist_user/prompt_analyzer.classification.md');
      expect(p.kind, PromptKind.prompt);
    });

    test('a fragment carries kind = fragment', () {
      final p = config.resolve('assist_user.answer_with_memory.tool_catalogue');
      expect(p.kind, PromptKind.fragment);
    });
  });

  group('PromptSettings — inheritance precedence', () {
    late CognitionConfig config;
    setUp(() {
      config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
      );
    });

    test('prompt-level overrides win over sub and main', () {
      final s = config
          .resolve('assist_user.prompt_analyzer.classification')
          .settings;
      expect(s.temperature, 0.0); // prompt override
      expect(s.maxToolLoops, 1); // prompt override
      expect(s.tools, const ToolsNone()); // prompt override
      expect(s.llm, 'default'); // inherited from main
    });

    test('sub-procedure level overrides main, inherits the rest', () {
      final s =
          config.resolve('assist_user.answer_with_thinking.analysis').settings;
      expect(s.temperature, 0.5); // sub-level override
      expect(s.tools, const ToolsReadonly()); // prompt-level
      expect(s.maxToolLoops, 6); // inherited from main
      expect(s.llm, 'default'); // inherited from main
    });

    test('main-procedure defaults flow down when nothing overrides', () {
      final s =
          config.resolve('assist_user.answer_with_memory.assembly').settings;
      expect(s.temperature, 1.0); // main default
      expect(s.maxToolLoops, 6); // main default
      expect(s.tools, isA<ToolsExplicit>());
      expect((s.tools as ToolsExplicit).names, ['recall', 'search']);
    });

    test('all tool set forms parse', () {
      expect(
        config.resolve('assist_user.answer_with_thinking.synthesis').settings.tools,
        const ToolsAll(),
      );
    });

    test('llm falls back to the registry default when unset in the chain', () {
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _noLlmYaml},
      );
      expect(
        config.resolve('assist_user.answer_with_memory.assembly').settings.llm,
        'default',
      );
    });
  });

  group('CognitionConfig — fail-fast validation', () {
    test('resolve throws UnregisteredPromptException for an unknown ID', () {
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
      );
      expect(
        () => config.resolve('assist_user.answer_with_memory.nope'),
        throwsA(isA<UnregisteredPromptException>()),
      );
    });

    test('a prompt missing its template key fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _missingTemplateYaml},
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });

    test('a duplicate prompt mapping key fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _duplicateKeyYaml},
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });

    test('an unknown per-prompt setting key fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _unknownSettingYaml},
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });

    test('a referenced procedure config that is missing fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: const {},
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });
  });

  group('CognitionConfigLoader.loadFromDir', () {
    test('reads registry + procedure configs off disk', () async {
      final dir = await Directory.systemTemp.createTemp('cognition_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/registry.yaml').writeAsStringSync(_registryYaml);
      File('${dir.path}/assist_user.yaml').writeAsStringSync(_assistUserYaml);

      final config = CognitionConfigLoader.loadFromDir(dir.path);
      expect(
        config.promptIds,
        contains('assist_user.answer_with_memory.assembly'),
      );
      expect(
        config
            .resolve('assist_user.prompt_analyzer.classification')
            .settings
            .temperature,
        0.0,
      );
    });
  });
}

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
temperature: 1.0
max_tool_loops: 6
tools: all
llm: default

prompt_analyzer:
  prompts:
    classification:
      template: prompt_analyzer.classification.md
      tools: none
      max_tool_loops: 1
      temperature: 0.0

answer_with_thinking:
  temperature: 0.5
  prompts:
    analysis:
      template: answer_with_thinking.analysis.md
      tools: readonly
    synthesis:
      template: answer_with_thinking.synthesis.md
      tools: all

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly.md
      tools: [recall, search]
    tool_catalogue:
      template: answer_with_memory.tool_catalogue.md
      kind: fragment
''';

/// No `llm:` anywhere — the resolved route must fall back to the registry
/// default.
const String _noLlmYaml = '''
temperature: 1.0
max_tool_loops: 6

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly.md
''';

/// A prompt with no `template` key — fail fast at load.
const String _missingTemplateYaml = '''
answer_with_memory:
  prompts:
    assembly:
      tools: all
''';

/// Two prompts with the same mapping key — a duplicate YAML key.
const String _duplicateKeyYaml = '''
answer_with_memory:
  prompts:
    assembly:
      template: a.md
    assembly:
      template: b.md
''';

/// A per-prompt setting key outside the allowed set.
const String _unknownSettingYaml = '''
answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly.md
      bogus_setting: 7
''';
