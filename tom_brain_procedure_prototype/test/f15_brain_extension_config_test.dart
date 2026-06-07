// Extension F step 15 — `ToolPolicyConfig.fromYamlMap` + `BrainExtensionConfig`.
//
// Plan step 15 (verbatim, in part): "Load `prompt_template/`,
// `llm_configuration/`, the `mcpServers:` block, and the `ToolPolicyConfig`
// through the canonical plain-map loader at boot." This suite covers the two
// pure-value pieces that wiring stands on:
//
//   1. `ToolPolicyConfig.fromYamlMap` — the loader the step 5 `ToolPolicyConfig`
//      doc promised "lands in a later Extension F step". It parses the four
//      fields of the `toolPolicy:` block (`default` / `deny` / `groups` /
//      `allow`) from a plain `Map<Object?, Object?>` (never a `YamlMap`), and
//      rejects an unknown profile / unknown group through the shared typed
//      `LlmConfigInvalid`.
//   2. `BrainExtensionConfig` — the declarative config the boot assembles the
//      runtime bundle from. Its derived getters point the layer-1 providers
//      file and the layer-2 models directory under `llm_configuration/`
//      (§ 21.6), and its optional fields default to empty / all-permissive.
//
// The assemble path (turning this config into a live `ToolRegistry` +
// `McpClient` + stores) and the boot threading are exercised by
// `f15_brain_engine_extensions_test.dart` and `f15_brain_boot_extensions_test.dart`.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  group('F15 ToolPolicyConfig.fromYamlMap', () {
    test('parses default profile + deny / groups / allow lists', () {
      final block = loadYamlAsMap(
        '''
default: read_only
deny:
  - vscode.todo.*
groups:
  - memory
  - web
allow:
  - memory.read
  - web.search
''',
        rootPath: 'toolPolicy',
        errorFactory: LlmConfigInvalid.new,
      );

      final config = ToolPolicyConfig.fromYamlMap(block);

      expect(config.defaultProfile, ToolPolicyProfile.readOnly);
      expect(config.deny, <String>['vscode.todo.*']);
      expect(config.enabledGroups, <ToolGroup>{ToolGroup.memory, ToolGroup.web});
      expect(config.allow, <String>['memory.read', 'web.search']);
    });

    test('defaults to profile all + empty lists when keys are absent', () {
      final block = loadYamlAsMap(
        'default: all\n',
        rootPath: 'toolPolicy',
        errorFactory: LlmConfigInvalid.new,
      );

      final config = ToolPolicyConfig.fromYamlMap(block);

      expect(config.defaultProfile, ToolPolicyProfile.all);
      expect(config.deny, isEmpty);
      expect(config.enabledGroups, isEmpty);
      expect(config.allow, isEmpty);
    });

    test('an absent default falls back to the all profile', () {
      final block = loadYamlAsMap(
        'deny: [vscode.todo.*]\n',
        rootPath: 'toolPolicy',
        errorFactory: LlmConfigInvalid.new,
      );

      final config = ToolPolicyConfig.fromYamlMap(block);

      expect(config.defaultProfile, ToolPolicyProfile.all);
      expect(config.deny, <String>['vscode.todo.*']);
    });

    test('an unknown default profile is a located LlmConfigInvalid', () {
      final block = loadYamlAsMap(
        'default: nonsense\n',
        rootPath: 'toolPolicy',
        errorFactory: LlmConfigInvalid.new,
      );

      expect(
        () => ToolPolicyConfig.fromYamlMap(block),
        throwsA(isA<LlmConfigInvalid>()
            .having((e) => e.path, 'path', 'toolPolicy.default')),
      );
    });

    test('an unknown group name is a located LlmConfigInvalid', () {
      final block = loadYamlAsMap(
        '''
default: groups
groups:
  - memory
  - not_a_group
''',
        rootPath: 'toolPolicy',
        errorFactory: LlmConfigInvalid.new,
      );

      expect(
        () => ToolPolicyConfig.fromYamlMap(block),
        throwsA(isA<LlmConfigInvalid>()
            .having((e) => e.path, 'path', 'toolPolicy.groups[1]')),
      );
    });
  });

  group('F15 BrainExtensionConfig value object', () {
    test('derives the providers file + models dir under llm_configuration/', () {
      final config = BrainExtensionConfig(
        promptTemplateDir: Directory('cfg/prompt_template'),
        llmConfigurationDir: Directory('cfg/llm_configuration'),
      );

      expect(
        config.providersFile.path,
        'cfg/llm_configuration${Platform.pathSeparator}providers.yaml',
      );
      expect(
        config.modelsDir.path,
        'cfg/llm_configuration${Platform.pathSeparator}models',
      );
    });

    test('optional fields default to empty / all-permissive', () {
      final config = BrainExtensionConfig(
        promptTemplateDir: Directory('cfg/prompt_template'),
        llmConfigurationDir: Directory('cfg/llm_configuration'),
      );

      expect(config.mcpServers.servers, isEmpty);
      expect(config.toolPolicy.defaultProfile, ToolPolicyProfile.all);
      expect(config.requirePromptTypes, isEmpty);
      expect(config.environment, isNull);
    });

    test('carries through supplied mcpServers / toolPolicy / requirePromptTypes',
        () {
      final config = BrainExtensionConfig(
        promptTemplateDir: Directory('cfg/prompt_template'),
        llmConfigurationDir: Directory('cfg/llm_configuration'),
        mcpServers: McpServersConfig(<McpServerConfig>[
          const McpServerConfig(id: 'memory', transport: McpTransport.http),
        ]),
        toolPolicy: const ToolPolicyConfig(
          defaultProfile: ToolPolicyProfile.readOnly,
        ),
        requirePromptTypes: const <String>{'assistant_to_user'},
      );

      expect(config.mcpServers.byId('memory'), isNotNull);
      expect(config.toolPolicy.defaultProfile, ToolPolicyProfile.readOnly);
      expect(config.requirePromptTypes, <String>{'assistant_to_user'});
    });
  });
}
