// Cognition LLM route configs — increment 4 of `prompt_configuration.md`
// (§8 *LLM configuration*, §8.1 *Realisation*, §12 step 4).
//
// The named `cognition/llm/<name>.yaml` route configs are parsed into the
// `CognitionConfig` so a prompt references a route **by name** via its inherited
// `llm:` setting. A route config is an ordered `route:` chain of
// `{provider, model, conditions?}` entries (the substrate `RoleRouteEntryConfig`
// shape), preserved in rotation order.
//
// ── What this suite proves ───────────────────────────────────────────
//
//   Group A — route parse + resolution by name: `route(name)` returns the named
//   chain; `routeForPrompt` resolves a prompt's inherited `llm:` to its route.
//
//   Group B — rotation order preserved: the `route:` list order is carried
//   verbatim into `LlmRouteConfig.route`; `conditions.maxInputTokens` parses.
//
//   Group C — fail-fast validation: an unknown route name → `UnknownLlmRouteException`;
//   a missing registry default route, a prompt referencing an unloaded route, a
//   route entry missing `provider`/`model`, and an empty `route:` list each →
//   `CognitionConfigException`.
//
//   Group D — `loadFromDir` reads the `llm/` folder off disk.
//
//   Group E — no `llm/` folder loaded: routes are empty and route resolution
//   throws on demand (the increment-3 pure-registry parse stays valid).

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show RoleRouteEntryConfig;

void main() {
  group('LlmRouteConfig — parse + resolution by name', () {
    late CognitionConfig config;
    setUp(() {
      config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
        llmRouteConfigs: {
          'default': _defaultRouteYaml,
          'local_fast': _localFastRouteYaml,
        },
      );
    });

    test('route(name) returns the named chain', () {
      final route = config.route('default');
      expect(route.name, 'default');
      expect(route.route, isA<List<RoleRouteEntryConfig>>());
      expect(route.route.first.providerId, 'omlx');
      expect(route.route.first.model, 'gemma-4-26b-a4b-it-4bit');
    });

    test('llmRouteNames lists every loaded route', () {
      expect(config.llmRouteNames.toSet(), {'default', 'local_fast'});
    });

    test('routeForPrompt resolves a prompt inheriting the main default route',
        () {
      final prompt = config.resolve('assist_user.answer_with_memory.assembly');
      expect(prompt.settings.llm, 'default'); // inherited from main
      expect(config.routeForPrompt(prompt).name, 'default');
    });

    test('routeForPrompt follows a prompt-level llm override', () {
      final prompt =
          config.resolve('assist_user.prompt_analyzer.classification');
      expect(prompt.settings.llm, 'local_fast'); // prompt override
      expect(config.routeForPrompt(prompt).name, 'local_fast');
    });
  });

  group('LlmRouteConfig — rotation order + conditions', () {
    test('the route: list order is preserved verbatim', () {
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
        llmRouteConfigs: {
          'default': _defaultRouteYaml,
          'local_fast': _localFastRouteYaml,
        },
      );
      final entries = config.route('default').route;
      expect(
        entries.map((e) => '${e.providerId}/${e.model}').toList(),
        [
          'omlx/gemma-4-26b-a4b-it-4bit',
          'openrouter/gpt-4o-mini',
          'groq/llama-3.3-70b',
        ],
      );
    });

    test('conditions.maxInputTokens parses on the entry that carries it', () {
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
        llmRouteConfigs: {
          'default': _defaultRouteYaml,
          'local_fast': _localFastRouteYaml,
        },
      );
      final entries = config.route('default').route;
      expect(entries[0].conditions, isNull);
      expect(entries[1].conditions?.maxInputTokens, 8192);
    });
  });

  group('LlmRouteConfig — fail-fast validation', () {
    test('route(name) throws UnknownLlmRouteException for an unloaded route', () {
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
        llmRouteConfigs: {
          'default': _defaultRouteYaml,
          'local_fast': _localFastRouteYaml,
        },
      );
      expect(
        () => config.route('nope'),
        throwsA(isA<UnknownLlmRouteException>()),
      );
    });

    test('a missing registry default route fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _assistUserYaml},
          // `default` (the registry default) is not loaded.
          llmRouteConfigs: {'local_fast': _localFastRouteYaml},
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });

    test('a prompt referencing an unloaded route fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _assistUserYaml},
          // `local_fast` (referenced by classification) is not loaded.
          llmRouteConfigs: {'default': _defaultRouteYaml},
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });

    test('a route entry missing provider/model fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _assistUserYaml},
          llmRouteConfigs: {
            'default': _malformedRouteYaml,
            'local_fast': _localFastRouteYaml,
          },
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });

    test('an empty route: list fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _assistUserYaml},
          llmRouteConfigs: {
            'default': _emptyRouteYaml,
            'local_fast': _localFastRouteYaml,
          },
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });

    test('an unknown route row key fails at load', () {
      expect(
        () => CognitionConfigLoader.parse(
          registryYaml: _registryYaml,
          procedureConfigs: {'assist_user.yaml': _assistUserYaml},
          llmRouteConfigs: {
            'default': _unknownRowKeyYaml,
            'local_fast': _localFastRouteYaml,
          },
        ),
        throwsA(isA<CognitionConfigException>()),
      );
    });
  });

  group('CognitionConfigLoader.loadFromDir — llm/ folder', () {
    test('reads the llm/<name>.yaml route configs off disk', () async {
      final dir = await Directory.systemTemp.createTemp('cognition_llm_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/registry.yaml').writeAsStringSync(_registryYaml);
      File('${dir.path}/assist_user.yaml').writeAsStringSync(_assistUserYaml);
      Directory('${dir.path}/llm').createSync();
      File('${dir.path}/llm/default.yaml').writeAsStringSync(_defaultRouteYaml);
      File('${dir.path}/llm/local_fast.yaml')
          .writeAsStringSync(_localFastRouteYaml);

      final config = CognitionConfigLoader.loadFromDir(dir.path);
      expect(config.llmRouteNames.toSet(), {'default', 'local_fast'});
      expect(config.route('default').route.first.providerId, 'omlx');
    });
  });

  group('CognitionConfig — no llm/ folder loaded', () {
    test('routes are empty and route() throws on demand', () {
      // A pure registry+procedure parse (no route configs) — the increment-3
      // shape. No cross-check runs; route resolution throws on demand.
      final config = CognitionConfigLoader.parse(
        registryYaml: _registryYaml,
        procedureConfigs: {'assist_user.yaml': _assistUserYaml},
      );
      expect(config.llmRouteNames, isEmpty);
      expect(
        () => config.route('default'),
        throwsA(isA<UnknownLlmRouteException>()),
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

/// classification overrides `llm: local_fast`; everything else inherits the
/// main-level `llm: default`.
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
      llm: local_fast

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly.md
''';

const String _defaultRouteYaml = '''
route:
  - provider: omlx
    model: gemma-4-26b-a4b-it-4bit
  - provider: openrouter
    model: gpt-4o-mini
    conditions:
      maxInputTokens: 8192
  - provider: groq
    model: llama-3.3-70b
''';

const String _localFastRouteYaml = '''
route:
  - provider: ollama
    model: gemma2:2b
''';

/// An entry with no `model`.
const String _malformedRouteYaml = '''
route:
  - provider: omlx
''';

/// An empty `route:` list.
const String _emptyRouteYaml = '''
route: []
''';

/// A route row with a key outside {provider, model, conditions}.
const String _unknownRowKeyYaml = '''
route:
  - provider: omlx
    model: gemma-4-26b-a4b-it-4bit
    bogus: 7
''';
