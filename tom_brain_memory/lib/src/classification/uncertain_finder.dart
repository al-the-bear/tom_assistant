// UncertainFinder — opt-in batch path for finding nodes whose
// classification similarity sits in a borderline band
// (memory_specification.md § 7.4).
//
// Plan step A.65:
//   "Implement `findUncertain(forKey, low, high, limit)` for the opt-in
//    batch path."
//
// Spec § 7.4:
//
//   ```dart
//   Future<List<NodeId>> findUncertain({
//     required String forKey,             // node type or procedure id
//     required double low,                // e.g. 0.45
//     required double high,               // e.g. 0.65
//     int limit = 200,
//   });
//   ```
//
//   "A procedure (`dream_recentroid_v1` or its successor) reads
//    `findUncertain`, sends those nodes to an LLM for classification,
//    persists the corrections as new `derived_from` Claims, and updates
//    centroids. Memory never originates this call."
//
// ─────────────────────────────────────────────────────────────────────
// What `findUncertain` does at A.65
// ─────────────────────────────────────────────────────────────────────
//
// Given a centroid key (`'NodeType:Question'`, `'Procedure:research_v1'`,
// …), a band `[low, high]`, and a `limit`, the finder:
//
//   1. Looks up the centroid for `forKey` on the [CentroidStore].
//      No centroid → empty result (cold start, mirroring the classifier's
//      cold-start branch — spec § 7.1).
//   2. Applies the spec § 7.1 cold-start gate: a centroid whose
//      `example_count` is below [ClassificationConfig.coldStartMinExamples]
//      is not yet trusted, and `findUncertain` returns empty rather than
//      handing a not-yet-reliable centroid to the LLM-batch path.
//   3. Enumerates the candidate node set — see "candidate enumeration"
//      below.
//   4. Reads each candidate's stored vector from `vectors.db`. Only
//      vectors stored under the **same** `embeddingModelId` as the
//      centroid contribute: a mismatch means the candidate cannot be
//      compared against the current centroid without a re-embed (spec
//      § 15 — embedding-model mismatch policy). Mismatched candidates
//      are silently dropped from this call; a future
//      `restructure_tree_v1` re-embed will bring them back into scope.
//   5. Computes cosine similarity of each candidate vector against the
//      centroid; keeps those whose similarity falls in the closed
//      interval `[low, high]`.
//   6. Returns up to `limit` ids, ordered by **similarity ascending**
//      (lowest-in-band first — the most borderline cases come first,
//      which is the most useful order for the consuming LLM-batch
//      review).
//
// ─────────────────────────────────────────────────────────────────────
// Candidate enumeration
// ─────────────────────────────────────────────────────────────────────
//
//   * `NodeType:<typeName>` — every active (non-forgotten) row in
//     `nodes` where `type_name = <typeName>` and `embedding_model_id`
//     is non-null. The `embedding_model_id` non-null filter narrows the
//     scan to rows that actually have a stored vector (spec § 4.1 —
//     types without an `EmbeddingPolicy` never set this column). Order
//     of the scan is `created_at_ms ASC` so the candidate ordering is
//     deterministic before the post-scoring sort.
//
//   * `Procedure:<procedureId>` — **deferred at A.65.** The natural
//     candidate set is "historical procedure-invocation nodes routed
//     to this procedure", which requires either a
//     `ProcedureInvocation` node type or a `routed_to_procedure` edge.
//     Neither has been introduced yet (those land alongside
//     `tom_brain_procedure`). Calling `find` with a `Procedure:*` key
//     throws [UnimplementedError] with a message naming the missing
//     wiring. The surface stays honest — a silent empty return would
//     hide the gap. See `Q-A.65.2` in
//     `prototype_implementation_questions.md`.
//
// ─────────────────────────────────────────────────────────────────────
// Why a separate class, not a method on [Classifier]
// ─────────────────────────────────────────────────────────────────────
//
// The classifier and the finder share the cosine primitive, but their
// data shapes and traversal patterns are different:
//
//   * `Classifier.classify` reads every centroid for a target and
//     scores one query vector. It does not touch `nodes` or
//     `vectors.db`.
//   * `UncertainFinder.find` reads one centroid and scans every
//     embedding-bearing node in a type. It does touch `nodes` and
//     `vectors.db`.
//
// Folding the latter into the former would force the classifier to
// take dependencies it does not currently need (a `nodes`-table read
// path, a `vectors.db` handle). Splitting keeps the classifier a pure
// in-memory transformation over `CentroidStore` and lets the finder
// own its broader storage surface independently.
//
// ─────────────────────────────────────────────────────────────────────
// Why ordered by similarity ascending, not insertion order
// ─────────────────────────────────────────────────────────────────────
//
// The consuming use case is "feed N borderline nodes to an LLM-batch
// classifier and persist its corrections". The most useful order for
// that consumer is the most uncertain first — which is similarity
// closest to the band's lower bound. Insertion-order would be cheaper
// (no sort), but the consumer would either re-sort, or process them
// in an order that mixes very-borderline and barely-borderline cases.
// Sorting here once is the right place for the cost.
//
// Tie-breaking on identical similarity is by `node_id` lexicographic
// ascending, mirroring `VectorRecall`'s tie-break shape so the rest of
// the system's "deterministic ordering" expectation holds end to end.
//
// ─────────────────────────────────────────────────────────────────────
// Sync vs async
// ─────────────────────────────────────────────────────────────────────
//
// Same shape as [Classifier]: the abstract
// `TomBrainMemory.findUncertain` returns a `Future<List<NodeId>>`. The
// finder itself is synchronous — `CentroidStore.read`, the `nodes`
// SELECT, and `VectorTable.readVectors` are all synchronous against
// their owning handles. The concrete `SqliteTomBrainMemory.findUncertain`
// (later A-step) wraps with `Future.value(...)`. Making the finder itself
// async would force every caller (including in-process dreaming
// agents and the Forge inspector) onto an event-loop hop they do not
// need.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show ClassificationConfig, ClassificationTarget, cosine, NodeId, Vec;

