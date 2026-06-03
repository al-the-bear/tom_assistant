// Shaking events — the four `MemoryEvent` leaves named in spec § 9.4
// and § 16. A shaking event is a typed signal that something previously
// accepted is now in question; the dispatcher routes them to
// `dream_reconsolidate_v1`.
//
// Plan step A.69 owns this file.
//
// The four sub-kinds, with their detection sites and emission triggers:
//
//   - `ContradictionDetected` — emitted by `EdgeWriter` immediately
//     after a successful `contradicts` edge insert. The closed-alphabet
//     edge documentation in `edge_type.dart` names this event as the
//     downstream effect of the `contradicts` label.
//
//   - `CentroidDriftDetected` — emitted by `CentroidStore.update` when
//     the new centroid has drifted from the prior one by more than
//     the configured cosine-similarity threshold AND the prior row
//     met the `defaultDriftMinPreviousExamples` floor. A first-ever
//     update emits nothing; a model-id change emits unconditionally
//     (the prior vector is incommensurable). See Q-A.69.2 for the
//     threshold rationale.
//
//   - `RetrievalConflict` — emitted by `RecallExecutor.recall` after
//     mode execution but before fusion when at least two modes
//     returned non-empty candidate lists AND the intersection of
//     their top-`min(5, perModeK)` `NodeId`s is empty. See
//     Q-A.69.3 for the disagreement-rule rationale.
//
//   - `CritiqueRejected` — emitted by sleep-cycle agent procedures
//     (`dream_critique_v1` and friends) via the `ShakingEventEmitter`
//     helper. Memory has no internal signal that says "a critique
//     ran and rejected node X"; the class is the typed building
//     block agents construct. The abstract `raiseShakingEvent`
//     method on `TomBrainMemory` lands with the concrete
//     `SqliteTomBrainMemory` implementation step (see Q-A.69.4 —
//     same deferral pattern as `beginRun` / `endRun` /
//     `remainingBudget` at A.68).
//
// Discriminator convention: every shaking sub-kind's `kind` is
// `memory.shaking.<sub-kind-name>` (kebab-cased). This makes
// subscribers' "is this a shaking event?" check a single string
// prefix test on the `kind` discriminator, and keeps the shaking
// family identifiable in serialised event streams without a
// reflection cast.

import 'package:tom_brain_shared/tom_brain_shared.dart' show EdgeId, EdgeType, MemoryEvent, NodeId, RecallMode;

/// Common discriminator prefix for every shaking sub-kind. Subscribers
/// that want "the whole shaking family" can filter on
/// `event.kind.startsWith(ShakingEvent.kindPrefix)`.
///
/// Centralising the prefix here means a future fifth shaking sub-kind
/// inherits the prefix without churn, and a typo in any one leaf's
/// `kind` is caught by the prefix invariant (each leaf's `kind` is
/// `'$kindPrefix<sub-kind-name>'`).

/// Base class for the four shaking-event sub-kinds named in
/// spec § 9.4. A shaking event is a typed signal that something
/// previously accepted is now in question; the dispatcher routes
/// them to `dream_reconsolidate_v1`.
///
/// Sub-kinds:
///
///   * [ContradictionDetected] — `contradicts` edge committed.
///   * [CentroidDriftDetected] — centroid moved beyond the drift
///     threshold.
///   * [RetrievalConflict] — recall modes returned disjoint top-K.
///   * [CritiqueRejected] — sleep-cycle critique procedure rejected
///     a previously-accepted node.
///
/// Sealed so subscribers can switch over the four sub-kinds
/// exhaustively. Adding a fifth sub-kind is intentionally a breaking
/// change in this layer.
sealed class ShakingEvent extends MemoryEvent {
  /// Shared `kind` prefix every concrete sub-kind starts with. See
  /// the file header for the convention.
  static const String kindPrefix = 'memory.shaking.';

  const ShakingEvent({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });
}

/// Emitted by `EdgeWriter.edge` immediately after a successful
/// `contradicts` edge insert. Pairs with the `EdgeCreated` event that
/// the same write also emits — consumers see `EdgeCreated` first
/// (the structural fact), `ContradictionDetected` second (the
/// cognitive signal that the new edge invalidates whatever its `to`
/// endpoint had previously concluded).
///
/// Carries the new edge's id, both endpoints, and the resolved
/// endpoint type names so consumers can decide how to react without
/// re-reading either endpoint (e.g. a `Pruner` agent that only acts
/// on `Conclusion --contradicts--> Conclusion` need not fetch the
/// rows to filter by type).
final class ContradictionDetected extends ShakingEvent {
  /// Id of the freshly-committed `contradicts` edge.
  final EdgeId edgeId;

