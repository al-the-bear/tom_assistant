// Barrel for the `mcp_server/` module (Plan step A.23).
//
// Owns the MCP server described in `memory_specification.md` § 3.2 —
// the read-only network surface other Tom Brain components and
// well-known external consumers use when they cannot share an isolate
// with memory.
//
// Scope:
//
//   - Built on `dart_mcp` (pub.dev) — the workspace MCP library.
//   - Read-only seven-tool surface (no writes; writes happen through
//     the in-process API or the procedure-engine bridge):
//       `recall`, `get_node`, `edges_of`, `list_node_types`,
//       `stack_peek`, `centroid_lookup`, `health`.
//   - Bearer-token authentication via `TomBearerAuthentication`
//     (re-exported from `tom_core_kernel`; see Q-A.22.2).
//   - No HTTP transport in scope for the v1 server. Stdio + UNIX socket
//     are the supported transports.
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
//   - A.77 – A.79 — the seven tools, one per step.
//
// At A.23 this folder was intentionally empty. A.75 lands the server
// skeleton + the supported transports; later steps add bearer-auth
// (A.76) and the seven tools (A.77 – A.79) without changing this
// barrel's export list (subsequent files are wired into the same two
// modules listed below).

export 'mcp_transports.dart';
export 'tom_brain_memory_mcp_server.dart';
