// BrainEngineExtensions — the assembled Extension-F runtime bundle the engine
// holds (Plan step 15; `…_specification.md` § 13, § 21.5, § 21.6).
//
// Step 15 threads "the `ToolRegistry`, `McpClient`, `PromptTemplateConfig` set,
// and `ModelConfig` set into the engine host so `call_llm_v1` can read them".
// This is that bundle: a shared, run-independent collaborator the
// `ProcedureEngine` carries (optionally — the prototype's `answer_with_memory_v1`
// runs without it) and a future `call_llm_v1` reads to drive the scripted LLM
// loop. It owns no per-run state; the per-run `ToolBridge` / `McpBridge` (with
// their budget + file-scope + role binding) are built per run, not here.
//
// [assemble] is the single build path: it registers the basic tool set, loads
// the layer-1 provider registry (a hard [ProvidersMissing] when absent), opens
// the lazy layer-2 model store + prompt-template store, eagerly resolves every
// [BrainExtensionConfig.requirePromptTypes] (so a missing template or an
// unresolvable model surfaces *before* any run, hence before any substrate
// call), and builds the [McpClient] over the configured servers and the
// injected [McpConnector]. [close] tears the MCP client's connection pool down
// at shutdown.

import '../config/model_config.dart' show ModelConfigStore;
import '../config/prompt_template_config.dart'
    show PromptTemplateConfig, PromptTemplateStore;
import '../config/provider_config.dart' show ProviderRegistry;
import '../mcp/mcp_client.dart' show McpClient, McpConnector;
import '../tools/basic_tools.dart' show registerBasicTools;
import '../tools/tool_policy_config.dart' show ToolPolicyConfig;
import '../tools/tool_registry.dart' show ToolRegistry;
import 'brain_extension_config.dart';

/// The assembled Extension-F runtime bundle: the tool registry, the MCP client,
/// the three config stores, and the global tool policy. Built once per process
/// by [assemble] and held by the engine as a shared collaborator.
final class BrainEngineExtensions {
  /// Wraps the assembled parts. Use [assemble] to build from a
  /// [BrainExtensionConfig]; this constructor is for tests that supply doubles.
  BrainEngineExtensions({
    required this.tools,
    required this.mcp,
    required this.promptTemplates,
    required this.modelConfigs,
    required this.providers,
    required this.toolPolicy,
  });

  /// The registry the `tool.list` / `tool.invoke` primitives read.
  final ToolRegistry tools;

  /// The client the `mcp.servers` / `mcp.list` / `mcp.call` primitives run on.
  final McpClient mcp;

  /// The layer-3 prompt-template store (`<type>.yaml`, § 21.5).
  final PromptTemplateStore promptTemplates;

  /// The layer-2 model-config store (`models/<id>.yaml`, § 21.6).
  final ModelConfigStore modelConfigs;

  /// The layer-1 provider registry (`providers.yaml`, § 21.6).
  final ProviderRegistry providers;

  /// The global tool-access policy (§ 21.8).
  final ToolPolicyConfig toolPolicy;

  /// Assembles the runtime bundle from [config] and an MCP [connector].
  ///
  /// Order:
  ///   1. register the basic tool set (`registerBasicTools`, § 21.4);
  ///   2. load the layer-1 provider registry — a **hard** [ProvidersMissing]
  ///      when `providers.yaml` is absent (the substrate router needs it);
  ///   3. open the lazy layer-2 model store + layer-3 prompt-template store;
  ///   4. eagerly resolve each [BrainExtensionConfig.requirePromptTypes] —
  ///      a missing template throws [PromptTemplateMissing]; a template that
  ///      references an unknown model throws [LlmConfigInvalid]. Both surface
  ///      here, before any run and therefore before any substrate call;
  ///   5. build the [McpClient] over the configured servers and [connector].
  static Future<BrainEngineExtensions> assemble(
    BrainExtensionConfig config, {
    required McpConnector connector,
  }) async {
    // 1. Tools — the basic set the scripted loop calls (§ 21.4).
    final tools = ToolRegistry();
    registerBasicTools(tools);

    // 2. Providers (layer 1) — hard ProvidersMissing when absent.
    final providers = await ProviderRegistry.loadFromFile(
      config.providersFile,
      environment: config.environment,
    );

    // 3. Lazy stores — neither touches disk until a load.
    final modelConfigs = ModelConfigStore(config.modelsDir);
    final promptTemplates = PromptTemplateStore(config.promptTemplateDir);

    // 4. Eager validation of the required prompt types, before any run.
    for (final type in config.requirePromptTypes) {
      final PromptTemplateConfig template = await promptTemplates.load(type);
      await template.resolve(providers, modelConfigs);
    }

    // 5. The MCP client over the configured servers.
    final mcp = McpClient(config.mcpServers, connector);

    return BrainEngineExtensions(
      tools: tools,
      mcp: mcp,
      promptTemplates: promptTemplates,
      modelConfigs: modelConfigs,
      providers: providers,
      toolPolicy: config.toolPolicy,
    );
  }

  /// Tears the MCP client's connection pool down (process shutdown). Idempotent
  /// — delegates to [McpClient.close], which no-ops a second call.
  Future<void> close() => mcp.close();
}
