// VectorRecall — vector-mode executor for `RecallQuery.embedding`
// (Plan step A.55, spec § 6.1 vector mode).
//
// What this file owns:
//
//   - Resolving the set of embedding-bearing node types to query, under
//     an optional `typeNames` filter taken from the symbolic filter at
//     the call site.
//   - Grouping those types by their `EmbeddingPolicy.modelIdentity` so
//     each `vectors.db` per-model index is hit at most once per call.
//   - Filtering model groups whose installed dimensionality does not
//     match the query vector's dimension. A single vector recall
//     carries one query embedding produced by one model; model groups
//     with a different installed `dims` are unreachable from this call
//     and are silently skipped (a different recall, with a different
//     query embedding, would reach them).
//   - Calling `VectorTable.queryNearest` for each surviving model
//     group with `perModeK` as the per-group cap.
//   - Enriching each hit with the node's `type_name` via a single
//     `SELECT id, type_name FROM nodes WHERE id IN (...)` per model
//     group — so a model index that legitimately holds vectors for
//     multiple node types still yields per-type-tagged candidates.
//   - Re-filtering the enriched matches by the candidate-type set, so
//     a model group that holds vectors for types outside the caller's
//     filter does not leak through.
//   - Merging the per-group results into a single ranked list ordered
//     by ascending distance and capped at `perModeK`.
//
// What this file does NOT own:
//
//   - Embedding the query text. The contract per
//     `recall_query.dart` and spec § 6.1 is that the caller supplies
//     `RecallQuery.embedding` when running vector mode (or, in a
//     future step, that the recall executor at A.59 fans out an embed
//     callout on the caller's behalf). At A.55 the executor takes a
//     `Vec query` directly; the embed-on-behalf path lands with the
//     recall-executor wiring.
//   - Fusion across modes (A.57 RRF / weighted).
//   - Diversity (A.58 MMR).
//   - Symbolic filter compilation (A.56). The `typeNames` parameter
//     accepts the symbolic-filter's type-name set when present; the
//     wider `WHERE` shape is not applied at A.55.
//   - The `RecallReport` cost row. The recall executor at A.59 will
//     compose this output with the report (and, per spec § 6.4, will
//     count `embeddingsCallouts` when it had to embed on behalf).
//   - Degraded-mode signalling. The `VectorIndexUnavailable` event is
//     emitted at boot by `loadVecExtensionWithFailOpen` (A.50). The
//     recall executor at A.59 will set `RecallReport.degraded` when
//     vector mode is in the requested set but no vector backend is
//     available. The executor at this layer just returns empty when
//     no installed index can serve the query.
//
// Wire contract:
//
//   The `VectorRecallCandidate` carries
//   `(nodeId, typeName, modelId, distance)`. It deliberately does
//   *not* carry the materialised `Node` — that read happens in one
//   bulk `NodeReader.getMany` after fusion + diversity, so vector
//   results that lose the fusion stage do not cost a `nodes` row read
//   each.
//
//   The score field name is `distance` (not `score`) so the future
//   fusion record carrying multiple per-mode scores can disambiguate
//   "lower is better" (vec) from "lower is better" (bm25) at the
//   field name. The two share a sign convention by accident — the
//   fusion stage at A.57 normalises per mode anyway.
//
// Cross-model ordering:
//
//   The merge is a plain ascending sort on `distance`. Distances from
//   different embedding models are *not* comparable in any
//   semantically-meaningful sense — a 0.4 cosine-derived L2 from
//   `nomic-embed-text@v1.5` and a 0.4 cosine-derived L2 from
//   `openai/text-embedding-3-small` describe different geometries. We
//   sort them together anyway because:
//
//     (a) the vast majority of deployments install one embedding
//         model, so the cross-model branch is dormant;
//     (b) when more than one model is installed, the per-mode fusion
//         stage at A.57 (RRF) collapses distances to ranks before
//         anything else looks at them, so the only thing the
//         per-distance sort buys here is a deterministic tie-break;
//     (c) routing the query to a single matching model is the
//         caller's job — the substrate decides which model produced
//         the query embedding, and only that model's index is dim-
//         compatible.
//
//   When two candidates from different models share a distance value,
//   the merge falls back to (`modelId`, `nodeId`) lexicographic to
//   keep tests deterministic.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, Vec;

import '../nodes/node_type_registry.dart';
import '../store/vector_table.dart';
import '../store/vector_table_exception.dart';

/// A single vector-mode candidate.
///
/// The recall executor returns these ordered by ascending [distance]
/// (`vec0`'s convention: smaller distance = more similar to the
/// query vector).
final class VectorRecallCandidate {
  /// The node the vector index row points to.
  final NodeId nodeId;

