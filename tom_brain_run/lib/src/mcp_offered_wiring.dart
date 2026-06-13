// The run-layer composition glue for request (c)'s MCP availability gate
// (`agent_sdk_provider_and_mcp_liveness.md` § 3.2 / § 3.3).
//
// `offered(serverId) = exposeToLlms(serverId) && monitor.isLive(serverId)`.
// The static half (`exposeToLlms`) lives on the parsed `McpServerConfig`; the
// dynamic half (`isLive`) is held by the `McpLivenessMonitor` heartbeat. These
// two pure helpers are the only place the run layer joins the procedure
// package's `McpServersConfig` / `McpClient` to the run package's monitor:
//
//   * [mcpOfferedGate] folds the two halves into the single `McpOfferedGate`
//     the procedure engine's `McpClientToolSource` consumes.
//   * [mcpLivenessMonitorOverClient] builds the monitor, binding its probe seam
//     to `McpClient.listTools` (a cheap, already-pooled reachability check) and
//     its evict seam to `McpClient.evict` (drop a dead server's pooled
//     connection so the next probe reconnects).
//
// Keeping the join as functions rather than inline in the provisioner lets it
// be unit-tested without standing a whole brain up (r40), exactly as the dream
// cadence wiring separates its composable pieces from the boot path.

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpClient, McpOfferedGate, McpServersConfig;

import 'mcp_liveness_monitor.dart';

/// Folds the static `exposeToLlms` flag on [config] and the dynamic live set
/// held by [monitor] into the `offered = exposeToLlms && isLive` gate.
///
/// An unconfigured id is never offered (`byId` is null → not exposed); a
/// configured-but-unexposed server is never offered regardless of liveness; an
/// exposed server is offered only while the monitor holds it live.
McpOfferedGate mcpOfferedGate(
  McpServersConfig config,
  McpLivenessMonitor monitor,
) =>
    (String serverId) =>
        (config.byId(serverId)?.exposeToLlms ?? false) &&
        monitor.isLive(serverId);

/// Builds the liveness [McpLivenessMonitor] over the servers in [config],
/// binding its probe to `client.listTools` and its evict to `client.evict`.
///
/// [interval] overrides the 30-second heartbeat (tests inject a small value).
/// Each configured id starts optimistically live so the boot-time tool merge
/// offers it before the first tick.
McpLivenessMonitor mcpLivenessMonitorOverClient(
  McpClient client,
  McpServersConfig config, {
  Duration interval = const Duration(seconds: 30),
}) =>
    McpLivenessMonitor(
      serverIds: config.servers.map((server) => server.id),
      probe: (id) async {
        await client.listTools(id);
      },
      evict: client.evict,
      interval: interval,
    );
