// McpToolSource — the host-side seam onto the configured external MCP servers'
// tools (`tom_brain_procedure_specification.md` § 21.3, § 21.8;
// `prototype_tools_mcp_extension_plan.md` step 8).
//
// When the brain is configured with one or more external MCP servers, each
// server's advertised tools are merged into the `ToolRegistry` as additional
// `BrainTool`s (`mergeMcpTools`), so a remote MCP tool and a built-in
// `BrainTool` are indistinguishable to `tool.list` / `tool.invoke` — the model
// is offered them in the same flat tool list and calls them through the same
// tool-calling loop. The merge reaches the servers only through this narrow
// port: the tools layer never holds an `McpClient` (no `mcp/` import), so there
// is no file-level cycle (`mcp_bridge.dart` already imports the tools layer).
// The concrete adapter that maps an [McpClient] onto this port lives in `mcp/`
// (`McpClientToolSource`), exactly as `ToolEngineSurface` fronts the engine
// without the tools knowing the engine's internals (PE-10).
//
// The port is method-only and exchanges plain values (PE-1): a merged tool
// reaches the server through the run's [McpToolSource] (carried on the
// `ToolContext`), never a raw socket or `dart:io` handle.

/// One external MCP server tool's descriptor, as the merge sees it.
///
/// Carries the [server] id and remote [tool] name the call routes back to,
/// plus the `{description, input_schema}` the registry advertises. The flat,
/// namespaced [qualifiedName] (`mcp__<server>__<tool>`) is the registry key and
/// `tool.invoke` selector — a namespace keeps a remote tool from clashing with
/// a built-in or another server's same-named tool. Immutable; built by the
/// adapter from the server's `mcp.list` reply (§ 21.3).
final class McpToolDefinition {
  /// The configured MCP server id the call routes to.
  final String server;

  /// The remote tool name on [server].
  final String tool;

  /// The one-line description surfaced through `tool.list`.
  final String description;

  /// The JSON-Schema fragment `tool.invoke` validates `args` against before the
  /// call is forwarded. Defaults to the empty object (an open schema).
  final Map<String, Object?> inputSchema;

  /// Builds a descriptor for [tool] on [server] with its [description] and
  /// optional [inputSchema] (defaulting to an open object schema).
  const McpToolDefinition({
    required this.server,
    required this.tool,
    this.description = '',
    this.inputSchema = const <String, Object?>{},
  });

  /// The flat, namespaced registry name and `tool.invoke` selector for this
  /// remote tool: `mcp__<server>__<tool>`. The double-underscore separators
  /// keep the server id and tool name recoverable and avoid colliding with the
  /// dotted built-in tool names (`memory.read`, `web.search`, …).
  String get qualifiedName => 'mcp__${server}__$tool';
}

/// The narrow external-MCP capability the merged `mcp__*` tools route through
/// (PE-1, PE-10).
///
/// Method-only and result-as-data: [listTools] enumerates every configured
/// server's advertised tools (so the merge can register one `BrainTool` per
/// remote tool), and [invokeTool] forwards a validated call to a named server +
/// tool. The `McpClient` adapter implements this in `mcp/`; tests substitute an
/// in-process stub.
abstract interface class McpToolSource {
  /// Every configured server's advertised tools, each as a plain
  /// [McpToolDefinition]. Read once at boot to register the merged tools; an
  /// unreachable server is skipped (its tools are simply absent), never thrown.
  Future<List<McpToolDefinition>> listTools();

  /// Forwards a call to [tool] on the MCP server [server] with [arguments] (the
  /// args already validated against the tool's `inputSchema`), returning the
  /// server's raw result payload.
  Future<Object?> invokeTool(
    String server,
    String tool,
    Map<String, Object?> arguments,
  );
}
