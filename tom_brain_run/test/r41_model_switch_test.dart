// r41 — `/switch_model` as a normal-config change (request e).
//
// `/switch_model <prompt-id> <provider:model>` is NOT an override layer: it
// re-points one cognition prompt at a chosen model by editing the normal
// cognition configuration on disk — a dedicated single-entry route file plus the
// prompt's `llm:` binding (rewritten comment-preserving) — and mutating the live
// `CognitionConfig` so the change applies on the next run *and* survives a
// restart because the standard loader reads it back at boot. There is no
// separate `model_overrides.yaml`, registry, or synthetic route.
//
// These tests pin the two pieces of that seam:
//
//   * [CognitionModelWriter] — the on-disk + live encoding of a per-prompt model
//     choice (route file, `llm:` binding via yaml_edit, live-config mutation),
//     including that the two `sub.run` resolvers reflect it and that a reload
//     reads it back.
//   * [TomBrainModelSwitcher] — the writer-backed happy path: a validated switch
//     applied through the writer, confirmed, and visible after a reload.

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart'
    show
        BrainBuiltins,
        CognitionConfigLoader,
        CognitionModelWriteException,
        CognitionModelWriter,
        TomBrainModelSwitcher,
        buildPromptResolver,
        buildRouteChainResolver;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        EmbeddingChoice,
        McpClientConfigBlock,
        ProviderAuthConfig,
        ProviderKind,
        ProviderProfile,
        RouteEntry,
        SubstrateConfig,
        WebFetchConfig,
        WebSearchConfig;
import 'package:test/test.dart';

/// The prompt id the tests switch — the committed `answer_with_memory` assembly
/// prompt, whose `llm:` is inherited from the `assist_user` main level.
const String _promptId = 'assist_user.answer_with_memory.assembly';

/// A distinctive comment in the hand-authored main-procedure config file, used
/// to assert `yaml_edit` left every comment intact across the binding rewrite.
const String _signatureComment =
    '# A hand-authored, heavily commented main-procedure config.';

/// Scaffolds a minimal but real cognition tree under [root]: `registry.yaml`,
/// the commented `assist_user.yaml` main-procedure config, the assembly
/// template, and the default `assistant` route. Returns nothing — callers load
/// it with [CognitionConfigLoader.loadFromDir].
void _scaffoldCognition(Directory root) {
  File('${root.path}/registry.yaml').writeAsStringSync('''
# Cognition config root index.
procedures:
  assist_user:
    config: assist_user.yaml
    folder: assist_user
roles:
  folder: roles
llm:
  folder: llm
  default: assistant
''');

  File('${root.path}/assist_user.yaml').writeAsStringSync('''
$_signatureComment
#
# Main-level settings are inherited by every sub-procedure and prompt beneath.

tools: all
llm: assistant
role: assistant_to_user

answer_with_memory:
  prompts:
    # The assembly prompt — this is the node /switch_model re-points.
    assembly:
      template: answer_with_memory.assembly
''');

  Directory('${root.path}/assist_user').createSync(recursive: true);
  File('${root.path}/assist_user/answer_with_memory.assembly.user.md')
      .writeAsStringSync(r'Answer: ${text}');

  Directory('${root.path}/llm').createSync(recursive: true);
  File('${root.path}/llm/assistant.yaml').writeAsStringSync('''
# The default assistant route.
route:
  - provider: omlx
    model: gemma-4-26b-a4b-it-4bit
''');
}

/// A substrate config advertising one Ollama provider with the switch target
/// model (`ollama:gemma3:27b`) — the valid provider/model space the switcher
/// validates against.
SubstrateConfig _substrateConfig() => SubstrateConfig(
      providers: [
        ProviderProfile(
          id: 'ollama',
          kind: ProviderKind.ollama,
          auth: ProviderAuthConfig.none,
          baseUrl: Uri.parse('http://127.0.0.1:11434'),
          models: const ['gemma3:27b', 'nomic-embed-text'],
        ),
      ],
      roleRoutes: const {},
      embedding: const EmbeddingChoice(
        providerId: 'ollama',
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      ),
      webSearch: const WebSearchConfig(defaultProvider: 'ddg', providers: {}),
      webFetch: const WebFetchConfig(),
      mcpClient: const McpClientConfigBlock(),
    );

