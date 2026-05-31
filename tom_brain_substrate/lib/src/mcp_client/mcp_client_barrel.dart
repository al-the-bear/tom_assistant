// B.8 — Outbound MCP client barrel.
//
// Substrate Spec § 3.2: substrate owns the *client* side of the MCP
// protocol; memory owns the server side. The public surface here is
// the single entry point procedures will use to talk to memory's MCP
// server or to any external MCP server configured under
// `SubstrateConfig.mcpClient.endpoints`.

export 'channel_transport.dart' show ChannelMcpTransport;
export 'http_transport.dart' show HttpMcpTransport;
export 'mcp_client.dart'
    show McpClient, McpClientIdentity, McpSession, McpToolInfo, McpToolResult;
export 'mcp_errors.dart'
    show
        McpAuthFailed,
        McpClientException,
        McpHandshakeFailed,
        McpTransportUnreachable;
export 'mcp_transport.dart' show McpBearerCredential, McpTransport;
export 'stdio_transport.dart' show StdioMcpTransport;
