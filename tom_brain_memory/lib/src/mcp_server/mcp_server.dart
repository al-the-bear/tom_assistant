// Barrel for the `mcp_server/` module (Plan step A.23).
//
// Owns the MCP server described in `memory_specification.md` § 3.2 —
// the network surface other Tom Brain components and well-known
// external consumers use when they cannot share an isolate with
// memory.
//
// Scope:
//
//   - Built on `dart_mcp` (pub.dev) — the workspace MCP library.
//   - Seven-tool surface. Six are pure reads; `memory.persistNote` is
//     the single, closed-set write (gated by `McpWriteForbidden` to
//     the `allowedPersistNoteTypeNames` types and by bearer auth):
//       `memory.recall`, `memory.get`, `memory.edgesOf`,
//       `memory.stack.list`, `memory.stack.peek`, `memory.classify`,
//       `memory.persistNote`.
//   - Bearer-token authentication via `TomBearerAuthentication`
//     (re-exported from `tom_core_kernel`; see Q-A.22.2).
//   - Three supported transports (`mcp_transports.dart`): stdio, UNIX
//     socket, and — added at todo #3 — Streamable HTTP / HTTPS
//     (`McpHttpServer`). The HTTP transport is the network surface the
//     cross-machine Big-Beast/bomber topology (memory_specification.md
//     § 10) needs, since neither stdio nor a UNIX socket crosses a host
//     boundary. It implements the POST + single JSON-RPC response
//     subset (no SSE), mirroring the outbound client subset in
//     `tom_brain_substrate`. HTTP-header bearer auth (todo #4) is
//     optional and off by default: when `McpHttpServer` is bound with a
//     `BearerTokenAuthenticator`, every POST / DELETE must carry a valid
//     `Authorization: Bearer <token>` (refused `401` otherwise) — the
//     same header the substrate client sends. With no authenticator the
//     endpoint admits anonymous callers (trust-the-VPN default).
//
// Hard invariants honoured here:
//
//   - § 1.2 — "memory does not call LLMs on the hot path". Tool calls
//     are pure retrieval; classification with batched LLM input is a
//     separate procedure path, not exposed via MCP.
//   - § 1.7 — "no backwards compatibility". The tool list is the
//     contract; new tools are added by version bump, never by silent
//     extension.
//
// Wiring across later Phase A steps:
//
//   - A.75 — server skeleton extending `dart_mcp`'s `MCPServer`.
//   - A.76 — bearer-token check using `TomBearerAuthentication`.
//   - A.77 — seven v1 tools (memory_specification.md § 3.2) registered
//     when the server is constructed with the optional `memory`
//     parameter; the closed-set rejection `McpWriteForbidden` and the
//     `allowedPersistNoteTypeNames` constant ship in
//     `mcp_write_forbidden.dart`. See Q-A.77.1 for why the seven tools
//     land in one step rather than three.
//
// At A.23 this folder was intentionally empty. A.75 lands the server
// skeleton + the supported transports; A.76 lands the bearer-token
// authentication surface (`bearer_auth.dart`) and folds the
// `initialize`-time check into the server class. A.77 lands the
// seven-tool registration helper (`mcp_tools.dart`) and the
// closed-set rejection exception (`mcp_write_forbidden.dart`).

export 'bearer_auth.dart';
export 'mcp_tools.dart' show registerMemoryTools;
export 'mcp_transports.dart';
export 'mcp_write_forbidden.dart';
export 'tom_brain_memory_mcp_server.dart';