BrainBuiltins _builtins(String configRoot) => BrainBuiltins(
      hostname: 'bomber',
      trailFolder: '',
      configFolder: configRoot,
      memoryRoot: '/tmp/mem',
      scriptsFolder: '/tmp/scripts',
    );

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('model_switch_');
    _scaffoldCognition(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('CognitionModelWriter.apply', () {
    test('MSW-1: writes a single-entry route file named after the prompt', () {
      final config = CognitionConfigLoader.loadFromDir(root.path);
      CognitionModelWriter(cognitionRoot: root.path, config: config).apply(
        promptId: _promptId,
        providerId: 'ollama',
        model: 'gemma3:27b',
      );

      final routeFile = File('${root.path}/llm/$_promptId.yaml');
      expect(routeFile.existsSync(), isTrue);
      final text = routeFile.readAsStringSync();
      expect(text, contains('provider: ollama'));
      expect(text, contains('model: gemma3:27b'));
    });

    test('MSW-2: rewrites the prompt\'s llm binding, preserving all comments',
        () {
      final config = CognitionConfigLoader.loadFromDir(root.path);
      CognitionModelWriter(cognitionRoot: root.path, config: config).apply(
        promptId: _promptId,
        providerId: 'ollama',
        model: 'gemma3:27b',
      );

      final mainConfig =
          File('${root.path}/assist_user.yaml').readAsStringSync();
      // The one node changed: the assembly prompt now names its dedicated route.
      expect(mainConfig, contains('llm: $_promptId'));
      // Every hand-authored comment survives the surgical edit.
      expect(mainConfig, contains(_signatureComment));
      expect(mainConfig,
          contains('# The assembly prompt — this is the node'));
    });

    test('MSW-3: mutates the live config so the resolvers reflect the switch '
        'with no re-wiring', () async {
      final config = CognitionConfigLoader.loadFromDir(root.path);
      CognitionModelWriter(cognitionRoot: root.path, config: config).apply(
        promptId: _promptId,
        providerId: 'ollama',
        model: 'gemma3:27b',
      );

      // The route-chain resolver expands the dedicated route to the new model.
      final routeChainOf = buildRouteChainResolver(config);
      final List<RouteEntry> chain = routeChainOf(_promptId);
      expect(chain, hasLength(1));
      expect(chain.single.providerId, 'ollama');
      expect(chain.single.model, 'gemma3:27b');

      // The prompt resolver now routes the switched prompt over that route.
      final resolve = buildPromptResolver(config, _builtins(root.path));
      final resolved = await resolve(_promptId, {'text': 'hi'});
      expect(resolved, isNotNull);
      expect(resolved!.llmRoute, _promptId);
    });

    test('MSW-4: the switch survives a restart (a fresh load reads it back)',
        () {
      final config = CognitionConfigLoader.loadFromDir(root.path);
      CognitionModelWriter(cognitionRoot: root.path, config: config).apply(
        promptId: _promptId,
        providerId: 'ollama',
        model: 'gemma3:27b',
      );

      // A brand-new load (as a process restart would do) reads the rewritten
      // config: the prompt's binding and the dedicated route are both on disk.
      final reloaded = CognitionConfigLoader.loadFromDir(root.path);
      expect(reloaded.resolve(_promptId).settings.llm, _promptId);
      final route = reloaded.route(_promptId);
      expect(route.route.single.providerId, 'ollama');
      expect(route.route.single.model, 'gemma3:27b');
    });

    test('MSW-5: a missing main-procedure file raises a located exception', () {
      final config = CognitionConfigLoader.loadFromDir(root.path);
      // Remove the main-procedure config the binding rewrite needs.
      File('${root.path}/assist_user.yaml').deleteSync();

      expect(
        () => CognitionModelWriter(cognitionRoot: root.path, config: config)
            .apply(promptId: _promptId, providerId: 'ollama', model: 'gemma3:27b'),
        throwsA(isA<CognitionModelWriteException>()),
      );
    });
  });

  group('TomBrainModelSwitcher (/switch_model) — writer-backed happy path', () {
    test('MSW-6: a valid switch is applied through the writer and confirmed to '
        'survive a restart', () async {
      final config = CognitionConfigLoader.loadFromDir(root.path);
      final switcher = TomBrainModelSwitcher(
        cognition: config,
        substrate: _substrateConfig(),
        writer: CognitionModelWriter(cognitionRoot: root.path, config: config),
      );

      // A model name carrying a colon (gemma3:27b) is split on the FIRST colon.
      final text = await switcher.switchModel(
        promptId: _promptId,
        modelId: 'ollama:gemma3:27b',
      );

      expect(text, contains(_promptId));
      expect(text, contains('ollama:gemma3:27b'));
      expect(text, contains('survives a restart'));

      // The change is on disk: a fresh load routes the prompt at the new model.
      final reloaded = CognitionConfigLoader.loadFromDir(root.path);
      expect(reloaded.resolve(_promptId).settings.llm, _promptId);
      expect(reloaded.route(_promptId).route.single.model, 'gemma3:27b');
    });
  });
}
