// B.9 — `SubstrateStats` value class.
//
// substrate_specification.md § 10.3: cheaply-refreshable point-in-time
// counters exposed by `TomBrainSubstrateClient.stats()`. No SQL backs
// this; counters live in memory and are sampled on demand. Consumers
// (Tom Forge brain inspector, operator-side health probes, tests)
// poll this rather than subscribe to the firehose of events.

/// Point-in-time snapshot of substrate counters.
final class SubstrateStats {
  /// Wall-clock at which the snapshot was taken (UTC).
  final DateTime snapshotAt;

  /// LLM call count per `providerId`.
  final Map<String, int> callsPerProvider;

  /// LLM call count per `roleId`.
  final Map<String, int> callsPerRole;

  /// Embeddings produced (single + batched together).
  final int embeddingsComputed;

  /// Number of credential cooldowns currently active across all
  /// providers.
  final int activeCooldowns;

  /// Wall-clock of the most recent provider failover, UTC.
  /// `null` when no failover has happened since open.
  final DateTime? lastFailoverAt;

  /// Web searches issued.
  final int webSearches;

  /// Web fetches issued.
  final int webFetches;

  /// Outbound MCP tool calls issued.
  final int mcpCalls;

  const SubstrateStats({
    required this.snapshotAt,
    required this.callsPerProvider,
    required this.callsPerRole,
    required this.embeddingsComputed,
    required this.activeCooldowns,
    required this.lastFailoverAt,
    required this.webSearches,
    required this.webFetches,
    required this.mcpCalls,
  });

  /// All-zero snapshot. Used as the post-`open` initial value by
  /// the in-process facade and by tests that need a baseline.
  factory SubstrateStats.empty(DateTime snapshotAt) => SubstrateStats(
        snapshotAt: snapshotAt,
        callsPerProvider: const <String, int>{},
        callsPerRole: const <String, int>{},
        embeddingsComputed: 0,
        activeCooldowns: 0,
        lastFailoverAt: null,
        webSearches: 0,
        webFetches: 0,
        mcpCalls: 0,
      );
}
