// Extension F, step 3 — prompt-template loader acceptance suite
// (`tom_brain_procedure_prototype_specification.md` § 21.5, § 21.6;
// `prototype_tools_mcp_extension_plan.md` step 3).
//
// Pins the `prompt_template/` config layer (layer 3 of the three-layer
// model configuration), loaded through the canonical plain-map loader
// (`loadYamlAsMap`, no `YamlMap` leak):
//
//   • `PromptTemplateConfig` parses `id`, `role`, the ordered `models`
//     chain (`{config, provider}` pairs), the `tools` / `mcpServers`
//     default sets, the `toolPolicy` profile, the optional `setup` d4rt
//     script, and the `system` / `user` scaffolds (kept verbatim, so
//     their `${…}` placeholders survive untouched at load).
//   • `resolve(ProviderRegistry, ModelConfigStore)` walks the chain and
//     binds the first reachable `(config, provider)` pair to a concrete
//     provider connection (layer 1) + provider-specific model name
//     (layer-2 `providerNames`) + sampling (layer 2). A pair whose model
//     is simply not offered on its provider is a soft fallback to the
//     next pair; a pair naming an id that does not exist (unknown
//     provider, unknown config) is a hard, located `llm.config.invalid`.
//   • `prompt_template.missing` typed error for an absent template file,
//     surfaced by both `loadFromFile` and `PromptTemplateStore.load`.

import 'dart:io';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Recursively asserts no `package:yaml` node type survives in [value] —
/// the § 21.6 "no `YamlMap` leak" guarantee of the canonical loader.
void _assertNoYamlNodes(Object? value) {
  expect(value, isNot(isA<YamlMap>()));
  expect(value, isNot(isA<YamlList>()));
  expect(value, isNot(isA<YamlScalar>()));
  if (value is Map) {
    for (final entry in value.entries) {
      _assertNoYamlNodes(entry.key);
      _assertNoYamlNodes(entry.value);
    }
  } else if (value is Iterable) {
    for (final element in value) {
      _assertNoYamlNodes(element);
    }
  }
}

const _fullTemplate = r'''
id: assistant_to_user
role: assistant_to_user
models:
  - { config: gemma_4_26b, provider: omlx }
  - { config: gemma_4_26b, provider: ollama }
tools:
  - memory.read
  - web.search
  - web.fetch
mcpServers:
  - memory
toolPolicy: read_only
setup: |
  final citations = recalled.map((n) => n.title).join(', ');
system: |
  ${role.anchor}
  You are answering the user. Cited memory: ${citations}
  ${{ tools.isEmpty ? 'No tools available.' : 'Tools available; call one when useful.' }}
user: |
  ${prompt}
''';

const _minimalTemplate = r'''
id: bare
role: assistant_to_user
models:
  - { config: gemma_4_26b, provider: ollama }
system: |
  ${role.anchor}
user: |
  ${prompt}
''';

/// A providers registry covering `omlx` (openai) + `ollama` — both
/// verbatim local URLs so no `${env:…}` expansion is needed.
Future<ProviderRegistry> _registry() => ProviderRegistry.fromYamlString('''
providers:
  - id: omlx
    apiType: openai
    baseUrl: http://localhost:8080
    toolProtocol: openai
    free: true
  - id: ollama
    apiType: ollama
    baseUrl: http://localhost:11434
    toolProtocol: json_text
    free: true
''');

/// Builds a throwaway `models/` directory holding one `<id>.yaml`, and
/// returns a store over it. The fixture is deleted on test teardown.
ModelConfigStore _modelStore(String id, String yaml) {
  final dir = Directory.systemTemp.createTempSync('f3_models_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}${Platform.pathSeparator}$id.yaml').writeAsStringSync(yaml);
  return ModelConfigStore(dir);
}

const _modelOnBoth = '''
id: gemma_4_26b
temperature: 0.7
maxTokens: 2048
topP: 0.95
providerNames:
  omlx: gemma-4-26b-a4b-it-4bit
  ollama: gemma2:27b
''';

