// Extension F, step 2 — three-layer model configuration acceptance suite
// (`tom_brain_procedure_specification.md` § 21.6, Q-F.2;
// `prototype_tools_mcp_extension_plan.md` step 2).
//
// Pins the two file layers the step owns, both loaded through the
// canonical plain-map loader (`loadYamlAsMap`, no `YamlMap` leak):
//
//   • Layer 1 — Providers (`providers.yaml`): `ProviderRegistry` parses
//     every provider `{id, apiType, baseUrl, apiKey, toolProtocol, free}`.
//     `apiKey` (and `baseUrl`) accept a verbatim string OR `${env:NAME}`,
//     resolved via the step-1 placeholder resolver's env form.
//   • Layer 2 — Model configs (`models/<id>.yaml`): `ModelConfig` carries
//     pure identity + sampling plus a per-provider name map; it names no
//     provider and holds no endpoint/key, so it cannot open an HTTP path.
//
// Plus the two typed missing-file errors (`providers.missing`,
// `model_config.missing`) and the structural-invalid error
// (`llm.config.invalid`), and the recursive "no YAML node leaked into a
// loaded object" invariant the canonical loader guarantees.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Recursively asserts that no `package:yaml` node type (`YamlMap`,
/// `YamlList`, `YamlScalar`) survives anywhere in [value]'s object graph —
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

const _fullProviders = '''
providers:
  - id: omlx
    apiType: openai
    baseUrl: \${env:TOM_BRAIN_OMLX_BASE_URI}
    apiKey: \${env:TOM_BRAIN_OMLX_KEY}
    toolProtocol: openai
    free: true
  - id: ollama
    apiType: ollama
    baseUrl: http://localhost:11434
    toolProtocol: json_text
    free: true
  - id: openrouter
    apiType: openai
    baseUrl: https://openrouter.ai/api/v1
    apiKey: sk-verbatim-key
    toolProtocol: openai
    free: false
''';

const _env = <String, String>{
  'TOM_BRAIN_OMLX_BASE_URI': 'http://127.0.0.1:8080/v1',
  'TOM_BRAIN_OMLX_KEY': 'omlx-secret',
};

const _modelGemma = '''
id: gemma_4_26b
temperature: 0.7
maxTokens: 2048
topP: 0.95
providerNames:
  omlx: gemma-4-26b-a4b-it-4bit
  ollama: gemma2:27b
''';

