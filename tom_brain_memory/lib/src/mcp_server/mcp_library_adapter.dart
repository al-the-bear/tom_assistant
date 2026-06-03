// todo #5 — the single point of contact with the underlying MCP wire
// library on the **server** side.
//
// Every other server-side file (`tom_brain_memory_mcp_server.dart`,
// `mcp_tools.dart`, `mcp_transports.dart`) imports the MCP protocol
// types it needs through this adapter, never `package:dart_mcp/...`
// (or `package:json_rpc_2/...`) directly. That confines the dependency
// on the concrete wire library to one file, so swapping `dart_mcp` for
// a different MCP implementation later is a localized change: re-point
// the `export` lines below at the new library and the rest of the
// package is unaffected (provided the new library exposes the same
// named surface, which the enforcement test in
// `test/mcp_library_isolation_test.dart` and the dependency-surface
// test together pin down).
//
// The `show` lists are deliberately explicit rather than a blanket
// re-export: they name the exact surface the server leans on, so the
// adapter doubles as the authoritative inventory of "what we actually
// use from the MCP library". A symbol that needs adding here is a
// signal that the package's coupling to the library is growing — the
// review happens in one place.
//
// `RpcException` is included because the MCP `initialize`-time bearer
// refusal surfaces on the wire as a JSON-RPC error; `json_rpc_2` is the
// error model `dart_mcp` builds on, so it belongs to the same swap
// boundary.

export 'package:dart_mcp/server.dart'
    show
        CallToolRequest,
        CallToolResult,
        Implementation,
        InitializeRequest,
        InitializeResult,
        MCPServer,
        ObjectSchema,
        Schema,
        TextContent,
        Tool,
        ToolAnnotations,
        ToolsSupport;
export 'package:dart_mcp/stdio.dart' show stdioChannel;
export 'package:json_rpc_2/json_rpc_2.dart' show RpcException;