  /// The node's type — kept on the candidate so the fusion stage can
  /// apply per-type weights without a second registry lookup.
  final String typeName;

  /// The embedding-model identity whose per-model index produced this
  /// candidate. Recorded so a diagnostic dump of a multi-model recall
  /// can attribute each row back to its origin.
  final String modelId;

  /// L2 distance from the query vector under the index's metric.
  /// `>= 0.0`. Lower = more similar.
  final double distance;

  const VectorRecallCandidate({
    required this.nodeId,
    required this.typeName,
    required this.modelId,
    required this.distance,
  });

  @override
  String toString() =>
      'VectorRecallCandidate(type: $typeName, id: $nodeId, '
      'model: $modelId, d: $distance)';
}

/// Vector mode executor.
///
/// One instance per open memory store. Stateless across calls; safe
/// to share between callers on the same `memory.db` + `vectors.db`
/// pair.
final class VectorRecall {
  /// Live SQLite handle on `memory.db`. Used for the type-name
  /// enrichment SELECT against `nodes`.
  final Database _memoryDb;

  /// Live registry — used to enumerate which types have an embedding
  /// policy at all.
  final NodeTypeRegistry _registry;

  /// The `vectors.db` side of the storage stack. Owner of the
  /// per-model physical-table queries.
  final VectorTable _vectorTable;

  /// Constructs the executor.
  VectorRecall({
    required Database memoryDb,
    required NodeTypeRegistry registry,
    required VectorTable vectorTable,
  })  : _memoryDb = memoryDb,
        _registry = registry,
        _vectorTable = vectorTable;

  // ─── Public surface ────────────────────────────────────────────

  /// Runs the vector mode for [query] across every registered type whose
  /// `EmbeddingPolicy` matches the query's dimensionality.
  ///
  /// Contract:
  ///
  ///   * Returns at most [perModeK] candidates, ordered by ascending
  ///     `distance` (vec0's lower-is-better, mirrored by the test
  ///     backend).
  ///   * [typeNames] (when non-null and non-empty) restricts the scan
  ///     to those type names. Names that are not registered or that
  ///     carry no embedding policy are silently elided. An empty set
  ///     restricts to *no* types (returns empty); pass `null` for
  ///     "all types with embeddings".
  ///   * Types whose `EmbeddingPolicy.dimensions` do not match
  ///     `query.dimension` are skipped. The vector index they target
  ///     was provisioned with a different width and cannot answer
  ///     this query.
  ///   * Types whose `EmbeddingPolicy.modelIdentity` has no installed
  ///     index in `vectors.db` are silently skipped. This is the
  ///     conservative branch — boot-side wiring is the install path
  ///     (`VectorTable.installIndex` from
  ///     `SqliteTomBrainMemory.open`), and a missing index means
  ///     either the operator has not installed yet (a setup mistake
  ///     already reported elsewhere) or the boot path failed open
  ///     (BM25-only mode, see `loadVecExtensionWithFailOpen`).
  ///   * [perModeK] caps the *post-merge* count, not the per-model
  ///     count: each model group is queried with `k = perModeK`,
  ///     then the merged result is truncated to `perModeK`. This
  ///     bounds per-mode I/O at `numModels * perModeK` rows in the
  ///     worst case.
  ///   * [perModeK] <= 0 returns empty without issuing SQL.
  ///   * An empty registered-type set, an empty post-dim-filter set,
  ///     or zero hits across every model group all return an empty
  ///     list (never null).
  ///
  /// Does **not** raise on dim or model mismatch — both are recall-
  /// time normal: a query whose dim does not match any installed
  /// index just returns empty. Raising would force every BM25-only
  /// caller to wrap vector recall in a try/catch.
  List<VectorRecallCandidate> recall({
    required Vec query,
    Set<String>? typeNames,
    int perModeK = 64,
  }) {
    if (perModeK <= 0) return const <VectorRecallCandidate>[];

    final byModel = _groupCandidateTypesByModel(typeNames, query.dimension);
    if (byModel.isEmpty) return const <VectorRecallCandidate>[];

    final merged = <VectorRecallCandidate>[];
    for (final entry in byModel.entries) {
      _appendPerModelMatches(
        modelId: entry.key,
        candidateTypeNames: entry.value,
        query: query,
        perModeK: perModeK,
        into: merged,
      );
    }

    // vec0 + plain backend: lower distance = better. Sort ascending,
    // tie-break by (modelId, nodeId) lexicographic for determinism.
    merged.sort((a, b) {
      final byDistance = a.distance.compareTo(b.distance);
      if (byDistance != 0) return byDistance;
      final byModelId = a.modelId.compareTo(b.modelId);
      if (byModelId != 0) return byModelId;
      return a.nodeId.toString().compareTo(b.nodeId.toString());
    });
    if (merged.length > perModeK) {
      return List<VectorRecallCandidate>.unmodifiable(
        merged.sublist(0, perModeK),
      );
    }
    return List<VectorRecallCandidate>.unmodifiable(merged);
  }

