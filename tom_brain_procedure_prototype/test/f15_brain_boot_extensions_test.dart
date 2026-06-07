// Extension F step 15 — boot threads `BrainEngineExtensions` onto the engine.
//
// Plan step 15 *Test* (verbatim): "boot assembles the registry + client +
// configs from fixtures; a missing prompt-template/model-config surfaces the
// typed error before any substrate call."
//
// This suite drives `BrainProcessBoot.boot` with a `BrainProcessConfig` that
// carries the step-15 `extensions` (a `BrainExtensionConfig` over on-disk
// fixtures) + an MCP `connector`, and proves:
//
//   1. Threading — a booted brain exposes the assembled bundle on
//      `booted.engine.extensions` (registry + client + config stores live).
//   2. Eager validation — a required-but-absent prompt template makes boot fail
//      in `BootPhase.engine` (the assemble runs inside engine bring-up, before
//      the access layer and before any run, so before any substrate call),
//      wrapped as a typed `BrainStartupError`.
//   3. Shutdown — `BootedBrain.shutdown` closes the MCP client (every pooled
//      connection), in addition to memory + substrate.
//
// The substrate/memory are minimal lifecycle doubles (no run is accepted here),
// and the MCP connector is a stub (no socket, no `dart_mcp` type).

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig, TomBrainSubstrateClient;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, TomBrainMemoryClient;

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late Directory root;
  late _LifecycleMemory memory;
  late _LifecycleSubstrate substrate;

  setUp(() async {
    final base = Directory('ztmp/f15_boot');
    await base.create(recursive: true);
    root = await base.createTemp('run_');
    memory = _LifecycleMemory();
    substrate = _LifecycleSubstrate();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<BrainExtensionConfig> writeFixture({
    Set<String> requirePromptTypes = const <String>{},
    bool writeTemplate = true,
    McpServersConfig? mcpServers,
  }) async {
    final llmDir = Directory('${root.path}/llm_configuration');
    final modelsDir = Directory('${llmDir.path}/models');
    final templateDir = Directory('${root.path}/prompt_template');
    await modelsDir.create(recursive: true);
    await templateDir.create(recursive: true);

    await File('${llmDir.path}/providers.yaml').writeAsString('''
providers:
  - id: local
    apiType: openai
    baseUrl: http://localhost:11434/v1
    toolProtocol: openai
    free: true
''');
    await File('${modelsDir.path}/gemma.yaml').writeAsString('''
id: gemma
providerNames:
  local: gemma3:27b
''');
    if (writeTemplate) {
      await File('${templateDir.path}/assistant_to_user.yaml').writeAsString('''
id: assistant_to_user
role: assistant_to_user
models:
  - { config: gemma, provider: local }
system: |
  hi
user: |
  hi
''');
    }

    return BrainExtensionConfig(
      promptTemplateDir: templateDir,
      llmConfigurationDir: llmDir,
      mcpServers: mcpServers ?? McpServersConfig(const <McpServerConfig>[]),
      requirePromptTypes: requirePromptTypes,
    );
  }

  BrainProcessConfig configWith({
    required BrainExtensionConfig extensions,
    required McpConnector connector,
  }) =>
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/f15_boot_mem'),
        ),
        extensions: extensions,
        mcpConnector: connector,
      );

  test('boot threads the assembled extensions onto the engine', () async {
    final extensions = await writeFixture(
      mcpServers: McpServersConfig(<McpServerConfig>[
        const McpServerConfig(id: 'memory', transport: McpTransport.http),
      ]),
    );
    final booted = await BrainProcessBoot.boot(
      configWith(extensions: extensions, connector: _StubConnector(_StubConnection())),
    );
    addTearDown(booted.shutdown);

    final bundle = booted.engine.extensions;
    expect(bundle, isNotNull);
    expect(bundle!.tools.names, isNotEmpty);
    expect(bundle.providers.contains('local'), isTrue);
    expect(bundle.mcp.servers().map((s) => s['id']), contains('memory'));
  });

  test('a required-but-absent prompt template fails boot in BootPhase.engine',
      () async {
    final extensions = await writeFixture(
      writeTemplate: false,
      requirePromptTypes: const <String>{'assistant_to_user'},
    );

    await expectLater(
      BrainProcessBoot.boot(
        configWith(
          extensions: extensions,
          connector: _StubConnector(_StubConnection()),
        ),
      ),
      throwsA(isA<BrainStartupError>()
          .having((e) => e.phase, 'phase', BootPhase.engine)
          .having((e) => e.cause, 'cause', isA<PromptTemplateMissing>())),
    );

    // Failure hygiene: the provisioned memory was torn back down.
    expect(memory.closeCount, 1);
  });

  test('shutdown closes the MCP client', () async {
    final connection = _StubConnection();
    final extensions = await writeFixture(
      mcpServers: McpServersConfig(<McpServerConfig>[
        const McpServerConfig(id: 'memory', transport: McpTransport.http),
      ]),
    );
    final booted = await BrainProcessBoot.boot(
      configWith(extensions: extensions, connector: _StubConnector(connection)),
    );

    // Open + pool one MCP connection, then shut down.
    await booted.engine.extensions!.mcp.listTools('memory');
    expect(connection.closeCount, 0);

    await booted.shutdown();
    expect(connection.closeCount, 1);
    expect(memory.closeCount, 1);
    expect(substrate.closeCount, 1);
  });

  test('boot without extensions leaves engine.extensions null', () async {
    final booted = await BrainProcessBoot.boot(
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/f15_boot_mem'),
        ),
      ),
    );
    addTearDown(booted.shutdown);

    expect(booted.engine.extensions, isNull);
  });
}

/// Minimal lifecycle-recording memory double — boot only opens/closes it.
class _LifecycleMemory implements TomBrainMemoryClient {
  int closeCount = 0;

  @override
  Future<void> open(MemoryConfig config) async {}

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Minimal lifecycle-recording substrate double — boot only opens/closes it.
class _LifecycleSubstrate implements TomBrainSubstrateClient {
  int closeCount = 0;

  @override
  Future<void> open(SubstrateConfig config) async {}

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A stub MCP connection mirroring `f8_mcp_bridge_test.dart`.
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

/// A stub MCP connector mirroring `f8_mcp_bridge_test.dart`.
final class _StubConnector implements McpConnector {
  _StubConnector(this._connection);

  final McpServerConnection _connection;

  @override
  Future<McpServerConnection> connect(McpServerConfig config) async =>
      _connection;
}
