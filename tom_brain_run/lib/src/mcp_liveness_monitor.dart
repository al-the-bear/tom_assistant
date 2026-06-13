// McpLivenessMonitor — the 30-second heartbeat that keeps the MCP live set
// (request (c) § 3.2; `agent_sdk_provider_and_mcp_liveness.md` § 3.2).
//
// `offered(serverId) = exposeToLlms(serverId) && monitor.isLive(serverId)`.
// `exposeToLlms` is static config; this monitor owns the dynamic half. Each
// tick it probes every configured server (in production via
// `McpClient.listTools(serverId)` — cheap, already pooled); a successful probe
// marks the server **live**, any failure marks it **dead** and **evicts** the
// pooled connection so the next tick reconnects rather than re-failing against
// a stale one. That is the "auto-enable/disable on live/dead" behaviour: a
// server flips into / out of `offered(...)` as its live bit flips, with no
// process restart.
//
// Why this lives in `tom_brain_run`, not in procedure: liveness *policy* (how
// often, against which configured servers, wired to which client) is a
// composition-root concern, exactly like the dream cadence loop
// (`dream_cadence_wiring.dart`). The monitor holds no `dart_mcp` type and no
// store; it drives two injected seams (`probe` / `evict`) the provisioner binds
// to the real `McpClient`. That keeps it trivially testable (this suite drives
// the pure `probeOnce()` with in-memory seams) and free of any wire dependency.
//
// Design note — optimistic start: a configured server begins **live** before
// its first probe. The boot-time tool merge reads `offered(...)` immediately
// (before the first 30 s tick), so a pessimistic default would hide every MCP
// tool at boot. A genuinely-dead server is still omitted from the merge (the
// merge's own `listTools` skips an unreachable server, PE-6) and is flipped
// dead by the first tick; an unconfigured id is never live.

import 'dart:async';

/// Probes one MCP server. Completes normally when the server is reachable;
/// throws (any error) when it is not. Production binds this to
/// `McpClient.listTools(serverId)`.
typedef McpProbe = Future<void> Function(String serverId);

/// Drops the pooled connection for a dead server so the next probe reconnects.
/// Production binds this to `McpClient.evict(serverId)`.
typedef McpEvict = Future<void> Function(String serverId);

/// The MCP liveness heartbeat: probes configured servers on an [interval] and
/// holds the live set (`agent_sdk_provider_and_mcp_liveness.md` § 3.2).
final class McpLivenessMonitor {
  /// Builds a monitor over the [serverIds] it probes, the [probe] seam it
  /// reaches each server through, and the [evict] seam it drops a dead server's
  /// connection with. [interval] defaults to the 30-second contract heartbeat.
  ///
  /// Each configured id starts optimistically **live** (see the file header);
  /// the first probe corrects any genuinely-dead server. [onProbeError], when
  /// supplied, receives an evict-time error so a teardown failure never kills
  /// the heartbeat.
  McpLivenessMonitor({
    required Iterable<String> serverIds,
    required McpProbe probe,
    required McpEvict evict,
    this.interval = const Duration(seconds: 30),
    void Function(Object error, StackTrace stack)? onProbeError,
  })  : _serverIds = List<String>.unmodifiable(serverIds),
        _probe = probe,
        _evict = evict,
        _onProbeError = onProbeError {
    for (final id in _serverIds) {
      _live[id] = true;
    }
  }

  final List<String> _serverIds;
  final McpProbe _probe;
  final McpEvict _evict;

  /// How often [probeOnce] runs once [start]ed.
  final Duration interval;

  final void Function(Object error, StackTrace stack)? _onProbeError;

  final Map<String, bool> _live = <String, bool>{};

  Timer? _timer;
  bool _probing = false;

  /// Whether [serverId] is currently live. An unconfigured id is never live.
  bool isLive(String serverId) => _live[serverId] ?? false;

  /// Whether the heartbeat is running.
  bool get isRunning => _timer != null;

  /// Probes every configured server once, updating the live set.
  ///
  /// A successful probe marks the server live; a failing one marks it dead and
  /// evicts its pooled connection (best-effort — an evict failure is routed to
  /// `onProbeError`, never thrown). Servers are probed concurrently; the call
  /// completes when every probe has settled.
  Future<void> probeOnce() async {
    await Future.wait(_serverIds.map(_probeServer));
  }

  Future<void> _probeServer(String id) async {
    try {
      await _probe(id);
      _live[id] = true;
    } catch (_) {
      _live[id] = false;
      try {
        await _evict(id);
      } catch (error, stack) {
        _onProbeError?.call(error, stack);
      }
    }
  }

  /// Starts the heartbeat. Kicks an immediate probe, then probes every
  /// [interval]. Idempotent — a second call while running is a no-op.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_pump()));
    unawaited(_pump());
  }

  /// Stops the heartbeat. Idempotent. An in-flight probe runs to completion; no
  /// new probe starts after this returns.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  /// One beat: probe unless a previous probe is still running (a slow probe must
  /// never let two ticks overlap).
  Future<void> _pump() async {
    if (_probing) return;
    _probing = true;
    try {
      await probeOnce();
    } finally {
      _probing = false;
    }
  }
}
