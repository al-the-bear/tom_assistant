// B.8 — `McpTransport` abstraction.
//
// Substrate Spec § 3.2 defines two transports for the outbound MCP
// client: stdio and Streamable HTTP. Plan policy override 2 of
// `prototype_implementation_plan.md` makes both mandatory in this
// phase and pins auth as HTTP-only.
//
// `dart_mcp` 0.5.1's client surface (`MCPClient.connectServer`) is
// transport-agnostic — it consumes any `StreamChannel<String>` of
// newline-framed JSON-RPC messages. That makes the transport
// abstraction a thin "factory of `StreamChannel<String>`" plus a
// disposal hook, which is exactly what this file expresses.
//
// Three implementations land in companion files at B.8:
//
//   - `StdioMcpTransport`  (`stdio_transport.dart`) — spawns a child
//     process or wraps a pre-supplied `Stdio`-style pair. Default for
//     the prototype's colocated memory deployment shape.
//   - `HttpMcpTransport`   (`http_transport.dart`) — POST-based
//     Streamable HTTP, JSON response subset. Optional bearer auth.
//   - `ChannelMcpTransport`(`channel_transport.dart`) — wraps a
//     pre-built `StreamChannel<String>`. Used by tests and by future
//     in-isolate / in-process colocation shapes.
//
// What this file deliberately does NOT do:
//
//   - It does not implement the full Streamable HTTP spec
//     (server-initiated messages over GET-based SSE). The
//     POST-with-JSON-response subset is enough for the v1 tools list
//     and call surface; richer behaviour is documented in
//     `completion_steps.tom_brain.md` as future work.
//   - It does not bake retry / cooldown policy in — that lives one
//     layer up in `McpClient`. The transport surfaces failures as
//     typed errors and lets the client decide.

import 'package:stream_channel/stream_channel.dart';

/// Optional bearer-token credential applied by HTTP transports.
///
/// Stdio / channel transports ignore this field (policy override 2 on
/// `prototype_implementation_plan.md`: auth is HTTP-only). Token
/// material is held by value; the surrounding `SubstrateConfig`
/// loader resolves `_ai/secrets/*.bearer` paths into the concrete
/// string before constructing this object.
final class McpBearerCredential {
  /// The raw bearer token. Substrate logs **never** include this
  /// field; observability emits a token-fingerprint instead
  /// (Substrate Spec § 10.2).
  final String token;

  const McpBearerCredential(this.token);
}

/// A transport that yields a `StreamChannel<String>` of newline-framed
/// JSON-RPC messages suitable for `dart_mcp`'s `MCPClient`.
///
/// Implementations own the underlying connection's lifecycle. Callers
/// must invoke [close] (typically via `McpClient.close` /
/// `McpSession.close`) when they are done — the transport is
/// responsible for tearing down any spawned process, open socket, or
/// in-flight HTTP requests.
abstract interface class McpTransport {
  /// Stable identifier used in telemetry and typed-error messages.
  /// Matches the `McpEndpoint.id` from `SubstrateConfig.mcpClient`.
  String get id;

  /// Establishes the transport and returns the duplex channel
  /// `dart_mcp` will speak through.
  ///
  /// Implementations MUST throw an [McpClientException] subtype on
  /// failure. Specifically:
  ///   - HTTP transports throw [McpAuthFailed] on 401/403, and
  ///     [McpTransportUnreachable] on network errors or non-2xx
  ///     statuses outside the auth range.
  ///   - Stdio transports throw [McpTransportUnreachable] if the
  ///     child process cannot be spawned.
  ///
  /// May be called only once per instance. Re-connect requires
  /// constructing a new transport.
  Future<StreamChannel<String>> connect();

  /// A future that completes (with error) the first time the
  /// transport observes a fatal post-connect failure — e.g. the HTTP
  /// server starts returning 401 on the second POST, or the stdio
  /// child process exits unexpectedly.
  ///
  /// `McpClient` races handshake completion against this future so
  /// transport failures that happen mid-handshake surface as the
  /// correct typed error rather than as a generic dart_mcp
  /// `StateError`.
  ///
  /// Completes normally (no error) once [close] is called by the
  /// owner.
  Future<void> get done;

  /// Releases all transport resources. Idempotent.
  Future<void> close();
}
