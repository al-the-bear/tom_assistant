// `McpEvent` sealed sum — the MCP client's typed observability stream
// (Extension F step 16; `tom_brain_procedure_specification.md`
// § 13, § 21.10).
//
// Three variants, one per outcome the `McpClient` (`mcp_client.dart`) can
// reach when a procedure calls *out* to an MCP server via the
// `mcp.servers` / `mcp.list` / `mcp.call` primitives:
//
//   - `McpConnected`  — a per-id connection was opened (the lazy first use).
//   - `McpToolCalled` — a `mcp.call` ran a tool on a server to a result.
//   - `McpFailed`     — a connect failed (`mcp.unreachable`) or a call
//                       failed (`mcp.call.failed`) — the [McpFailure] carrier.
//
// Same shape as the engine (`EngineEvent`, C.44), dispatcher
// (`DispatcherEvent`, D.49), and tool (`ToolEvent`, step 16) halves: a
// `sealed` `BrainEvent` subtree with a kebab-case `kind` and a null-omitting
// `payloadJson()`. The `McpEventBus` (`mcp_event_bus.dart`) is the broadcast
// fan-in.
//
// ── `runId` stays nullable ──────────────────────────────────────────
//
// The `McpClient` is built once per process over the configured servers, not
// per run; its connect/call effects are not intrinsically run-scoped (a
// pooled connection outlives the run that opened it). So `McpEvent` keeps
// `BrainEvent`'s nullable `runId`, like the access-scoped `DispatcherEvent`
// variants.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// Sink the [McpClient] calls with each [McpEvent] it emits (step 16).
///
/// Injected into the client; the composition root wires it to an
/// [McpEventBus] (`bus.emit`). `null` (the default) disables emission.
typedef McpEventSink = void Function(McpEvent event);

/// Marker / base for every typed MCP-client observability event.
///
/// A consumer subscribed to `McpEventBus.events()` sees only subtypes of
/// this class. Exhaustive `switch` over the closed three-variant taxonomy
/// (spec § 13) is the recommended branch surface.
sealed class McpEvent extends BrainEvent {
  /// The id of the configured server this event concerns.
  final String serverId;

  /// Builds the base of an MCP event over [serverId]. [runId] stays nullable
  /// — see the file header.
  McpEvent({
    required this.serverId,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });
}

/// A per-id connection was opened to a configured server (§ 21.3) — emitted
/// once per server the first time it is reached (the pool then reuses it).
final class McpConnected extends McpEvent {
  McpConnected({
    required super.serverId,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'mcp.connected';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'serverId': serverId,
      };
}

/// A `mcp.call` ran a tool on a server to a result (§ 21.3) — emitted after a
/// successful outbound call, within the per-call wall-clock cap.
final class McpToolCalled extends McpEvent {
  /// The name of the tool that was called on the server.
  final String tool;

  McpToolCalled({
    required super.serverId,
    required this.tool,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'mcp.tool-called';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'serverId': serverId,
        'tool': tool,
      };
}

/// An MCP-client failure surfaced (§ 21.10, PE-6) — a connect failure
/// (`mcp.unreachable`) or a call failure (`mcp.call.failed`). Carries the
/// same wire [code] the [McpFailure] exception does.
final class McpFailed extends McpEvent {
  /// The wire code — `mcp.unreachable` or `mcp.call.failed`.
  final String code;

  /// The human-readable failure message.
  final String message;

  McpFailed({
    required super.serverId,
    required this.code,
    required this.message,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'mcp.failed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'serverId': serverId,
        'code': code,
        'message': message,
      };
}
