// McpClientToolSource — the concrete adapter that maps an [McpClient] onto the
// tools layer's [McpToolSource] port (`tom_brain_procedure_specification.md`
// § 21.3, § 21.8; `prototype_tools_mcp_extension_plan.md` step 8).
//
// The tools layer declares the narrow [McpToolSource] port (method-only, plain
// values) so it never imports `mcp/` (no file-level cycle: `mcp_bridge.dart`
// already imports the tools layer). This adapter is the one place the two meet:
// it holds the run-spanning [McpClient] and projects its `servers()` /
// `listTools(id)` / `callTool(id, …)` onto the port the merge and the merged
// `mcp__*` tools consume.
//
// ── Resilience at the list seam (PE-6) ──────────────────────────────
//
// [listTools] enumerates every configured server's advertised tools for the
// boot-time merge. A configured-but-unreachable server is an *environmental*
// failure, not a configuration error — so the adapter swallows the per-server
// [McpFailure] and simply omits that server's tools. One dead server therefore
// never aborts the merge (and so never breaks process boot); its tools are
// absent until it comes back and the process is restarted. The `invoke` path
// has no such swallow: a failed call propagates as the client's `McpFailure`,
// which `tool.invoke` turns into the standard `{ok: false, error}` envelope.

import '../tools/mcp_tool_source.dart';
import 'mcp_client.dart';

/// Adapts an [McpClient] to the tools layer's [McpToolSource] port.
///
/// Constructed by the engine wiring over the process-spanning client; handed to
/// `mergeMcpTools` (to register the merged tools at boot) and carried on each
/// run's `ToolContext.mcp` (to forward a merged tool's call).
final class McpClientToolSource implements McpToolSource {
  /// The process-spanning MCP client this projects onto the port.
  final McpClient client;

  /// Wraps [client].
  const McpClientToolSource(this.client);

  @override
  Future<List<McpToolDefinition>> listTools() async {
    final defs = <McpToolDefinition>[];
    for (final advert in client.servers()) {
      final serverId = advert['id'];
      if (serverId is! String) continue;
      final List<Map<String, Object?>> tools;
      try {
        tools = await client.listTools(serverId);
      } on McpFailure {
        // An unreachable server is environmental (PE-6): omit its tools rather
        // than fail the whole merge (and so the whole boot).
        continue;
      }
      for (final tool in tools) {
        final toolName = tool['name'];
        if (toolName is! String) continue;
        defs.add(McpToolDefinition(
          server: serverId,
          tool: toolName,
          description: _stringOr(tool['description'], ''),
          inputSchema: _schemaOf(tool['input_schema']),
        ));
      }
    }
    return defs;
  }

  @override
  Future<Object?> invokeTool(
    String server,
    String tool,
    Map<String, Object?> arguments,
  ) =>
      client.callTool(server, tool, arguments);

  /// Narrows [value] to a `String`, falling back to [fallback] otherwise.
  static String _stringOr(Object? value, String fallback) =>
      value is String ? value : fallback;

  /// Narrows [value] to a `Map<String, Object?>` schema, defaulting to the open
  /// object schema when it is absent or wrong-typed.
  static Map<String, Object?> _schemaOf(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return value.map((key, v) => MapEntry('$key', v));
    }
    return const <String, Object?>{};
  }
}
