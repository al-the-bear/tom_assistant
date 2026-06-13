// Barrel for the `mcp/` module (Extension F step 8;
// `tom_brain_procedure_specification.md` § 21.3).
//
// The MCP **client** the `mcp.servers` / `mcp.list` / `mcp.call` bridged
// primitives run on — the consumer edge that lets a procedure call *out* to
// MCP servers (the memory one and any configured external one). The engine
// owns no MCP *server* (that stays memory's concern, A.75); this folder is the
// outbound counterpart.
//
//   - `McpServerConfig` / `McpServersConfig` / `McpTransport` — the parsed
//     `mcpServers:` config block (§ 21.6), loaded through the canonical
//     plain-map loader. `McpConfigInvalid` is its structural-shape failure.
//   - `McpClient` — the configured registry + per-server-id connection pool,
//     closed at shutdown, with a per-call wall-clock cap.
//   - `McpServerConnection` / `McpConnector` — the transport-neutral wire
//     contracts the client uses; `McpFailure` is the environmental failure
//     they raise (`mcp.unreachable` / `mcp.call.failed`, PE-6).
//   - `DartMcpConnection` / `DartMcpConnector` / `McpChannelFactory` — the
//     concrete `dart_mcp` adapter (the only place `dart_mcp` types live).
//
// The `McpBridge` that re-exposes these three primitives to d4rt scripts
// lives in `src/bridges/mcp_bridge.dart` (bridged exactly like `ToolBridge`).

export 'dart_mcp_connection.dart'
    show DartMcpConnection, DartMcpConnector, McpChannelFactory;
export 'mcp_client.dart'
    show
        McpClient,
        McpConnector,
        McpFailure,
        McpServerConnection,
        mcpCallFailedCode,
        mcpUnreachableCode;
// Step 8 — the adapter that merges configured servers' tools into the
// `tool.*` surface (§ 21.8); maps `McpClient` onto the tools layer's
// `McpToolSource` port.
export 'mcp_client_tool_source.dart' show McpClientToolSource, McpOfferedGate;
export 'mcp_config_errors.dart' show McpConfigInvalid, mcpConfigInvalidCode;
// Extension F step 16 — the MCP-client observability stream (§ 13).
export 'mcp_event.dart'
    show McpConnected, McpEvent, McpEventSink, McpFailed, McpToolCalled;
export 'mcp_event_bus.dart' show McpEventBus;
export 'mcp_server_config.dart'
    show McpServerConfig, McpServersConfig, McpTransport;
