// todo #5 — the single point of contact with the underlying MCP wire
// library on the **client** side.
//
// `mcp_client.dart` is the only consumer of MCP protocol types, and it
// reaches them through this adapter (imported `as mcp`) rather than
// `package:dart_mcp/...` directly. That confines the dependency on the
// concrete wire library to one file, so swapping `dart_mcp` for a
// different MCP implementation later is a localized change: re-point
// the `export` lines below and the rest of the package is unaffected
// (provided the new library exposes the same named surface, which the
// enforcement test in `test/mcp_library_isolation_test.dart` and the
// dependency-surface test together pin down).
//
// The surface is split across the upstream `client.dart` /
// `server.dart` sub-libraries, but consumers do not care: collapsing
// both behind one adapter prefix means `mcp_client.dart` uses a single
// `mcp.` qualifier instead of the old `mcp.` + `mcp_proto.` pair.
//
// The `show` lists are deliberately explicit rather than a blanket
// re-export: they name the exact surface the client leans on, and they
// partition the names across the two sub-libraries so there is no
// ambiguous-export collision for the protocol types (e.g.
// `Implementation`) that both sub-libraries re-export.
//
//   - `MCPClient` / `ServerConnection` are the client-driver surface
//     (`client.dart`).
//   - The protocol value types come from `server.dart`, the canonical
//     home of the wire-protocol declarations.

export 'package:dart_mcp/client.dart' show MCPClient, ServerConnection;
export 'package:dart_mcp/server.dart'
    show
        CallToolRequest,
        ClientCapabilities,
        Implementation,
        InitializeRequest,
        InitializeResult,
        ProtocolVersion;