void main() {
  group('F.2-1 ProviderRegistry — full document', () {
    test('parses every provider field', () async {
      final registry =
          await ProviderRegistry.fromYamlString(_fullProviders, environment: _env);

      expect(registry.providerIds, ['omlx', 'ollama', 'openrouter']);
      expect(registry.contains('omlx'), isTrue);
      expect(registry.contains('absent'), isFalse);
      expect(registry.maybeProvider('absent'), isNull);

      final omlx = registry.maybeProvider('omlx')!;
      expect(omlx.id, 'omlx');
      expect(omlx.apiType, ProviderApiType.openai);
      expect(omlx.toolProtocol, ToolProtocol.openai);
      expect(omlx.free, isTrue);

      final ollama = registry.maybeProvider('ollama')!;
      expect(ollama.apiType, ProviderApiType.ollama);
      expect(ollama.toolProtocol, ToolProtocol.jsonText);
      expect(ollama.baseUrl, Uri.parse('http://localhost:11434'));
    });

    test('env-expands baseUrl and apiKey via the step-1 resolver env form',
        () async {
      final registry =
          await ProviderRegistry.fromYamlString(_fullProviders, environment: _env);
      final omlx = registry.maybeProvider('omlx')!;
      expect(omlx.baseUrl, Uri.parse('http://127.0.0.1:8080/v1'));
      expect(omlx.apiKey, 'omlx-secret');
    });

    test('a verbatim apiKey passes through unchanged', () async {
      final registry =
          await ProviderRegistry.fromYamlString(_fullProviders, environment: _env);
      expect(registry.maybeProvider('openrouter')!.apiKey, 'sk-verbatim-key');
    });

    test('an absent apiKey is null', () async {
      final registry =
          await ProviderRegistry.fromYamlString(_fullProviders, environment: _env);
      expect(registry.maybeProvider('ollama')!.apiKey, isNull);
    });

    test('free defaults to false when omitted', () async {
      const yaml = '''
providers:
  - id: p
    apiType: openai
    baseUrl: https://example.com
    toolProtocol: openai
''';
      final registry = await ProviderRegistry.fromYamlString(yaml);
      expect(registry.maybeProvider('p')!.free, isFalse);
    });
  });

  group('F.2-2 ProviderRegistry — rejections', () {
    test('an unknown apiType is rejected', () {
      const yaml = '''
providers:
  - id: p
    apiType: gibberish
    baseUrl: https://example.com
    toolProtocol: openai
''';
      expect(
        () => ProviderRegistry.fromYamlString(yaml),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });

    test('an unknown toolProtocol is rejected', () {
      const yaml = '''
providers:
  - id: p
    apiType: openai
    baseUrl: https://example.com
    toolProtocol: smoke_signals
''';
      expect(
        () => ProviderRegistry.fromYamlString(yaml),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });

    test('a duplicate provider id is rejected', () {
      const yaml = '''
providers:
  - id: dup
    apiType: openai
    baseUrl: https://a.example.com
    toolProtocol: openai
  - id: dup
    apiType: ollama
    baseUrl: https://b.example.com
    toolProtocol: json_text
''';
      expect(
        () => ProviderRegistry.fromYamlString(yaml),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });

    test('a missing baseUrl is rejected', () {
      const yaml = '''
providers:
  - id: p
    apiType: openai
    toolProtocol: openai
''';
      expect(
        () => ProviderRegistry.fromYamlString(yaml),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });

    test('a missing providers key is rejected', () {
      expect(
        () => ProviderRegistry.fromYamlString('something_else: 1'),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });

    test('a non-list providers value is rejected', () {
      expect(
        () => ProviderRegistry.fromYamlString('providers: not-a-list'),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });
  });

  group('F.2-3 ProviderRegistry.loadFromFile', () {
    test('an absent providers.yaml throws ProvidersMissing', () async {
      final dir = Directory.systemTemp.createTempSync('f2_providers_absent');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/providers.yaml');
      await expectLater(
        ProviderRegistry.loadFromFile(file),
        throwsA(isA<ProvidersMissing>()
            .having((e) => e.code, 'code', 'providers.missing')),
      );
    });

    test('a present providers.yaml loads', () async {
      final dir = Directory.systemTemp.createTempSync('f2_providers_present');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/providers.yaml')
        ..writeAsStringSync(_fullProviders);
      final registry =
          await ProviderRegistry.loadFromFile(file, environment: _env);
      expect(registry.providerIds, ['omlx', 'ollama', 'openrouter']);
    });
  });

  group('F.2-4 ModelConfig', () {
    test('parses identity + sampling + per-provider names', () {
      final model = ModelConfig.fromYamlString(_modelGemma);
      expect(model.id, 'gemma_4_26b');
      expect(model.temperature, 0.7);
      expect(model.maxTokens, 2048);
      expect(model.topP, 0.95);
      expect(model.nameFor('omlx'), 'gemma-4-26b-a4b-it-4bit');
      expect(model.nameFor('ollama'), 'gemma2:27b');
      expect(model.nameFor('unknown'), isNull);
    });

    test('sampling fields are optional', () {
      const yaml = '''
id: bare
providerNames:
  omlx: bare-1
''';
      final model = ModelConfig.fromYamlString(yaml);
      expect(model.temperature, isNull);
      expect(model.maxTokens, isNull);
      expect(model.topP, isNull);
      expect(model.nameFor('omlx'), 'bare-1');
    });

    test('a missing id is rejected', () {
      expect(
        () => ModelConfig.fromYamlString('temperature: 0.5'),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });
  });

  group('F.2-5 ModelConfigStore', () {
    test('an absent models/<id>.yaml throws ModelConfigMissing', () async {
      final dir = Directory.systemTemp.createTempSync('f2_models_absent');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = ModelConfigStore(dir);
      await expectLater(
        store.load('nonexistent'),
        throwsA(isA<ModelConfigMissing>()
            .having((e) => e.code, 'code', 'model_config.missing')
            .having((e) => e.modelId, 'modelId', 'nonexistent')),
      );
    });

    test('a present models/<id>.yaml loads', () async {
      final dir = Directory.systemTemp.createTempSync('f2_models_present');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/gemma_4_26b.yaml').writeAsStringSync(_modelGemma);
      final store = ModelConfigStore(dir);
      final model = await store.load('gemma_4_26b');
      expect(model.id, 'gemma_4_26b');
      expect(model.nameFor('omlx'), 'gemma-4-26b-a4b-it-4bit');
    });
  });

  group('F.2-6 plain-map invariant (no YamlMap/YamlList leak)', () {
    test('no YAML node survives in a loaded provider', () async {
      final registry =
          await ProviderRegistry.fromYamlString(_fullProviders, environment: _env);
      for (final provider in registry.providers) {
        _assertNoYamlNodes(provider.id);
        _assertNoYamlNodes(provider.apiKey);
        _assertNoYamlNodes(provider.baseUrl.toString());
      }
      _assertNoYamlNodes(registry.providers.map((p) => p.id).toList());
    });

    test('no YAML node survives in a loaded model', () {
      final model = ModelConfig.fromYamlString(_modelGemma);
      _assertNoYamlNodes(model.providerNames);
      expect(model.providerNames, isA<Map<String, String>>());
    });
  });
}