import '../store/vector_table.dart';
import 'centroid_store.dart';

/// One borderline candidate that survived the band filter.
///
/// Exposed for tests and for the future Forge inspector "uncertainty
/// queue" view, which renders not just the ids but the per-id
/// similarity for the operator. Production consumers
/// (`dream_recentroid_v1`) only need the ids; [UncertainFinder.find]
/// returns `List<NodeId>` directly.
final class UncertainCandidate {
  /// The node id.
  final NodeId nodeId;

  /// Cosine similarity to the centroid for the requested `forKey`.
  /// Always in `[low, high]` (inclusive).
  final double similarity;

  const UncertainCandidate({
    required this.nodeId,
    required this.similarity,
  });

  @override
  String toString() =>
      'UncertainCandidate(id: $nodeId, sim: $similarity)';
}

/// Opt-in batch path: ids of nodes whose similarity against the
/// centroid for `forKey` sits in `[low, high]`.
///
/// Construct once per `(memory.db, vectors.db, CentroidStore)` triple;
/// reuse for every `findUncertain` call. The finder holds no per-call
/// state — every call re-reads the centroid table and re-scans the
/// candidate set, so an `updateCentroid` (spec § 7.3) lands
/// immediately on the next call.
///
/// Thread / isolate safety: inherits the underlying handles' single-
/// threaded-owner rule.
final class UncertainFinder {
  final Database _memoryDb;
  final VectorTable _vectorTable;
  final CentroidStore _centroidStore;
  final ClassificationConfig _config;

  /// Constructs a finder over [memoryDb] / [vectorTable] /
  /// [centroidStore].
  ///
  /// Production wires the workspace's [MemoryConfig.classification]
  /// for the cold-start gate (`coldStartMinExamples`); tests construct
  /// a custom [ClassificationConfig] to exercise the boundary.
  UncertainFinder({
    required Database memoryDb,
    required VectorTable vectorTable,
    required CentroidStore centroidStore,
    ClassificationConfig config = const ClassificationConfig(),
  })  : _memoryDb = memoryDb,
        _vectorTable = vectorTable,
        _centroidStore = centroidStore,
        _config = config;

  /// The configuration this finder was built with. Exposed so the
  /// concrete `SqliteTomBrainMemory.findUncertain` and the Forge
  /// inspector can surface the cold-start gate in their UIs.
  ClassificationConfig get config => _config;

