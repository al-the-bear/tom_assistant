// A.75 — MCP server skeleton.
//
// Extends `dart_mcp`'s [MCPServer] (with the [ToolsSupport] mixin) and
// advertises the Tom Brain memory identity + the v1 read-only contract.
// This is the *skeleton* deliberately: no tools are registered at A.75.
// The seven spec § 3.2 tools (`memory.recall`, `memory.get`,
// `memory.edgesOf`, `memory.stack.list`, `memory.stack.peek`,
// `memory.classify`, `memory.persistNote`) are reserved by the
// instructions string but only land at A.77 – A.79. Bearer-token
// authentication lands at A.76.
//
// Why this split:
//
//   - The plan line for A.75 reads "Implement the MCP server on
//     `dart_mcp` with the seven tools in memory spec § 3.2". The
//     barrel-file design (`mcp_server.dart`) decomposes that single
//     plan line into four step-sized landings — A.75 (skeleton),
//     A.76 (bearer auth), A.77 – A.79 (tool implementations). The
//     barrel is the authoritative breakdown; see Q-A.75.1 for the
//     rationale.
//   - Landing the skeleton first lets the rest of Phase A wire the
//     server into deployment topologies (stdio for CLI, UNIX socket
//     for in-host inter-process; see `mcp_transports.dart`) before
//     committing to a specific tool shape. The bearer-auth check
//     (A.76) and per-tool argument schemas (A.77 – A.79) layer in
//     without changing the constructor surface.
//
// Hard-invariant alignment (memory spec):
//
//   - § 1.2 — "memory does not call LLMs on the hot path". The
//     instructions explicitly carry this guarantee so well-behaved
//     clients can advertise it onward to their users / LLM
//     orchestrators.
//   - § 1.7 — "no backwards compatibility". The instructions
//     advertise the seven-tool v1 surface as a *closed* set; future
//     tool additions are a version bump, never a silent extension.
//   - § 3.2 — read-only by default, with `memory.persistNote` as the
//     one constrained write (NodeType ∈ {Claim, Question,
//     AutomationIdea, InterestItem}). The skeleton advertises this
//     contract; the actual enforcement lives in the tool
//     implementations at A.77 – A.79.

import 'package:dart_mcp/server.dart';

/// The Tom Brain memory MCP server skeleton.
///
/// At A.75 this server constructs over a `StreamChannel<String>` (from
/// either [stdioChannel] or `socketChannel` — see
/// `mcp_transports.dart`), completes the `initialize` handshake, and
/// advertises an empty tool list. It does not authenticate the caller
/// (A.76) and does not implement any of the seven v1 tools yet
/// (A.77 – A.79).
///
/// Construct directly with a pre-built channel:
///
/// ```dart
/// final server = TomBrainMemoryMcpServer(channel);
/// await server.initialized;
/// ```
///
/// Or use the transport helpers in `mcp_transports.dart` to wire stdio
/// or a UNIX-domain socket connection.
///
/// `base` matches `dart_mcp`'s `MCPServer` modifier; subclasses extending
/// further (e.g. an A.77 variant that bolts on per-tool handlers) must
/// stay in the same `base` family.
base class TomBrainMemoryMcpServer extends MCPServer with ToolsSupport {
  /// Identity name returned in `serverInfo.name` during initialization.
  ///
  /// Matches the `name:` line in `pubspec.yaml`. The MCP spec recommends
  /// the package name as the implementation name; we follow that.
  static const serverName = 'tom_brain_memory';

  /// Identity version returned in `serverInfo.version` during
  /// initialization.
  ///
  /// Hand-mirrored from the `version:` line in `pubspec.yaml` (currently
  /// `0.0.1`). A future helper may parse the pubspec at build time; until
  /// then, bumping the package version requires bumping this constant in
  /// the same change.
  static const serverVersion = '0.0.1';

  /// The instructions string returned to clients during the `initialize`
  /// handshake. Documents the v1 contract — read-only by default with
  /// one constrained write, no LLM calls on the hot path, no silent
  /// tool-surface extension.
  ///
  /// Kept inline (not loaded from disk) so the contract is locked in the
  /// same source file as the server skeleton. A divergence between the
  /// docs and the advertised string would surface in code review of this
  /// file alone.
  static const readOnlyInstructions = '''
Tom Brain memory MCP server (v1).

This server exposes a read-only retrieval surface plus exactly one
constrained write (memory.persistNote, restricted to NodeType in
{Claim, Question, AutomationIdea, InterestItem}). All other writes
flow through the in-process Dart API or the procedure-engine bridge,
never through this MCP surface.

Memory-spec invariants honoured at the protocol boundary:
- Section 1.2: memory does not call LLMs on the hot path. Tool calls
  are pure retrieval; classification uses pre-computed centroids.
- Section 1.7: no backwards compatibility. The tool list is the
  contract; tool-surface changes are version-bumped, never silently
  extended.
- Section 3.2: the v1 surface is a closed set of seven tools:
  memory.recall, memory.get, memory.edgesOf, memory.stack.list,
  memory.stack.peek, memory.classify, memory.persistNote.

At A.75 the seven tools are reserved by this contract but not yet
registered. listTools returns an empty list until A.77 - A.79 land
the implementations.
''';

  /// Constructs a server bound to [channel].
  ///
  /// [channel] is the line-delimited UTF-8 transport — typically produced
  /// by `stdioChannel(input: stdin, output: stdout)` for command-line
  /// hosting, or by `socketChannel(socket)` for a UNIX-domain socket
  /// connection. The constructor does not start the I/O loop directly;
  /// `dart_mcp`'s [MCPBase] does that internally on construction.
  ///
  /// [protocolLogSink], if provided, receives every incoming and outgoing
  /// JSON-RPC frame for debugging. The caller owns the sink's lifecycle.
  TomBrainMemoryMcpServer(super.channel, {super.protocolLogSink})
    : super.fromStreamChannel(
        implementation: Implementation(
          name: serverName,
          version: serverVersion,
        ),
        instructions: readOnlyInstructions,
      );
}
