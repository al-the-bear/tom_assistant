// The Memory MCP read seam (`prompt_tracing.md` § 8.4) — the transport-neutral
// contract the [MemoryReadClient] (PT-5.1) talks to. It mirrors the brain's own
// `McpServerConnection` (`tom_brain_procedure/lib/src/mcp/`): a
// `listTools` / `callTool` / `close` surface stripped of every `dart_mcp` type,
// so the observatory's read client holds no wire library and no `dart:io` handle
// and a test can substitute a fake.
//
// `callTool` returns the tool's decoded payload map — the JSON object the brain
// tool produced (`{nodes: …, report: …}`, `{edges: …}`, the bare
// ClassificationResult, …; see `tom_brain_memory/lib/src/mcp_server/mcp_tools.dart`).
// Unwrapping the `dart_mcp` `CallToolResult` (structuredContent vs a single
// `TextContent` whose `text` is that JSON) is the concrete connector's job, not
// this seam's — keeping the read client a pure marshalling facade.
//
// Read-only is structural here (OBS-2 / OBS-3, § 6.2): the seam exposes no write
// path and no file/DB handle. The only memory door is `callTool`, and the client
// over it (PT-5.1) confines that door to the nine read tools.

/// A read-only connection to the brain's memory MCP server. Implemented by a
/// concrete `dart_mcp`-backed connector (wired at the run-assembly seam) and by
/// test fakes.
abstract interface class McpReadConnection {
  /// The server's advertised tools, each as `{name, description, inputSchema}`.
  /// Throws [McpReadException] on a wire error.
  Future<List<Map<String, Object?>>> listTools();

  /// Calls read tool [name] with [args], returning the tool's decoded payload
  /// map. Throws [McpReadException] when the server reports a tool error or the
  /// wire call fails.
  Future<Map<String, Object?>> callTool(String name, Map<String, Object?> args);

  /// Closes the connection. Idempotent.
  Future<void> close();
}

/// A failure reading the memory MCP surface — an unreachable server, a wire
/// error, or a tool-reported error. The observatory treats every memory-read
/// failure as environmental: a view shows "memory unavailable", never a crash.
final class McpReadException implements Exception {
  const McpReadException(this.message, {this.cause});

  /// Human-readable explanation.
  final String message;

  /// The underlying error, when this wraps one.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'McpReadException: $message'
      : 'McpReadException: $message ($cause)';
}