  // ─── Internal: candidate-type enumeration ──────────────────────

  /// Groups candidate types by their `EmbeddingPolicy.modelIdentity`,
  /// restricted to the registry's embedding-bearing types, optionally
  /// filtered by [typeNames], and finally restricted to types whose
  /// `EmbeddingPolicy.dimensions` matches [queryDimension].
  ///
  /// Returns a map of `modelId -> Set<typeName>` so the caller can
  /// (a) make one `queryNearest` call per model, and (b) post-filter
  /// the results by the per-model candidate-type set.
  Map<String, Set<String>> _groupCandidateTypesByModel(
    Set<String>? typeNames,
    int queryDimension,
  ) {
    if (typeNames != null && typeNames.isEmpty) {
      return const <String, Set<String>>{};
    }
    final all = _registry.listAll();
    final scoped = typeNames == null
        ? all
        : all.where((decl) => typeNames.contains(decl.typeName));

    final byModel = <String, Set<String>>{};
    for (final decl in scoped) {
      final policy = decl.embeddingPolicy;
      if (policy.isNone) continue;
      if (policy.dimensions != queryDimension) continue;
      byModel
          .putIfAbsent(policy.modelIdentity, () => <String>{})
          .add(decl.typeName);
    }
    return byModel;
  }

  // ─── Internal: per-model query + enrichment ────────────────────

  /// Issues one [VectorTable.queryNearest] call against the installed
  /// index for [modelId], looks up `type_name` for each returned node
  /// in a single SELECT against `nodes`, drops rows whose
  /// `type_name` is not in [candidateTypeNames], and appends the
  /// surviving rows to [into] as `VectorRecallCandidate`s.
  void _appendPerModelMatches({
    required String modelId,
    required Set<String> candidateTypeNames,
    required Vec query,
    required int perModeK,
    required List<VectorRecallCandidate> into,
  }) {
    if (!_vectorTable.hasIndex(modelId)) {
      // Conservative: skip silently. See header on "missing index"
      // — the operator-facing signal is on the boot path, not on
      // every recall.
      return;
    }

    final List<VectorMatch> matches;
    try {
      matches = _vectorTable.queryNearest(
        query: query,
        k: perModeK,
        modelId: modelId,
      );
    } on VectorTableException {
      // Pre-filter already removed dim mismatches; reaching here
      // means a race with index drop / model rename. Skip silently
      // — the recall stays conservative.
      return;
    }

    if (matches.isEmpty) return;

    final typeNameByNodeId = _readTypeNamesFor(
      matches.map((m) => m.nodeId).toList(growable: false),
    );

    for (final match in matches) {
      final typeName = typeNameByNodeId[match.nodeId];
      if (typeName == null) {
        // The vector row outlived its `nodes` row. This is a
        // referential-integrity drift that the storage stack does
        // not currently police (no FK from vectors.db to memory.db
        // — see `vector_table.dart` header on the cross-DB
        // decoupling). The conservative branch is to drop the row
        // from this recall and continue; a future cleanup pass will
        // reconcile.
        continue;
      }
      if (!candidateTypeNames.contains(typeName)) {
        // The model index legitimately holds vectors for more types
        // than the caller asked for (multiple types sharing one
        // embedding model). Drop the non-requested types.
        continue;
      }
      into.add(
        VectorRecallCandidate(
          nodeId: NodeId.fromString(match.nodeId),
          typeName: typeName,
          modelId: modelId,
          distance: match.distance,
        ),
      );
    }
  }

  /// Reads `(node_id, type_name)` for every id in [nodeIds] in one
  /// SELECT. Returns a map keyed by the bare `NodeId.toString()` form
  /// the vector backend emits. Ids that no longer exist in `nodes`
  /// are absent from the result.
  ///
  /// Bounded by [VectorTable.queryNearest]'s k — at most `perModeK`
  /// per call, so the parameter list never approaches SQLite's
  /// default 999-host-parameter ceiling for the perModeK values we
  /// care about (typical `perModeK <= 256`).
  Map<String, String> _readTypeNamesFor(List<String> nodeIds) {
    if (nodeIds.isEmpty) return const <String, String>{};
    final placeholders = List<String>.filled(nodeIds.length, '?').join(',');
    final rows = _memoryDb.select(
      'SELECT id, type_name FROM nodes WHERE id IN ($placeholders)',
      nodeIds,
    );
    final result = <String, String>{};
    for (final row in rows) {
      result[row['id'] as String] = row['type_name'] as String;
    }
    return result;
  }
}
