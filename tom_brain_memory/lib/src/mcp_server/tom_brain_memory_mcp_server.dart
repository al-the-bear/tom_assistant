// A.75 — MCP server skeleton.
// A.76 — Bearer-token authentication folded into `initialize`.
//
// Extends `dart_mcp`'s [MCPServer] (with the [ToolsSupport] mixin) and
// advertises the Tom Brain memory identity + the v1 read-only contract.
// This is still the *skeleton* with respect to tool surface: no tools
// are registered yet. The seven spec § 3.2 tools (`memory.recall`,
// `memory.get`, `memory.edgesOf`, `memory.stack.list`,
// `memory.stack.peek`, `memory.classify`, `memory.persistNote`) are
// reserved by the instructions string but only land at A.77 – A.79.
//
// What A.76 adds:
//
//   - An optional [BearerTokenAuthenticator] parameter. When non-null,
//     the server overrides `initialize` and rejects the handshake
//     unless the client supplied a valid bearer token via the
//     `_meta.tomBrainBearerToken` extensibility slot
//     ([bearerTokenMetaKey]).
//   - A [principal] accessor that exposes the authenticated
//     [TomPrincipal] to A.77 tool handlers. Stays `null` for the
//     no-auth deployment shape (anonymous in-process callers).
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
//     (A.76, here) and per-tool argument schemas (A.77 – A.79) layer
//     in without changing the constructor surface beyond the single
//     opt-in `authenticator` parameter.
//
// Hard-invariant alignment (memory spec):
//
//   - § 1.2 — "memory does not call LLMs on the hot path". The
//     instructions explicitly carry this guarantee so well-behaved
//     clients can advertise it onward to their users / LLM
//     orchestrators. The bearer-auth check is a pure synchronous
//     predicate; it never reaches out for token introspection.
//   - § 1.7 — "no backwards compatibility". The instructions
//     advertise the seven-tool v1 surface as a *closed* set; future
//     tool additions are a version bump, never a silent extension.
//     Likewise the `_meta.tomBrainBearerToken` key is part of the v1
//     contract and is version-bumped, never silently renamed.
//   - § 3.2 — read-only by default, with `memory.persistNote` as the
//     one constrained write (NodeType ∈ {Claim, Question,
//     AutomationIdea, InterestItem}). The skeleton advertises this
//     contract; the actual enforcement lives in the tool
//     implementations at A.77 – A.79.

import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:json_rpc_2/json_rpc_2.dart' show RpcException;
import 'package:tom_core_kernel/tom_core_kernel.dart' show TomPrincipal;

import 'bearer_auth.dart';

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

  /// The optional bearer-token authenticator.
  ///
  /// `null` means the server is in **anonymous mode** — every
  /// `initialize` call succeeds without a token check. This is the
  /// shape an in-process embedded caller uses (same isolate, no
  /// trust boundary to defend).
  ///
  /// When non-null, the `initialize` override consults this object
  /// against the value at `_meta.tomBrainBearerToken` on the request.
  /// Failure surfaces as a JSON-RPC error and the handshake is
  /// aborted; success caches the principal on [principal] for A.77
  /// tool handlers.
  final BearerTokenAuthenticator? authenticator;

  TomPrincipal? _principal;

  /// The authenticated principal for the current connection.
  ///
  /// `null` when [authenticator] is `null` (anonymous mode), or before
  /// `initialize` has completed. After a successful authenticated
  /// `initialize`, this returns the principal the authenticator
  /// produced; A.77 tool handlers will consult this value for
  /// per-tool authorisation decisions.
  TomPrincipal? get principal => _principal;

  /// Constructs a server bound to [channel].
  ///
  /// [channel] is the line-delimited UTF-8 transport — typically produced
  /// by `stdioChannel(input: stdin, output: stdout)` for command-line
  /// hosting, or by `socketChannel(socket)` for a UNIX-domain socket
  /// connection. The constructor does not start the I/O loop directly;
  /// `dart_mcp`'s [MCPBase] does that internally on construction.
  ///
  /// [authenticator] enables the bearer-token check at `initialize`.
  /// When omitted (or `null`), the server runs in anonymous mode —
  /// suitable for in-process embedded callers. See `bearer_auth.dart`
  /// for the two shipped implementations
  /// ([JwtBearerTokenAuthenticator] for JWT-backed deployments,
  /// [StaticBearerTokenAuthenticator] for shared-secret deployments
  /// and tests).
  ///
  /// [protocolLogSink], if provided, receives every incoming and outgoing
  /// JSON-RPC frame for debugging. The caller owns the sink's lifecycle.
  TomBrainMemoryMcpServer(
    super.channel, {
    this.authenticator,
    super.protocolLogSink,
  }) : super.fromStreamChannel(
         implementation: Implementation(
           name: serverName,
           version: serverVersion,
         ),
         instructions: readOnlyInstructions,
       );

  /// Overrides `MCPServer.initialize` to interpose the bearer-token
  /// check before delegating to the base behaviour.
  ///
  /// When [authenticator] is non-null:
  ///
  ///   - The request's `_meta.tomBrainBearerToken` field is read.
  ///     A missing value raises a JSON-RPC error tagged
  ///     [BearerAuthFailureReason.missing].
  ///   - The token is passed to [authenticator]. Any
  ///     [BearerAuthFailure] is converted into a JSON-RPC error;
  ///     internal exception text is mapped to a stable reason tag
  ///     so token-introspection details cannot leak to the client.
  ///   - On success the produced [TomPrincipal] is cached on
  ///     [principal] for A.77 tool handlers.
  ///
  /// When [authenticator] is `null` the override is a no-op and the
  /// base behaviour is invoked unchanged.
  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) {
    if (authenticator != null) {
      _principal = _checkBearerToken(request, authenticator!);
    }
    return super.initialize(request);
  }

  /// Pulls the bearer token off the `_meta` extensibility slot and
  /// runs it through [auth]. Translates [BearerAuthFailure] into the
  /// JSON-RPC error surface so the `initialize` handshake fails
  /// cleanly on the wire.
  ///
  /// Kept as a static-ish helper rather than baked into `initialize`
  /// so unit tests can exercise the failure paths independently.
  static TomPrincipal _checkBearerToken(
    InitializeRequest request,
    BearerTokenAuthenticator auth,
  ) {
    // `_meta` is an extension-type map; we treat it as a plain
    // `Map<String, Object?>` for the lookup. Both `request.meta` and
    // a missing meta map are handled.
    final meta = request.meta as Map<String, Object?>?;
    final token = meta?[bearerTokenMetaKey];

    if (token is! String || token.isEmpty) {
      throw _bearerRpcError(
        const BearerAuthFailure(
          BearerAuthFailureReason.missing,
          'Bearer token missing from initialize _meta.',
        ),
      );
    }

    try {
      return auth.authenticate(token);
    } on BearerAuthFailure catch (failure) {
      throw _bearerRpcError(failure);
    }
  }

  /// Maps a [BearerAuthFailure] to a JSON-RPC error.
  ///
  /// The error code (`-32001`) is in the JSON-RPC server-defined
  /// implementation range (-32099 … -32000). The error message is
  /// generic (`Bearer authentication failed: <reason>`) so the wire
  /// surface cannot be used to fingerprint individual tokens; the
  /// detailed [BearerAuthFailure.message] is left for server-side
  /// logs only.
  static RpcException _bearerRpcError(BearerAuthFailure failure) =>
      RpcException(
        -32001,
        'Bearer authentication failed: ${failure.reason.name}',
      );
}
