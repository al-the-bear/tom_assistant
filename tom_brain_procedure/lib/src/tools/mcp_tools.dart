// McpBrainTool + mergeMcpTools — merging external MCP servers' tools into the
// `ToolRegistry` (`tom_brain_procedure_specification.md` § 21.3, § 21.8;
// `prototype_tools_mcp_extension_plan.md` step 8).
//
// This is the "external MCP servers as part of the tool loop" wiring: each
// advertised tool of each configured server is wrapped as an [McpBrainTool] and
// registered alongside the built-in tools. Because a remote tool's descriptor
// already matches § 21.2's `BrainTool` shape, the merge is uniform — a merged
// MCP tool and a built-in tool are indistinguishable to `tool.list` /
// `tool.invoke`, and the one `ToolPolicy` (step 5) governs both. The model is
// offered the merged tools in the same flat list and calls them through the
// same `tool_loop_v1` send→execute→re-send cycle, with no change to the loop.
//
// A merged tool is a stateless descriptor like every other `BrainTool`: it
// holds the [McpToolDefinition] but captures no live capability. Its effect is
// forwarded through the run's [McpToolSource], reached only via the
// `ToolContext.mcp` surface (PE-1) — the same pattern the `procedure.*` /
// `web.*` / `vscode.*` tools use for their engine / web / extension surfaces.
//
// ── Why this does not double-charge the budget ──────────────────────
//
// A merged tool is invoked through `tool.invoke`, which already charges one
// `toolCalls` unit (the `ToolBridge` pre-charge, PE-8). [run] therefore routes
// the effect through the [McpToolSource] (which calls the client directly) and
// NOT through the `McpBridge` (`mcp.call`, which charges its own unit). The two
// surfaces are alternatives: a script that calls `mcp.call(...)` directly is
// charged by the bridge; a model that calls the merged `mcp__server__tool` is
// charged by `tool.invoke`. Neither path charges twice.

import 'brain_tool.dart';
import 'mcp_tool_source.dart';
import 'tool_context.dart';
import 'tool_failures.dart' show ToolSurfaceUnavailable;
import 'tool_group.dart';
import 'tool_registry.dart';

/// The surface name an [McpBrainTool] reports when its run carries no
/// [ToolContext.mcp] (the `ToolSurfaceUnavailable` discriminator).
const String mcpToolSurfaceName = 'mcp';

/// A built-in-shaped wrapper around one external MCP server tool (§ 21.3).
///
/// Group [ToolGroup.mcp] and (conservatively) `readOnly == false`: a remote
/// tool's descriptor carries no read/write flag, so a merged tool is treated as
/// effectful — under a `read_only` policy it is hidden, the safe default. The
/// name is the definition's namespaced [McpToolDefinition.qualifiedName]; the
/// description / input schema mirror the [McpToolDefinition]; [run] forwards the
/// call through the run's [McpToolSource].
final class McpBrainTool extends BrainTool {
  /// The remote MCP tool this wraps.
  final McpToolDefinition definition;

  /// Wraps [definition] as an `mcp`-group `BrainTool`.
  McpBrainTool(this.definition);

  @override
  String get name => definition.qualifiedName;

  @override
  ToolGroup get group => ToolGroup.mcp;

  @override
  bool get readOnly => false;

  @override
  String get description => definition.description;

  @override
  Map<String, Object?> get inputSchema => definition.inputSchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final source = ctx.mcp;
    if (source == null) {
      throw ToolSurfaceUnavailable(surface: mcpToolSurfaceName, tool: name);
    }
    return source.invokeTool(definition.server, definition.tool, args);
  }
}

/// Merges the [source] MCP servers' tools into [registry] when [enabled].
///
/// [enabled] is the deployment switch: when `false` (no MCP servers configured),
/// this is a no-op and nothing is merged. When `true`, each tool the [source]
/// lists is wrapped as an [McpBrainTool] and registered under its namespaced
/// name. Two servers exposing the same tool name do not clash (the name is
/// namespaced by server); a genuine duplicate (the same server tool listed
/// twice) surfaces as `ToolAlreadyRegistered` through [ToolRegistry.register],
/// exactly as a built-in clash would.
///
/// The [source] is responsible for skipping unreachable servers (an
/// environmental MCP failure is not a merge failure, PE-6); this function
/// registers exactly what it is handed.
Future<void> mergeMcpTools(
  ToolRegistry registry,
  McpToolSource source, {
  required bool enabled,
}) async {
  if (!enabled) return;
  for (final definition in await source.listTools()) {
    registry.register(McpBrainTool(definition));
  }
}
