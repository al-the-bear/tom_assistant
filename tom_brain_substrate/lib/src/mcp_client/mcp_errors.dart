// B.8 — Typed errors raised by the outbound MCP client.
//
// `substrate_specification.md` § 12 names two error surfaces the
// outbound MCP client must own:
//
//   - `McpToolUnreachable` — endpoint cannot be reached after the
//     configured backoff window. The plan attributes this to general
//     transport failure.
//   - "auth failure surfaces as typed error" (plan step B.35) —
//     materialised here as [McpAuthFailed], reserved for the HTTP
//     transport (policy override 2 from 2026-05-31:
//     `prototype_implementation_plan.md` preamble §2 — "Auth is
//     transport-scoped (HTTP only — stdio is never authenticated)").
//
// Why a closed taxonomy:
//
//   - Substrate Spec § 12 enumerates substrate's error closed-set;
//     adding a new failure mode is a version bump, not a silent
//     extension (mirrors memory spec § 1.7).
//   - Procedure-author roles and dispatcher critique paths pattern-
//     match on these classes — leaking a raw `Exception` from
//     `dart_mcp` or a transport library would punch through the
//     contract.
//
// What this file deliberately is NOT:
//
//   - Not a translation layer for every `dart_mcp` internal error
//     (e.g. JSON-RPC schema mismatches). Those continue to surface
//     as the dart_mcp / json_rpc_2 exceptions they already are; the
//     contract here covers transport-level concerns that the
//     substrate caller actually needs to branch on (auth, reach,
//     handshake refusal).

/// Base class for every typed error the outbound MCP client raises.
///
/// Pattern-matching on subtypes is the recommended branch surface;
/// the base type carries an [endpointId] tag so observability and
/// trail entries can attribute the failure to a specific
/// `McpEndpoint`.
sealed class McpClientException implements Exception {
  /// The configured `McpEndpoint.id` the failing call was bound to.
  final String endpointId;

  /// Human-readable diagnostic. Intended for `TomLogger` /
  /// `SubstrateEvent` payloads, not for end-user surfaces.
  final String message;

  const McpClientException(this.endpointId, this.message);

  @override
  String toString() => '$runtimeType($endpointId): $message';
}

/// The endpoint refused the client's credentials.
///
/// Surfaces from the HTTP transport when the server returns 401 / 403
/// on the handshake POST (or any subsequent POST). Stdio / channel
/// transports do not produce this error — they have no authentication
/// surface (policy override 2 on `prototype_implementation_plan.md`).
///
/// [statusCode] is the HTTP status that triggered the rejection; 401
/// and 403 are the only values the prototype maps to this class.
final class McpAuthFailed extends McpClientException {
  /// The HTTP status code (401 or 403) that triggered the rejection.
  final int statusCode;

  const McpAuthFailed(super.endpointId, super.message, this.statusCode);
}

/// The endpoint is not reachable.
///
/// Covers network-level failures (DNS, connection-refused, TLS error,
/// HTTP 5xx after the configured retry budget, stdio child-process
/// exit before handshake). The caller should not retry tighter than
/// the configured backoff window.
///
/// Mirrors `substrate_specification.md` § 12's `McpToolUnreachable`
/// label; the name was tightened to match the broader role of this
/// class (it also covers handshake-time unreachability, not only
/// per-tool calls).
final class McpTransportUnreachable extends McpClientException {
  /// HTTP status code that triggered the failure, when applicable;
  /// `null` for stdio / channel transports and for pre-response
  /// network errors (DNS, connection-refused).
  final int? statusCode;

  const McpTransportUnreachable(
    super.endpointId,
    super.message, {
    this.statusCode,
  });
}

/// The transport connected but the MCP handshake itself failed.
///
/// Covers protocol-version mismatches, malformed `initialize`
/// responses, and any other JSON-RPC-level failure that surfaces
/// during [McpClient.connect]. Auth rejections are reported as
/// [McpAuthFailed] instead, since the caller branch on those is
/// different (rotate credential vs. surface to user).
final class McpHandshakeFailed extends McpClientException {
  const McpHandshakeFailed(super.endpointId, super.message);
}
