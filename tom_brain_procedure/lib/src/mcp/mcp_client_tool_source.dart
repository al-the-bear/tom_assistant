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
import '../tools/tool_failures.dart';
import 'mcp_client.dart';

/// Decides whether a configured server's tools are offered to procedures / LLMs
/// at this moment: `offered(serverId) = exposeToLlms(serverId) &&
/// monitor.isLive(serverId)` (`agent_sdk_provider_and_mcp_liveness.md` § 3.3).
typedef McpOfferedGate = bool Function(String serverId);

/// Composes a per-run MCP offered-server gate from a profile's resolved
/// allowlist and the process-wide dynamic liveness gate
/// (`session_configuration.md` § 3.6; plan step 8 (c); SCP-33).
///
/// [profileOffered] is the profile's already-composed offered-server set
/// (`(global-exposed ∩ allowlist) ∪ profile-defined-exposed`, computed at boot);
/// an **empty** list is the "all globally-exposed servers" sentinel. [globalGate]
/// is the engine's dynamic `exposeToLlms && isLive` gate (`null` ⇒ every
/// configured server is unconditionally offered).
///
/// The composition:
///   - empty allowlist ⇒ the global gate verbatim (the sentinel: every server
///     the global gate offers is offered — an `exposeToLlms:false` or dead
///     server still fails the global gate and is never offered);
///   - a non-empty allowlist ⇒ a server is offered only when it is **both** in
///     the allowlist **and** passing the global gate — so the dynamic liveness
///     gate still wins over a stale profile allowlist (a server that flips dead
///     drops out without a restart).
McpOfferedGate? composeMcpGate(
  List<String> profileOffered,
  McpOfferedGate? globalGate,
) {
  if (profileOffered.isEmpty) return globalGate;
  final allow = profileOffered.toSet();
  return (String serverId) =>
      allow.contains(serverId) && (globalGate?.call(serverId) ?? true);
}

/// Adapts an [McpClient] to the tools layer's [McpToolSource] port.
///
/// Constructed by the engine wiring over the process-spanning client; handed to
/// `mergeMcpTools` (to register the merged tools at boot) and carried on each
/// run's `ToolContext.mcp` (to forward a merged tool's call).
final class McpClientToolSource implements McpToolSource {
  /// The process-spanning MCP client this projects onto the port.
  final McpClient client;

  /// The live availability gate (request (c) § 3.3). When `null`, every
  /// configured server is offered (the pre-gate behaviour); otherwise a server
  /// is offered only when `offered(serverId)` is `true`. The gate is consulted
  /// both when enumerating tools for the merge ([listTools]) and on every call
  /// ([invokeTool]) — so a server that flips dead / unexposed after boot stops
  /// serving without a restart.
  final McpOfferedGate? offered;

  /// Wraps [client], optionally gating server availability through [offered].
  const McpClientToolSource(this.client, {this.offered});

  /// Whether [serverId] is offered right now: `true` when no gate is set, else
  /// the gate's verdict.
  bool _isOffered(String serverId) => offered?.call(serverId) ?? true;

  @override
  Future<List<McpToolDefinition>> listTools() async {
    final defs = <McpToolDefinition>[];
    for (final advert in client.servers()) {
      final serverId = advert['id'];
      if (serverId is! String) continue;
      if (!_isOffered(serverId)) continue;
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
  ) async {
    if (!_isOffered(server)) {
      // A server that is unexposed or has flipped dead since boot is denied
      // loudly per call (PE-1 style) rather than silently returning a wrong
      // answer — request (c) § 3.3. `async` makes this a rejected Future,
      // uniform with the client's own async call path.
      throw ToolSurfaceUnavailable(
        surface: 'mcp',
        tool: 'mcp__${server}__$tool',
      );
    }
    return client.callTool(server, tool, arguments);
  }

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
