// ProfileAggregator — the cross-profile global-aggregation engine
// (memory_specification.md § 2.6, GA-3 / GA-4 / GA-6 / GA-7 / GA-9).
//
// One pass reads the durable, semantic knowledge out of every source
// profile and re-derives it into the reserved read-only `global` profile,
// stamping provenance on each derived node. The invariant the whole tier
// rests on (GA-INV) is realised **by construction** here:
//
//   * sources are read through the registry's read seam
//     (`readInProfile`) and only ever `stream`-scanned — never recalled
//     (so no usage telemetry is bumped, GA-9) and never written;
//   * `global` is the single profile ever opened for writing, through the
//     registry's `writeInProfile` seam, opened **once per pass** (GA-6);
//   * nothing flows back into any source — the derived node lives only in
//     `global`, and provenance is recorded as node *values*, not as a
//     cross-store edge (which store isolation forbids).
//
// The pass is idempotent (GA-7): each derived node carries a stable
// `aggregate:<type>:<sourceProfile>:<sourceNodeId>` idempotency key, so a
// re-run persists nothing new — `persist` returns the original id and
// inserts no row.
//
// This is the Dart engine half of the tier (build-step #12, Phase 1). The
// d4rt `dream_aggregate_v1` procedure, the `aggregator` agent registration,
// and the `aggregate` cadence lane that schedules this pass off-by-default
// are the deferred Phase-2 remainder (see `tom_brain_completion_plan_2.md`).

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Clock,
        MemoryProfileRegistry,
        Node,
        NodeDraft,
        Scope,
        StreamQuery,
        SymbolicFilter,
        Vec,
        reservedGlobalProfile;

import '../store/sqlite_tom_brain_memory.dart';
import 'aggregation_config.dart';
import 'aggregation_provenance.dart';

/// Stable producer identity stamped on every aggregated node's `Scope`
/// (memory § 2.6, GA-5). This is the GA-5 attribution the Phase-1 engine
/// uses; it is sufficient for provenance and never triggers the
/// `AgentRegistry` write guard (that guard is a no-op when `agentName` is
/// null).
const String aggregatorProducer = 'dream_aggregate_v1';

/// The agent identity the aggregation writes will be issued under **once
/// the Phase-2 `aggregator` agent is registered** (memory § 2.6, GA-5).
///
/// Deliberately NOT stamped on the Phase-1 write scope: the `AgentRegistry`
/// rejects any `agentName` it has no registration for, and that
/// registration is the deferred Phase-2 remainder (the `dream_aggregate_v1`
/// procedure + `aggregator` agent + `aggregate` cadence lane — see
/// `tom_brain_completion_plan_2.md`). The Phase-1 engine attributes via
/// `producer` only; Phase 2 adds the registration and this `agentName`.
const String aggregatorAgentName = 'aggregator';

/// Summary of one aggregation pass — what was scanned and derived.
final class AggregationPassResult {
  /// The source profiles scanned this pass (in registry order, with the
  /// reserved `global` profile and any excluded profiles removed).
  final List<String> sourceProfiles;

  /// Total source nodes scanned across every source profile.
  final int nodesScanned;

  /// Number of derive→persist calls issued into `global`. Note this counts
  /// persist *calls*, not net-new rows: an idempotent re-run derives the
  /// same nodes (so `nodesDerived` is unchanged) while inserting zero new
  /// rows.
  final int nodesDerived;

  /// Whether the pass ran at all. `false` when the tier is disabled
  /// (GA-11) — nothing was scanned and nothing written.
  final bool ran;

  const AggregationPassResult({
    required this.sourceProfiles,
    required this.nodesScanned,
    required this.nodesDerived,
    this.ran = true,
  });

  /// The no-op result returned when the tier is disabled (GA-11).
  const AggregationPassResult.disabled()
      : sourceProfiles = const <String>[],
        nodesScanned = 0,
        nodesDerived = 0,
        ran = false;
}

/// The cross-profile aggregation engine (memory § 2.6).
///
/// Stateless beyond its injected collaborators: a single [runPass] reads
/// every source profile and (re-)derives its allowlisted nodes into
/// `global`. Constructed by the composition root from the owning store's
/// [MemoryProfileRegistry] and clock.
final class ProfileAggregator {
  final MemoryProfileRegistry _registry;
  final AggregationConfig _config;
  final Clock _clock;

