// BrainExtensionConfig — the declarative Extension-F config the boot assembles
// the runtime bundle from (Plan step 15; `…_specification.md` § 13, § 21.5,
// § 21.6).
//
// Step 13 names two new config folders loaded "by the same plain-map YAML
// path" the engine/dispatcher configs use: `prompt_template/` (§ 21.5) and
// `llm_configuration/` (§ 21.6, the three layers — `providers.yaml` +
// `models/<id>.yaml`). Plus the `mcpServers:` block (§ 21.6, already a parsed
// [McpServersConfig]) and the `ToolPolicyConfig` (§ 21.8). This value object is
// the *declarative input* gathering those four — directory locations and the
// two parsed blocks — that [BrainEngineExtensions.assemble] turns into the live
// `ToolRegistry` + `McpClient` + config-store bundle.
//
// It holds **paths and parsed config**, never opened resources: assembling
// (loading the providers registry, eagerly validating required prompt types,
// building the MCP client) is `assemble`'s job, so a config can be constructed
// and inspected without touching the filesystem or a socket.

import 'dart:io';

import '../mcp/mcp_server_config.dart' show McpServerConfig, McpServersConfig;
import '../tools/tool_policy_config.dart' show ToolPolicyConfig;

/// The declarative Extension-F configuration: the two config directories plus
/// the parsed `mcpServers:` + `ToolPolicyConfig` blocks and the set of prompt
/// types to validate eagerly at boot.
final class BrainExtensionConfig {
  /// Builds an extension config.
  ///
  /// [promptTemplateDir] is the `prompt_template/` folder (§ 21.5);
  /// [llmConfigurationDir] is the `llm_configuration/` folder holding
  /// `providers.yaml` + `models/` (§ 21.6). [mcpServers] is the parsed
  /// `mcpServers:` block (defaults to none); [toolPolicy] is the global tool
  /// policy (defaults to the all-permissive [ToolPolicyConfig.new]).
  /// [requirePromptTypes] names the prompt types
  /// [BrainEngineExtensions.assemble] resolves at boot so a missing template /
  /// unresolvable model fails fast (defaults to none). [environment] resolves
  /// `${env:NAME}` tokens in the providers file (defaults to the process
  /// environment when `null`).
  BrainExtensionConfig({
    required this.promptTemplateDir,
    required this.llmConfigurationDir,
    McpServersConfig? mcpServers,
    this.toolPolicy = const ToolPolicyConfig(),
    this.requirePromptTypes = const <String>{},
    this.environment,
  }) : mcpServers = mcpServers ?? McpServersConfig(const <McpServerConfig>[]);

  /// The `prompt_template/` directory (one `<type>.yaml` per prompt type).
  final Directory promptTemplateDir;

  /// The `llm_configuration/` directory (holds `providers.yaml` + `models/`).
  final Directory llmConfigurationDir;

  /// The parsed `mcpServers:` registry the MCP client is built over.
  final McpServersConfig mcpServers;

  /// The global tool-access policy (§ 21.8).
  final ToolPolicyConfig toolPolicy;

  /// Prompt types resolved eagerly at boot, so a missing template or an
  /// unresolvable model surfaces before any run (and any substrate call).
  final Set<String> requirePromptTypes;

  /// The environment used to resolve `${env:NAME}` in the providers file, or
  /// `null` for the process environment.
  final Map<String, String>? environment;

  /// The layer-1 providers file (`<llm_configuration>/providers.yaml`).
  File get providersFile => File(
        '${llmConfigurationDir.path}${Platform.pathSeparator}providers.yaml',
      );

  /// The layer-2 model-config directory (`<llm_configuration>/models`).
  Directory get modelsDir => Directory(
        '${llmConfigurationDir.path}${Platform.pathSeparator}models',
      );
}
