// Classification `MemoryEvent` leaves —
//   * `ClassificationComputed` (spec § 16) — emitted once per
//     `Classifier.classify` call, carrying the decision and the two
//     similarity scores that produced it.
//   * `CentroidUpdated` (spec § 16) — emitted on every successful
//     `CentroidStore.update`, carrying the row identity (key, model,
//     example count, dimension) and whether the upsert created a fresh
//     row or replaced an existing one.
//
// These sit alongside the existing `CentroidDriftDetected` shaking
// event (`cognitive_agents/shaking_events.dart`). The split is by
// purpose, not by producer: `CentroidUpdated` is the *unconditional*
// audit of every centroid write; `CentroidDriftDetected` is the
// *conditional* signal that a write moved the centroid beyond
// tolerance. A single `update` that crosses the drift threshold emits
// both — one on the observability audit stream, one on the shaking
// stream — and a subscriber correlates them by `forKey` + `occurredAt`.
//
// The discriminators (`memory.classification-computed`,
// `memory.centroid-updated`) follow the per-component convention
// documented on `MemoryEvent`.

import '../api/memory_event.dart';
import 'classification_result.dart'
    show ClassificationDecision, ClassificationTarget;

/// Emitted when `Classifier.classify` returns a decision.
///
/// One event per call, including the cold-start `unknown` paths (no
/// eligible centroids): "the classifier was asked and answered" is
/// the observable fact, and an `unknown` answer is still an answer.
/// Subscribers that only care about confident verdicts filter on
/// [decision] themselves.
///
/// [bestMatch] is the bare (namespace-stripped) key of the winning
/// centroid, or `null` on the cold-start `unknown` paths where no
/// centroid was scored. [bestSimilarity] / [secondSimilarity] mirror
/// the returned `ClassificationResult`; both are `0.0` on the
/// cold-start paths.
final class ClassificationComputed extends MemoryEvent {
  /// Which namespace the classification ran against.
  final ClassificationTarget target;

  /// The decision the rule produced.
  final ClassificationDecision decision;

  /// Bare winning key (no `NodeType:` / `Procedure:` prefix), or
  /// `null` when no centroid was scored (cold start).
  final String? bestMatch;

  /// Cosine similarity of the best centroid.
  final double bestSimilarity;

  /// Cosine similarity of the runner-up (or `0.0` when there was no
  /// runner-up / no eligible centroid).
  final double secondSimilarity;

  const ClassificationComputed({
    required this.target,
    required this.decision,
    required this.bestSimilarity,
    required this.secondSimilarity,
    required super.occurredAt,
    this.bestMatch,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.classification-computed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'target': target.name,
        'decision': decision.name,
        if (bestMatch != null) 'bestMatch': bestMatch,
        'bestSimilarity': bestSimilarity,
        'secondSimilarity': secondSimilarity,
      };
}

/// Emitted on every successful `CentroidStore.update` upsert.
///
/// Carries the identity of the row that now lives in the table so a
/// subscriber can reconstruct the centroid-write audit without
/// re-reading SQLite: the namespaced [forKey], the [embeddingModelId]
/// that produced the vector, the [exampleCount] backing it, the
/// vector [dimensions], and whether this upsert [created] a fresh row
/// ([created] `true`, no prior row) or replaced an existing one
/// ([created] `false`).
///
/// `runId` / `causedBy` are threaded from the optional `Scope` passed
/// to `update` — typically a `dream_recentroid_v1` run.
final class CentroidUpdated extends MemoryEvent {
  /// Namespaced centroid key, e.g. `'NodeType:Question'`.
  final String forKey;

  /// Embedding-model identity that produced the written centroid.
  final String embeddingModelId;

  /// Number of accepted examples backing the written centroid.
  final int exampleCount;

  /// Dimensionality of the written centroid vector.
  final int dimensions;

  /// `true` when the upsert inserted a fresh row (no prior centroid
  /// for [forKey]); `false` when it replaced an existing row.
  final bool created;

  const CentroidUpdated({
    required this.forKey,
    required this.embeddingModelId,
    required this.exampleCount,
    required this.dimensions,
    required this.created,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.centroid-updated';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'forKey': forKey,
        'embeddingModelId': embeddingModelId,
        'exampleCount': exampleCount,
        'dimensions': dimensions,
        'created': created,
      };
}
