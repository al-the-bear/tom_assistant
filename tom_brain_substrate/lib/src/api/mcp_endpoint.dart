// B.9 — `McpEndpoint`.
//
// substrate_specification.md § 3.1: `mcpClient(McpEndpoint endpoint)`
// is the substrate-side method that produces an outbound MCP client
// bound to a configured endpoint. The configuration shape lives in
// `SubstrateConfig.mcpClient.endpoints` (spec § 9):
//
// ```yaml
// mcpClient:
//   endpoints:
//     memory:
//       transport: stdio
//       command: 'tom_brain_memory_mcp'
//     memory_remote:
//       transport: http
//       url: 'https://brain.example/mcp'
//       auth: { mode: bearer, secretRef: '_ai/secrets/mcp.bearer' }
// ```
//
// `McpEndpoint` is the api/-surface key into that table. It carries
// only the endpoint id (which is the YAML key under `endpoints:`);
// the transport choice, command line, URL, and auth profile all
// live in the config and are resolved internally by the substrate.
//
// Why a typed wrapper rather than `String`:
//
//   - Consumers (the dispatcher's MCP-tool adapter, tests) name
//     endpoints from procedure headers; a typed wrapper catches
//     accidental cross-arg swaps with role ids or provider ids at
//     compile time.
//   - Spec § 3.2 talks about "one persistent MCP session per
//     `McpEndpoint`"; the typed key gives the session cache an
//     unambiguous map key.

/// Reference to an MCP endpoint configured under
/// `SubstrateConfig.mcpClient.endpoints`.
final class McpEndpoint {
  /// The YAML key under `mcpClient.endpoints`. Substrate resolves
  /// the transport / URL / auth from the config; consumers never
  /// see those fields.
  ///
  /// `McpEndpoint('memory')` and `McpEndpoint('memory')` compare
  /// equal; the substrate uses the id as the session-cache key.
  final String id;

  const McpEndpoint(this.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is McpEndpoint && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'McpEndpoint($id)';
}