  ProfileAggregator({
    required MemoryProfileRegistry registry,
    required Clock clock,
    AggregationConfig config = const AggregationConfig(),
  })  : _registry = registry,
        _clock = clock,
        _config = config;

  /// Runs one aggregation pass. Returns a summary of what was scanned and
  /// derived; a no-op [AggregationPassResult.disabled] when the tier is
  /// off (GA-11).
  Future<AggregationPassResult> runPass() async {
    if (!_config.enabled) return const AggregationPassResult.disabled();

    final all = await _registry.list();
    // GA-INV: never read `global` as a source (it would re-aggregate its
    // own output), and honour the operator's excludeProfiles.
    final sources = all
        .where((p) =>
            p != reservedGlobalProfile && !_config.excludeProfiles.contains(p))
        .toList();

    if (sources.isEmpty || _config.nodeTypes.isEmpty) {
      return AggregationPassResult(
        sourceProfiles: sources,
        nodesScanned: 0,
        nodesDerived: 0,
      );
    }

    final filter = SymbolicFilter(typeNames: _config.nodeTypes);
    var scanned = 0;
    var derived = 0;

    // GA-6: open the write target (`global`) exactly once for the whole
    // pass; it is the only profile ever opened for writing here.
    await _registry.writeInProfile(reservedGlobalProfile, (globalClient) async {
      for (final source in sources) {
        // GA-9: a stream scan over the source — access-neutral, so it never
        // bumps usage columns (unlike recall). The read seam is read-only by
        // contract; the in-process cast reaches the vector readback the read
        // path omits (Q-A.35.1), so the source embedding is copied verbatim.
        // Sound: the only registry implementation spawns in-process
        // `SqliteTomBrainMemory` child stores.
        final scanned0 = await _registry.readInProfile(
          source,
          (src) async {
            final store = src as SqliteTomBrainMemory;
            final nodes =
                await store.stream(StreamQuery(filter: filter)).toList();
            final embeddings =
                await store.readEmbeddings([for (final n in nodes) n.id]);
            return [
              for (final n in nodes) (n, embeddings[n.id]),
            ];
          },
        );
        for (final (node, embedding) in scanned0) {
          scanned++;
          final draft =
              _derive(node, sourceProfile: source, embedding: embedding);
          // GA-7: idempotent per (type, source profile, source node).
          await globalClient.persist(draft, scope: _scopeFor(source, node));
          derived++;
        }
      }
    });

    return AggregationPassResult(
      sourceProfiles: sources,
      nodesScanned: scanned,
      nodesDerived: derived,
    );
  }

  /// Builds the `global` node from a source [node]: copies its semantic
  /// values (dropping any inbound provenance, defence in depth), stamps the
  /// three GA-4 provenance fields, and carries the source embedding over so
  /// `global` is vector-recallable without re-embedding.
  NodeDraft _derive(
    Node node, {
    required String sourceProfile,
    required Vec? embedding,
  }) {
    final values = <String, Object?>{};
    node.values.forEach((key, value) {
      if (aggregationProvenanceKeys.contains(key)) return;
      values[key] = value;
    });
    values[aggregationSourceProfileKey] = sourceProfile;
    values[aggregationSourceNodeIdKey] = node.id.value;
    values[aggregationAtKey] = _clock.now().toUtc().toIso8601String();
    return NodeDraft(
      typeName: node.typeName,
      values: values,
      embedding: embedding,
    );
  }

  /// The idempotent, attributed write scope for a derived node (GA-5/7).
  ///
  /// Attribution is by `producer` only. `agentName` is intentionally left
  /// null in Phase 1: the `AgentRegistry` rejects an unregistered agent,
  /// and the `aggregator` registration is the deferred Phase-2 remainder
  /// (see [aggregatorAgentName]). The idempotency key is what makes a
  /// re-run a no-op (GA-7) and does not depend on the agent.
  Scope _scopeFor(String sourceProfile, Node node) => Scope(
        producer: aggregatorProducer,
        idempotencyKey:
            'aggregate:${node.typeName}:$sourceProfile:${node.id.value}',
      );
}