  /// Source endpoint of the `contradicts` edge — the node that
  /// disagrees.
  final NodeId from;

  /// Destination endpoint of the `contradicts` edge — the node being
  /// contradicted.
  final NodeId to;

  /// Type name of the source endpoint at the moment of the write.
  /// Cached here so observability never has to re-fetch the row.
  final String fromTypeName;

  /// Type name of the destination endpoint at the moment of the write.
  final String toTypeName;

  const ContradictionDetected({
    required this.edgeId,
    required this.from,
    required this.to,
    required this.fromTypeName,
    required this.toTypeName,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => '${ShakingEvent.kindPrefix}contradiction-detected';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'edgeId': edgeId.toString(),
        'from': from.toString(),
        'to': to.toString(),
        'type': EdgeType.contradicts.wireName,
        'fromTypeName': fromTypeName,
        'toTypeName': toTypeName,
      };
}

/// Emitted by `CentroidStore.update` when the new centroid moved
/// beyond the configured drift threshold from the prior one.
///
/// Two parameters gate the emission (defaults documented on
/// `CentroidStore`):
///
///   * Cosine similarity between prior and new centroid is **strictly
///     less than** `driftCosineThreshold` (default `0.85`).
///   * Prior `exampleCount` is **at least** `minPreviousExamples`
///     (default `8`).
///
/// A first-ever update (no prior row) emits nothing — there is
/// nothing to compare. A model-id change between prior and new emits
/// unconditionally regardless of the cutoff: a different embedding
/// model produces incommensurable vectors, and the only correct
/// downstream reaction is a re-embed migration.
///
/// Carries the namespaced [forKey], the new and prior model ids
/// (they may differ — see above), the new and prior example counts,
/// the measured cosine similarity (or `null` when comparison was
/// short-circuited by a model-id change), and the threshold that was
/// in effect.
final class CentroidDriftDetected extends ShakingEvent {
  /// Namespaced centroid key (`'NodeType:Question'`,
  /// `'Procedure:research_v1'`, …).
  final String forKey;

  /// Embedding-model identity of the NEW centroid.
  final String embeddingModelId;

  /// Embedding-model identity of the PRIOR centroid. Equal to
  /// [embeddingModelId] in the normal drift case; different when the
  /// emission was triggered by a model-id change.
  final String previousEmbeddingModelId;

  /// Example count backing the NEW centroid.
  final int exampleCount;

  /// Example count backing the PRIOR centroid.
  final int previousExampleCount;

  /// Cosine similarity between prior and new centroid in [-1, 1].
  /// `null` when the emission was triggered by a model-id change
  /// (vectors are incommensurable; no meaningful cosine).
  final double? cosineSimilarity;

  /// Threshold in effect at the moment of the emission. Carried in
  /// the event so subscribers can correlate threshold tuning with
  /// shaking-event volume without consulting external configuration.
  final double driftCosineThreshold;

  const CentroidDriftDetected({
    required this.forKey,
    required this.embeddingModelId,
    required this.previousEmbeddingModelId,
    required this.exampleCount,
    required this.previousExampleCount,
    required this.cosineSimilarity,
    required this.driftCosineThreshold,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  /// `true` when the emission was triggered solely by the prior and
  /// new centroids using different embedding model ids — distinct
  /// from a normal cosine-cutoff drift signal.
  bool get isEmbeddingModelChange =>
      embeddingModelId != previousEmbeddingModelId;

  @override
  String get kind => '${ShakingEvent.kindPrefix}centroid-drift-detected';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'forKey': forKey,
        'embeddingModelId': embeddingModelId,
        'previousEmbeddingModelId': previousEmbeddingModelId,
        'exampleCount': exampleCount,
        'previousExampleCount': previousExampleCount,
        if (cosineSimilarity != null) 'cosineSimilarity': cosineSimilarity,
        'driftCosineThreshold': driftCosineThreshold,
        if (isEmbeddingModelChange) 'embeddingModelChange': true,
      };
}

/// Emitted by `RecallExecutor.recall` after mode execution but before
/// fusion when (a) at least two modes returned non-empty candidate
/// lists AND (b) the intersection of their top-`min(5, perModeK)`
/// `NodeId`s is empty.
///
/// "Empty intersection of top-K" is the strongest disagreement signal:
/// every contributing mode has produced candidates and none of them
/// agree on a single node. RRF will still fuse those lists, but the
/// resulting ordering is structurally fragile — a small change to
/// per-mode scoring would re-order the whole result. See Q-A.69.3
/// for the rationale on the rule and the K choice.
///
/// Carries the per-mode top-K lists so consumers can inspect what
/// each mode wanted. The map is immutable.
final class RetrievalConflict extends ShakingEvent {
  /// The recall modes that disagreed. Always at least two entries.
  /// Modes that returned empty candidates are not included — they
  /// did not contribute to the disagreement.
  final List<RecallMode> conflictingModes;

