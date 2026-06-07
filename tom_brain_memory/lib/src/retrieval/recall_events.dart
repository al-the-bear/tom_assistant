// Retrieval `MemoryEvent` leaf — `RecallCompleted`.
//
// Spec § 16 names `RecallCompleted` ("carries `RecallReport`") as one
// of the typed events memory fans out over the single observability
// stream (`TomBrainMemory.events()`). This file lands the leaf; the
// emission point is the `RecallExecutor.recall` tail, where the report
// is already assembled.
//
// Unlike the node-lifecycle leaves (which emit only on a state
// transition), a recall is a read — there is no transition to gate on.
// `RecallCompleted` therefore follows the same "one event per call"
// convention `RecallReport` itself does: every `recall` that produces a
// report emits exactly one `RecallCompleted`, including the empty-modes
// and degraded paths. Subscribers wanting only the interesting recalls
// filter on `degraded` / `returnedCount` themselves (the bus does not
// push typed filters — see `MemoryEventBus`).
//
// The discriminator (`memory.recall-completed`) follows the
// per-component convention documented on `MemoryEvent`.

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryEvent, RecallMode, RecallProvenanceEntry, RecallReport;

/// Emitted when `RecallExecutor.recall` finishes a recall call.
///
/// Carries the assembled [report] (spec § 16: "carries
/// `RecallReport`") plus the two summary numbers a subscriber most
/// often wants without reaching into the report: the modes the caller
/// requested and how many nodes the call ultimately returned.
///
/// `runId` / `causedBy` are threaded from the optional `Scope` passed
/// to `recall` — `null` when the caller supplied no scope, exactly as
/// the sibling `RetrievalConflict` shaking event does.
final class RecallCompleted extends MemoryEvent {
  /// The modes the caller requested, in request order. Empty when the
  /// caller asked for no modes (the empty-result fast path).
  final List<RecallMode> requestedModes;

  /// Number of nodes the recall ultimately returned (post-fusion,
  /// post-diversify, post-re-rank, truncated to `RecallQuery.k`).
  final int returnedCount;

  /// The cost / candidacy report the same call returned to the caller.
  /// Held by reference; consumers MUST treat it as read-only.
  final RecallReport report;

  const RecallCompleted({
    required this.requestedModes,
    required this.returnedCount,
    required this.report,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.recall-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'requestedModes':
            requestedModes.map((m) => m.name).toList(growable: false),
        'returnedCount': returnedCount,
        'candidatesPerMode': <String, Object?>{
          for (final entry in report.candidatesPerMode.entries)
            entry.key.name: entry.value,
        },
        'fusionStrategy': report.fusionStrategy.name,
        'diversityStrategy': report.diversityStrategy.name,
        if (report.diversityLambda != null)
          'diversityLambda': report.diversityLambda,
        'elapsedMs': report.elapsedMs,
        'embeddingsCallouts': report.embeddingsCallouts,
        'reRankInvoked': report.reRankInvoked,
        'degraded': report.degraded,
      };
}

/// Emitted when `RecallExecutor.recallMulti` finishes a multi-seed
/// recall call (§ 6.5, Extension H).
///
/// Spec § 16 names `MultiRecallCompleted` as "carries per-seed
/// candidate counts + fused result provenance". The per-seed counts
/// ([seedCandidateCounts]) are index-aligned with the
/// `MultiRecallQuery.seeds` list; [provenance] is the same per-node
/// provenance the call returned on `RecallResult.provenance`.
///
/// Like its single-seed sibling [RecallCompleted], it fires once per
/// call (including the empty-seeds and degraded paths) and threads
/// `runId` / `causedBy` from the optional `Scope`.
final class MultiRecallCompleted extends MemoryEvent {
  /// Pre-fusion candidate count per seed, index-aligned with the
  /// `MultiRecallQuery.seeds` list.
  final List<int> seedCandidateCounts;

  /// Number of nodes the recall ultimately returned (post-fusion,
  /// post-diversify, truncated to `MultiRecallQuery.k`).
  final int returnedCount;

  /// The cost / candidacy report the same call returned. Held by
  /// reference; consumers MUST treat it as read-only.
  final RecallReport report;

  /// Per-node seed provenance the call returned, index-aligned with
  /// the result node list.
  final List<RecallProvenanceEntry> provenance;

  const MultiRecallCompleted({
    required this.seedCandidateCounts,
    required this.returnedCount,
    required this.report,
    required this.provenance,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.multi-recall-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'seedCandidateCounts':
            seedCandidateCounts.toList(growable: false),
        'returnedCount': returnedCount,
        'fusionStrategy': report.fusionStrategy.name,
        'diversityStrategy': report.diversityStrategy.name,
        if (report.diversityLambda != null)
          'diversityLambda': report.diversityLambda,
        'elapsedMs': report.elapsedMs,
        'degraded': report.degraded,
        'provenance': provenance
            .map((e) => <String, Object?>{
                  'nodeId': e.nodeId.value,
                  'seedIndexes': e.seedIndexes.toList(growable: false),
                  'fusedScore': e.fusedScore,
                })
            .toList(growable: false),
      };
}