  /// Returns the borderline candidates with full similarity payload.
  ///
  /// Same scan path as [find]; the only difference is the return
  /// shape — `List<UncertainCandidate>` instead of `List<NodeId>`.
  /// Use this from inspector tooling and tests that need to assert on
  /// the per-id similarity.
  List<UncertainCandidate> findWithSimilarities({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) {
    _validateArgs(forKey: forKey, low: low, high: high, limit: limit);

    final centroid = _centroidStore.read(forKey);
    if (centroid == null) {
      // Cold start — no centroid registered yet for this key.
      return const <UncertainCandidate>[];
    }
    if (centroid.exampleCount < _config.coldStartMinExamples) {
      // Centroid exists but is below the trust threshold. Same
      // outcome as the classifier's cold-start gate.
      return const <UncertainCandidate>[];
    }

    final target = CentroidStore.targetOfKey(forKey);
    if (target == null) {
      throw ArgumentError.value(
        forKey,
        'forKey',
        'UncertainFinder.find: forKey "$forKey" missing recognised '
        'namespace prefix (expected "NodeType:" or "Procedure:")',
      );
    }

    switch (target) {
      case ClassificationTarget.nodeType:
        return _findForNodeType(
          typeName: forKey.substring(CentroidStore.nodeTypeKeyPrefix.length),
          centroidVec: centroid.centroid,
          centroidModelId: centroid.embeddingModelId,
          low: low,
          high: high,
          limit: limit,
        );
      case ClassificationTarget.procedure:
        throw UnimplementedError(
          'UncertainFinder.find: Procedure-keyed findUncertain '
          '("$forKey") requires a routed-to-procedure node type or '
          'edge, which lands alongside tom_brain_procedure. See '
          'Q-A.65.2 in prototype_implementation_questions.md.',
        );
      case ClassificationTarget.concept:
        throw UnimplementedError(
          'UncertainFinder.find: Concept-keyed findUncertain '
          '("$forKey") is not part of Extension H — concept centroids '
          'are recomputed by dream_recentroid_v1, not surfaced through '
          'the borderline-node batch path. See memory § 7.1.',
        );
    }
  }

  /// Returns up to [limit] node ids whose cosine similarity against
  /// the centroid for [forKey] falls in the closed interval
  /// `[low, high]`.
  ///
  /// Ordered by similarity ascending (most borderline first), with
  /// `node_id` lexicographic as the tie-breaker for determinism.
  /// Returns an empty list when:
  ///
  ///   * No centroid is registered for [forKey] (cold start).
  ///   * The centroid's `example_count` is below
  ///     [ClassificationConfig.coldStartMinExamples].
  ///   * No candidate node matches the type / band combination.
  ///   * No candidate's stored vector survives the embedding-model
  ///     identity filter against the centroid.
  ///
  /// Throws:
  ///
  ///   * [ArgumentError] when [forKey] is empty, when [low] > [high],
  ///     when [limit] < 1, or when [forKey] carries no recognised
  ///     namespace prefix.
  ///   * [UnimplementedError] when [forKey] is a `Procedure:*` key —
  ///     see the file header.
  List<NodeId> find({
    required String forKey,
    required double low,
    required double high,
    int limit = 200,
  }) {
    final candidates = findWithSimilarities(
      forKey: forKey,
      low: low,
      high: high,
      limit: limit,
    );
    return List<NodeId>.unmodifiable(
      candidates.map((c) => c.nodeId),
    );
  }

  // ─── Internal: per-target candidate enumeration ──────────────────

  List<UncertainCandidate> _findForNodeType({
    required String typeName,
    required Vec centroidVec,
    required String centroidModelId,
    required double low,
    required double high,
    required int limit,
  }) {
    // 1. Enumerate ids of active nodes of this type that carry an
    //    embedding-model identity. The `embedding_model_id IS NOT
    //    NULL` filter narrows the scan to rows that actually have a
    //    stored vector — types without an `EmbeddingPolicy` never set
    //    this column, and a candidate without a vector cannot be
    //    scored.
    //
    //    `status != 'forgotten'` keeps tombstoned rows out (the
    //    surviving row in `nodes` is a Tombstone, not the live data
    //    — see node_lifecycle.dart). The default `'active'` status
    //    covers the steady state; `'demoted'` and `'archived'` are
    //    legitimate candidates for re-classification by an LLM batch
    //    so they stay in scope.
    //
    //    Order is `created_at_ms ASC` for a stable pre-sort baseline.
    //    The final result is sorted by similarity ascending, so the
    //    SQL order matters only as a tie-breaker before the in-Dart
    //    sort — but a stable input order keeps test seeds easy to
    //    reason about.
    final rows = _memoryDb.select(
      'SELECT id, embedding_model_id FROM nodes '
      "WHERE type_name = ? AND status != 'forgotten' "
      'AND embedding_model_id IS NOT NULL '
      'ORDER BY created_at_ms ASC, id ASC',
      <Object?>[typeName],
    );
    if (rows.isEmpty) return const <UncertainCandidate>[];

    // 2. Drop candidates whose stored embedding was produced by a
    //    different model than the centroid. They cannot be compared
    //    against this centroid without a re-embed; spec § 15 names
    //    `restructure_tree_v1` as the migration that will bring them
    //    back into scope under the new model.
    final compatibleIds = <String>[];
    for (final row in rows) {
      final candidateModel = row['embedding_model_id'] as String;
      if (candidateModel != centroidModelId) continue;
      compatibleIds.add(row['id'] as String);
    }
    if (compatibleIds.isEmpty) return const <UncertainCandidate>[];

    // 3. Fetch the stored vectors in one round-trip against
    //    `vectors.db`. Ids whose vector row is missing (a
    //    referential-integrity drift between the two DBs, or a node
    //    that was persisted before its vector landed) are absent from
    //    the result map and silently dropped — the conservative
    //    branch, mirroring `VectorRecall`'s missing-row behaviour.
    final vectors = _vectorTable.readVectors(
      nodeIds: compatibleIds,
      modelId: centroidModelId,
    );
    if (vectors.isEmpty) return const <UncertainCandidate>[];

    // 4. Score every retrieved vector against the centroid and keep
    //    those in band. A dimension mismatch between the candidate
    //    and the centroid is treated as a producer bug — the
    //    embedding-model id matched but the dimensionality did not —
    //    and surfaces as `ArgumentError` from `cosine`. We do not
    //    swallow it: spec § 15's invariant is that one model id
    //    implies one dimensionality, and a violation here means a
    //    re-embed migration ran inconsistently across the centroid
    //    table and the per-node vectors. Better to surface than hide.
    final hits = <UncertainCandidate>[];
    for (final id in compatibleIds) {
      final vec = vectors[id];
      if (vec == null) continue;
      final sim = cosine(vec, centroidVec);
      if (sim < low || sim > high) continue;
      hits.add(UncertainCandidate(
        nodeId: NodeId.fromString(id),
        similarity: sim,
      ));
    }
    if (hits.isEmpty) return const <UncertainCandidate>[];

    // 5. Sort by similarity ascending (most borderline first); tie
    //    on node-id lexicographic so the order is reproducible across
    //    runs and across processes.
    hits.sort((a, b) {
      final bySimilarity = a.similarity.compareTo(b.similarity);
      if (bySimilarity != 0) return bySimilarity;
      return a.nodeId.toString().compareTo(b.nodeId.toString());
    });

    if (hits.length > limit) {
      return List<UncertainCandidate>.unmodifiable(hits.sublist(0, limit));
    }
    return List<UncertainCandidate>.unmodifiable(hits);
  }

  void _validateArgs({
    required String forKey,
    required double low,
    required double high,
    required int limit,
  }) {
    if (forKey.isEmpty) {
      throw ArgumentError.value(
        forKey,
        'forKey',
        'UncertainFinder.find: forKey must be non-empty',
      );
    }
    if (limit < 1) {
      throw ArgumentError.value(
        limit,
        'limit',
        'UncertainFinder.find: limit must be >= 1',
      );
    }
    if (low.isNaN || high.isNaN) {
      throw ArgumentError(
        'UncertainFinder.find: low ($low) and high ($high) must be '
        'finite numbers, not NaN',
      );
    }
    if (low > high) {
      throw ArgumentError(
        'UncertainFinder.find: low ($low) must be <= high ($high)',
      );
    }
  }
}