  /// Per-mode top-K candidate id lists, keyed by mode. Only the
  /// entries for modes in [conflictingModes] are present. K is
  /// `min(5, perModeK)`.
  final Map<RecallMode, List<NodeId>> topPerMode;

  /// The K window used to compute the empty-intersection check.
  /// Carried for correlation; equals `min(5, perModeK)`.
  final int topK;

  RetrievalConflict({
    required List<RecallMode> conflictingModes,
    required Map<RecallMode, List<NodeId>> topPerMode,
    required this.topK,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  })  : conflictingModes = List<RecallMode>.unmodifiable(conflictingModes),
        topPerMode = Map<RecallMode, List<NodeId>>.unmodifiable(topPerMode);

  @override
  String get kind => '${ShakingEvent.kindPrefix}retrieval-conflict';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'conflictingModes':
            conflictingModes.map((m) => m.name).toList(growable: false),
        'topPerMode': <String, Object?>{
          for (final entry in topPerMode.entries)
            entry.key.name:
                entry.value.map((id) => id.toString()).toList(growable: false),
        },
        'topK': topK,
      };
}

/// Emitted by sleep-cycle agent procedures (`dream_critique_v1` and
/// friends) when a previously-accepted node fails a critique pass.
/// The class is constructed inside the procedure and raised onto the
/// memory event stream via the `ShakingEventEmitter` helper (or the
/// abstract `raiseShakingEvent` method when the concrete
/// `SqliteTomBrainMemory` lands).
///
/// Memory has no internal signal that says "a critique ran and
/// rejected node X" — the typed shape lives here for consolidation
/// of the shaking family, but the *emission* is agent-driven. See
/// Q-A.69.4 for the rationale.
///
/// Carries the subject node id, its type name (resolved by the
/// agent at the moment of the rejection), the agent's reason
/// string, an optional critic identifier (e.g.
/// `'dream_critique_v1:run-2026-05-31T03:00:00Z'`), and optional
/// `evidenceNodeIds` pointing at the supporting evidence the
/// critique considered.
final class CritiqueRejected extends ShakingEvent {
  /// Id of the node the critique rejected.
  final NodeId subjectNodeId;

  /// Type name of the rejected node at the moment of the rejection.
  /// Resolved by the agent (it owns the read) and stored here so
  /// observability never has to re-fetch the row.
  final String subjectTypeName;

  /// Free-form reason from the critique procedure. Surfaces verbatim
  /// in the operator log and is consumed by `dream_reconsolidate_v1`
  /// to decide the next action.
  final String reason;

  /// Identifier of the procedure run that performed the critique.
  /// `null` when the rejection was raised outside a tracked run
  /// (e.g. an operator-initiated manual critique).
  final String? critic;

  /// Ids of the evidence nodes the critique considered, when the
  /// agent supplied them. Empty list is legal — not every rejection
  /// names its evidence.
  final List<NodeId> evidenceNodeIds;

  const CritiqueRejected({
    required this.subjectNodeId,
    required this.subjectTypeName,
    required this.reason,
    required super.occurredAt,
    this.critic,
    this.evidenceNodeIds = const <NodeId>[],
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => '${ShakingEvent.kindPrefix}critique-rejected';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'subjectNodeId': subjectNodeId.toString(),
        'subjectTypeName': subjectTypeName,
        'reason': reason,
        if (critic != null) 'critic': critic,
        if (evidenceNodeIds.isNotEmpty)
          'evidenceNodeIds':
              evidenceNodeIds.map((id) => id.toString()).toList(growable: false),
      };
}
