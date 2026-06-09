// Extension F step 15 — `BrainEngineExtensions.assemble` from on-disk fixtures.
//
// Plan step 15 *Test* (verbatim): "boot assembles the registry + client +
// configs from fixtures; a missing prompt-template/model-config surfaces the
// typed error before any substrate call."
//
// `BrainEngineExtensions.assemble(BrainExtensionConfig, connector: …)` is the
// pure (substrate-free) half of that: given a `llm_configuration/` +
// `prompt_template/` directory pair, it builds the live runtime bundle the
// engine holds — a `ToolRegistry` (basic tools registered), an `McpClient`
// over the configured servers, and the three config stores
// (`PromptTemplateStore` / `ModelConfigStore` / `ProviderRegistry`). Eager
// validation of `requirePromptTypes` makes a missing template / unresolvable
// model surface its typed error *here*, before any run (and therefore before
// any `sub.llm` call) — the "before any substrate call" half of the clause.
//
// The MCP connector is a stub (mirrors `f8_mcp_bridge_test.dart`), so this
// suite touches no socket and no `dart_mcp` type; `close()` is proven to close
// the client by opening one pooled connection first.

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  late Directory root;

  setUp(() async {
    final base = Directory('ztmp/f15_extensions');
    await base.create(recursive: true);
    root = await base.createTemp('run_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Writes a minimal valid `llm_configuration/` + `prompt_template/` set under
  /// [root] and returns the matching [BrainExtensionConfig]. The prompt type
  /// `assistant_to_user` resolves the model `gemma` on provider `local`.
  Future<BrainExtensionConfig> writeValidFixture({
    Set<String> requirePromptTypes = const <String>{},
    McpServersConfig? mcpServers,
    bool writeProviders = true,
    bool writeModel = true,
    bool writeTemplate = true,
  }) async {
    final llmDir = Directory('${root.path}/llm_configuration');
    final modelsDir = Directory('${llmDir.path}/models');
    final templateDir = Directory('${root.path}/prompt_template');
    await modelsDir.create(recursive: true);
    await templateDir.create(recursive: true);

    if (writeProviders) {
      await File('${llmDir.path}/providers.yaml').writeAsString('''
providers:
  - id: local
    apiType: openai
    baseUrl: http://localhost:11434/v1
    toolProtocol: openai
    free: true
''');
    }
    if (writeModel) {
      await File('${modelsDir.path}/gemma.yaml').writeAsString('''
id: gemma
temperature: 0.2
providerNames:
  local: gemma3:27b
''');
    }
    if (writeTemplate) {
      await File('${templateDir.path}/assistant_to_user.yaml').writeAsString('''
id: assistant_to_user
role: assistant_to_user
models:
  - { config: gemma, provider: local }
system: |
  \${prompt}
user: |
  \${prompt}
''');
    }

    return BrainExtensionConfig(
      promptTemplateDir: templateDir,
      llmConfigurationDir: llmDir,
      mcpServers: mcpServers ?? McpServersConfig(const <McpServerConfig>[]),
      requirePromptTypes: requirePromptTypes,
    );
  }

  group('F15-1 assemble builds the runtime bundle', () {
    test('registry, client, and config stores are all assembled', () async {
      final config = await writeValidFixture(
        mcpServers: McpServersConfig(<McpServerConfig>[
          const McpServerConfig(id: 'memory', transport: McpTransport.http),
        ]),
      );

      final extensions = await BrainEngineExtensions.assemble(
        config,
        connector: _StubConnector(_StubConnection()),
      );
      addTearDown(extensions.close);

      // The basic tool set is registered (registerBasicTools, § 21.4).
      expect(extensions.tools.names, isNotEmpty);
      // The MCP client advertises the configured server.
      expect(extensions.mcp.servers().map((s) => s['id']), contains('memory'));
      // The three config stores point at the fixture directories.
      expect(extensions.providers.contains('local'), isTrue);
      expect(
        extensions.modelConfigs.directory.path,
        endsWith('models'),
      );
      expect(
        extensions.promptTemplates.directory.path,
        endsWith('prompt_template'),
      );
      // The tool policy carries through (default: all here).
      expect(extensions.toolPolicy.defaultProfile, ToolPolicyProfile.all);
    });

    test('a required prompt type resolves cleanly against the providers', () async {
      final config = await writeValidFixture(
        requirePromptTypes: const <String>{'assistant_to_user'},
      );

      final extensions = await BrainEngineExtensions.assemble(
        config,
        connector: _StubConnector(_StubConnection()),
      );
      addTearDown(extensions.close);

      expect(extensions.providers.contains('local'), isTrue);
    });
  });

  group('F15-2 typed config failures surface before any substrate call', () {
    test('an absent providers.yaml throws ProvidersMissing', () async {
      final config = await writeValidFixture(writeProviders: false);

      expect(
        () => BrainEngineExtensions.assemble(
          config,
          connector: _StubConnector(_StubConnection()),
        ),
        throwsA(isA<ProvidersMissing>()),
      );
    });

    test('a required-but-absent prompt template throws PromptTemplateMissing',
        () async {
      final config = await writeValidFixture(
        requirePromptTypes: const <String>{'does_not_exist'},
      );

      expect(
        () => BrainEngineExtensions.assemble(
          config,
          connector: _StubConnector(_StubConnection()),
        ),
        throwsA(isA<PromptTemplateMissing>()
            .having((e) => e.type, 'type', 'does_not_exist')),
      );
    });

    test('a required template referencing a missing model throws '
        'LlmConfigInvalid', () async {
      // The template names model `gemma`, but no `models/gemma.yaml` exists:
      // resolve() catches the ModelConfigMissing and rethrows it as a located
      // LlmConfigInvalid (an unknown config id is a hard, located error).
      final config = await writeValidFixture(
        writeModel: false,
        requirePromptTypes: const <String>{'assistant_to_user'},
      );

      expect(
        () => BrainEngineExtensions.assemble(
          config,
          connector: _StubConnector(_StubConnection()),
        ),
        throwsA(isA<LlmConfigInvalid>()),
      );
    });
  });

  group('F15-3 close tears the MCP client down', () {
    test('close() closes every pooled MCP connection', () async {
      final connection = _StubConnection();
      final config = await writeValidFixture(
        mcpServers: McpServersConfig(<McpServerConfig>[
          const McpServerConfig(id: 'memory', transport: McpTransport.http),
        ]),
      );

      final extensions = await BrainEngineExtensions.assemble(
        config,
        connector: _StubConnector(connection),
      );

      // Open + pool one connection through the client.
      await extensions.mcp.listTools('memory');
      expect(connection.closeCount, 0);

      await extensions.close();
      expect(connection.closeCount, 1);
    });
  });
}

/// A stub MCP connection: records calls and returns canned tool/result data.
/// Mirrors the `_StubConnection` of `f8_mcp_bridge_test.dart`.
final class _StubConnection implements McpServerConnection {
  int closeCount = 0;

  @override
  Future<List<Map<String, Object?>>> listTools() async =>
      const <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> callTool(
    String name,
    Map<String, Object?> args,
  ) async =>
      const <String, Object?>{};

  @override
  Future<void> close() async {
    closeCount++;
  }
}

/// A stub connector handing back a single [_StubConnection]. Mirrors the
/// `_StubConnector` of `f8_mcp_bridge_test.dart`.
final class _StubConnector implements McpConnector {
  _StubConnector(this._connection);

  final McpServerConnection _connection;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async =>
      _connection;
}