void main() {
  group('F.3-1 prompt template parse', () {
    test('a full template parses every field', () {
      final t = PromptTemplateConfig.fromYamlString(_fullTemplate);
      expect(t.id, 'assistant_to_user');
      expect(t.role, 'assistant_to_user');
      expect(t.models, hasLength(2));
      expect(t.models[0].config, 'gemma_4_26b');
      expect(t.models[0].provider, 'omlx');
      expect(t.models[1].provider, 'ollama');
      expect(t.tools, ['memory.read', 'web.search', 'web.fetch']);
      expect(t.mcpServers, ['memory']);
      expect(t.toolPolicy, ToolPolicyProfile.readOnly);
      expect(t.setup, contains('citations'));
    });

    test('the scaffolds survive as placeholder-bearing strings', () {
      final t = PromptTemplateConfig.fromYamlString(_fullTemplate);
      expect(t.system, contains(r'${role.anchor}'));
      expect(t.system, contains(r'${citations}'));
      expect(t.system, contains(r'${{'));
      expect(t.user, contains(r'${prompt}'));
    });

    test('a minimal template defaults the optional sets', () {
      final t = PromptTemplateConfig.fromYamlString(_minimalTemplate);
      expect(t.tools, isEmpty);
      expect(t.mcpServers, isEmpty);
      expect(t.toolPolicy, isNull);
      expect(t.setup, isNull);
      expect(t.models, hasLength(1));
    });

    test('no YAML node leaks into the parsed models chain', () {
      final t = PromptTemplateConfig.fromYamlString(_fullTemplate);
      for (final ref in t.models) {
        _assertNoYamlNodes(ref.config);
        _assertNoYamlNodes(ref.provider);
      }
      _assertNoYamlNodes(t.tools);
      _assertNoYamlNodes(t.mcpServers);
    });
  });

  group('F.3-2 reject malformed templates', () {
    // A "located" error names the offending field in its rendered form —
    // either in `path` (loader-thrown) or in the message (reader-thrown,
    // where the dotted location is embedded), both visible via toString().
    void rejects(String yaml, String pathFragment) {
      expect(
        () => PromptTemplateConfig.fromYamlString(yaml),
        throwsA(
          isA<LlmConfigInvalid>()
              .having((e) => e.code, 'code', llmConfigInvalidCode)
              .having((e) => e.toString(), 'toString', contains(pathFragment)),
        ),
      );
    }

    test('missing id', () {
      rejects('role: r\nmodels:\n  - { config: c, provider: p }\nsystem: s\nuser: u\n', 'prompt_template.id');
    });

    test('missing role', () {
      rejects('id: x\nmodels:\n  - { config: c, provider: p }\nsystem: s\nuser: u\n', 'prompt_template.role');
    });

    test('missing models', () {
      rejects('id: x\nrole: r\nsystem: s\nuser: u\n', 'prompt_template.models');
    });

    test('empty models chain', () {
      rejects('id: x\nrole: r\nmodels: []\nsystem: s\nuser: u\n', 'prompt_template.models');
    });

    test('a model entry that is not a mapping', () {
      rejects('id: x\nrole: r\nmodels:\n  - just-a-string\nsystem: s\nuser: u\n', 'prompt_template.models[0]');
    });

    test('a model entry missing config', () {
      rejects('id: x\nrole: r\nmodels:\n  - { provider: p }\nsystem: s\nuser: u\n', 'prompt_template.models[0].config');
    });

    test('a model entry missing provider', () {
      rejects('id: x\nrole: r\nmodels:\n  - { config: c }\nsystem: s\nuser: u\n', 'prompt_template.models[0].provider');
    });

    test('missing system scaffold', () {
      rejects('id: x\nrole: r\nmodels:\n  - { config: c, provider: p }\nuser: u\n', 'prompt_template.system');
    });

    test('missing user scaffold', () {
      rejects('id: x\nrole: r\nmodels:\n  - { config: c, provider: p }\nsystem: s\n', 'prompt_template.user');
    });

    test('an unknown toolPolicy value', () {
      rejects(
        'id: x\nrole: r\nmodels:\n  - { config: c, provider: p }\ntoolPolicy: nonesuch\nsystem: s\nuser: u\n',
        'prompt_template.toolPolicy',
      );
    });

    test('a non-string tools entry', () {
      rejects(
        'id: x\nrole: r\nmodels:\n  - { config: c, provider: p }\ntools:\n  - 42\nsystem: s\nuser: u\n',
        'prompt_template.tools[0]',
      );
    });
  });

  group('F.3-3 missing-file error + store', () {
    test('loadFromFile on an absent file throws PromptTemplateMissing', () {
      final dir = Directory.systemTemp.createTempSync('f3_tpl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}gone.yaml');
      expect(
        PromptTemplateConfig.loadFromFile(file),
        throwsA(
          isA<PromptTemplateMissing>()
              .having((e) => e.code, 'code', promptTemplateMissingCode),
        ),
      );
    });

    test('loadFromFile on a present file parses it', () async {
      final dir = Directory.systemTemp.createTempSync('f3_tpl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}assistant_to_user.yaml')
        ..writeAsStringSync(_fullTemplate);
      final t = await PromptTemplateConfig.loadFromFile(file);
      expect(t.id, 'assistant_to_user');
    });

    test('PromptTemplateStore.load resolves <type>.yaml; absent type throws', () async {
      final dir = Directory.systemTemp.createTempSync('f3_tpl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}${Platform.pathSeparator}assistant_to_user.yaml')
          .writeAsStringSync(_fullTemplate);
      final store = PromptTemplateStore(dir);
      final t = await store.load('assistant_to_user');
      expect(t.id, 'assistant_to_user');
      expect(
        store.load('unknown_type'),
        throwsA(isA<PromptTemplateMissing>()),
      );
    });
  });

  group('F.3-4 chain resolution', () {
    test('the first reachable pair wins', () async {
      final t = PromptTemplateConfig.fromYamlString(_fullTemplate);
      final resolved = await t.resolve(await _registry(),
          _modelStore('gemma_4_26b', _modelOnBoth));
      expect(resolved.provider.id, 'omlx');
      expect(resolved.modelName, 'gemma-4-26b-a4b-it-4bit');
      expect(resolved.model.temperature, 0.7);
      expect(resolved.model.maxTokens, 2048);
    });

    test('a pair whose model is not offered there falls through to the next', () async {
      // Model is named only on ollama; the first pair (omlx) has no name,
      // so resolution falls back to the second pair (ollama).
      final t = PromptTemplateConfig.fromYamlString(_fullTemplate);
      final store = _modelStore('gemma_4_26b', '''
id: gemma_4_26b
temperature: 0.5
providerNames:
  ollama: gemma2:27b
''');
      final resolved = await t.resolve(await _registry(), store);
      expect(resolved.provider.id, 'ollama');
      expect(resolved.modelName, 'gemma2:27b');
      expect(resolved.model.temperature, 0.5);
    });

    test('an unknown provider id is rejected with a located error', () async {
      final t = PromptTemplateConfig.fromYamlString('''
id: x
role: r
models:
  - { config: gemma_4_26b, provider: nonesuch }
system: s
user: u
''');
      await expectLater(
        t.resolve(await _registry(), _modelStore('gemma_4_26b', _modelOnBoth)),
        throwsA(
          isA<LlmConfigInvalid>()
              .having((e) => e.code, 'code', llmConfigInvalidCode)
              .having((e) => e.path, 'path', contains('provider')),
        ),
      );
    });

    test('an unknown model config id is rejected with a located error', () async {
      final t = PromptTemplateConfig.fromYamlString('''
id: x
role: r
models:
  - { config: not_a_model, provider: omlx }
system: s
user: u
''');
      await expectLater(
        t.resolve(await _registry(), _modelStore('gemma_4_26b', _modelOnBoth)),
        throwsA(
          isA<LlmConfigInvalid>()
              .having((e) => e.code, 'code', llmConfigInvalidCode)
              .having((e) => e.path, 'path', contains('config')),
        ),
      );
    });

    test('no reachable pair (model offered on no listed provider) is a located error', () async {
      final t = PromptTemplateConfig.fromYamlString('''
id: x
role: r
models:
  - { config: gemma_4_26b, provider: omlx }
  - { config: gemma_4_26b, provider: ollama }
system: s
user: u
''');
      final store = _modelStore('gemma_4_26b', '''
id: gemma_4_26b
providerNames:
  openrouter: some/name
''');
      await expectLater(
        t.resolve(await _registry(), store),
        throwsA(
          isA<LlmConfigInvalid>()
              .having((e) => e.path, 'path', contains('prompt_template.models')),
        ),
      );
    });
  });
}
