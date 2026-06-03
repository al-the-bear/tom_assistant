// GraphWalkRecall — graph-walk-mode executor for `RecallQuery.seeds`
// (Plan step A.61, spec § 6.1 graph-walk mode).
//
// What this file owns:
//
//   - Bounded-depth BFS from a seed set over the `memory.db.edges`
//     table, with per-edge-type weights, depth decay, optional
//     direction filter (outgoing / incoming / both), and an optional
//     `typeNames` post-filter.
//   - Per-visited-node score = `parentScore * edgeTypeWeight *
//     edge.weight * depthDecay`. Score at first visit wins; later
//     paths do NOT overwrite the first-discovery score, which gives
//     cycle safety as a side-effect (a node already visited is
//     ignored — every cycle is therefore broken at its first
//     re-entry).
//   - Seeds are excluded from the result candidates. Graph walk
//     returns *related* nodes; the caller already has the seeds.
//   - Per-row materialisation of `type_name` for the surviving
//     candidates via one bulk SELECT against the `nodes` table — the
//     fusion stage at A.59 needs the type per candidate to slot into
//     `RrfFusedCandidate`, but the executor's per-mode dispatch flow
//     hands fusion only the ranked `NodeId` list, so the `type_name`
//     is carried on the candidate purely for the symmetry with the
//     other three modes (and for a future per-type re-weighting
//     stage).
//
// What this file does NOT own:
//
//   - Fusion (A.57 RRF) or diversity (A.58 MMR).
//   - The `RecallReport` cost row — the recall executor at A.59
//     composes this output with the report.
//   - LLM re-rank — caller-side hook on `RecallQuery`.
//   - Edge-write or edge-read concerns. Graph walk reads `edges`
//     directly with its own SQL (the same pattern `SymbolicRecall`
//     uses against `nodes`); `EdgeReader.edgesOf` is an async,
//     per-node API and graph walk wants batched-by-frontier reads.
//     Each scan goes through ONE round-trip per depth, not one per
//     frontier node.
//
// Wire contract:
//
//   `GraphWalkRecallCandidate` carries `(nodeId, typeName, score)`.
//   The score is the BFS-derived value above; the fusion stage at
//   A.57 only uses the rank (descending by score, tie-broken by
//   `NodeId.value` ascending for determinism). The `typeName` is
//   carried purely for downstream symmetry with the other mode
//   executors — fusion does not consume it today.
//
// Cycle safety:
//
//   The visited-set guard rejects any neighbour already discovered
//   at a previous depth. This includes seeds, which are pre-inserted
//   into the visited set with score `1.0`. A cycle A → B → A
//   therefore breaks at the second-hop attempt to re-enter A: A is
//   already visited, the edge is skipped, the walk terminates
//   naturally without revisiting. The same guard implicitly handles
//   self-loops (`A → A` is skipped because A is in the visited set
//   when we try to step into it).
//
// Depth bound:
//
//   The outer loop runs `for (depth = 1; depth <= maxDepth; depth++)`.
//   `maxDepth <= 0` returns `[]` without touching the database. A
//   `maxDepth` of 1 walks only direct neighbours; the spec's default
//   is 2 (see `GraphWalkPolicy.defaultPolicy`).
//
// Per-edge-type weights:
//
//   Edge types absent from `policy.edgeTypeWeights` default to
//   `kDefaultEdgeTypeWeight` (`1.0`). A weight of `0.0` removes the
//   edge type from the walk entirely — those edges are never
//   selected by the frontier-expansion SQL, so they neither
//   propagate score nor advance the frontier. Negative weights are
//   rejected up-front with `ArgumentError`; a negative weight would
//   make a "more matching" path score lower than "less matching",
//   which inverts the relevance semantics every other mode honours.
//
// Determinism:
//
//   The walk is deterministic against the same DB state:
//
//     * Frontier expansion uses `SELECT ... WHERE id IN (...)`, which
//       SQLite returns in row-id order (insertion order for `edges`);
//       per-depth processing folds them into the score map, which is
//       order-insensitive (`max`-based update).
//     * The final ranking sorts by score descending, NodeId
//       ascending. Two candidates with the same score therefore tie-
//       break the same way every call.
//
// Empty-input semantics:
//
//   * Empty seed set → `[]` without touching the database.
//   * `maxDepth <= 0` → `[]` without touching the database.
//   * `perModeK <= 0` → `[]` without touching the database.
//   * All edge-type weights zero → `[]` without touching the
//     database (no permitted edge labels means no walk).
//   * Seeds with no outgoing edges → `[]` after one empty frontier
//     expansion. The cost is a single SELECT that returns no rows.

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show sqlPlaceholders;
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../edges/edge_type.dart';
import '../nodes/node_reader.dart' show readNodeTypeNames;
import 'recall_query.dart';

/// Default per-edge-type weight when [GraphWalkPolicy.edgeTypeWeights]
/// has no entry for a given edge label.
///
/// `1.0` means "edge type contributes its `edge.weight` unchanged".
const double kDefaultEdgeTypeWeight = 1.0;

/// A single graph-walk-mode candidate.
///
/// The executor returns these ordered by descending [score]
/// (highest-scoring first), tie-broken by [NodeId] ascending for
/// determinism.
final class GraphWalkRecallCandidate {
  /// The node the walk reached.
  final NodeId nodeId;

  /// The node's type — kept on the candidate so the fusion stage can
  /// apply per-type weights without a second registry lookup. Mirrors
  /// the other three mode candidates' shape.
  final String typeName;

  /// First-visit walk score. Higher = closer / more strongly
  /// connected. The exact magnitude is policy-dependent and not
  /// comparable across calls with different policies; the rank
  /// across this single result list is what fusion consumes.
  final double score;

  const GraphWalkRecallCandidate({
    required this.nodeId,
    required this.typeName,
    required this.score,
  });

  @override
  String toString() => 'GraphWalkRecallCandidate('
      'type: $typeName, id: $nodeId, score: $score)';
}

/// Graph-walk mode executor.
///
/// One instance per open memory store. Stateless across calls; safe to
/// share between callers on the same SQLite connection.
final class GraphWalkRecall {
  /// Live SQLite handle on `memory.db`. Owned by the store opener.
  final Database _db;

  /// Constructs the executor.
  GraphWalkRecall({required Database memoryDb}) : _db = memoryDb;

  // ─── Public surface ────────────────────────────────────────────

  /// Runs the graph-walk mode from [seeds] under [policy].
  ///
  /// Contract:
  ///
  ///   * Returns at most [perModeK] candidates, ordered by descending
  ///     score, tie-broken by [NodeId] ascending.
  ///   * Seeds are excluded from the returned list.
  ///   * Empty [seeds], `policy.maxDepth <= 0`, or [perModeK] <= 0
  ///     returns empty without issuing SQL.
  ///   * If every edge type has weight `0.0` (i.e. the caller
  ///     explicitly removed every permitted label), returns empty
  ///     without issuing SQL.
  ///   * [typeNames], when non-null, filters the result to
  ///     candidates whose `nodes.type_name` is in the set. Applied
  ///     AFTER the walk, against the materialised `type_name`
  ///     column — so the walk still costs the same; the filter
  ///     just trims the result.
  ///
  /// Throws [ArgumentError] when:
  ///
  ///   * Any entry in `policy.edgeTypeWeights` is negative.
  ///   * `policy.depthDecay` is negative.
  List<GraphWalkRecallCandidate> recall({
    required Set<NodeId> seeds,
    GraphWalkPolicy policy = GraphWalkPolicy.defaultPolicy,
    Set<String>? typeNames,
    int perModeK = 64,
  }) {
    if (perModeK <= 0) return const <GraphWalkRecallCandidate>[];
    if (seeds.isEmpty) return const <GraphWalkRecallCandidate>[];
    if (policy.maxDepth <= 0) return const <GraphWalkRecallCandidate>[];

    if (policy.depthDecay < 0.0) {
      throw ArgumentError.value(
        policy.depthDecay,
        'GraphWalkPolicy.depthDecay',
        'depthDecay must be >= 0 — a negative decay would invert the '
            'relevance semantics (deeper = better), which graph-walk '
            'mode does not support.',
      );
    }

    // Compute the effective per-edge-type weight table. Edges with
    // weight 0 are excluded entirely (never queried, never expand
    // the frontier). Negative weights are rejected.
    final permittedTypeWeights = <EdgeType, double>{};
    for (final t in EdgeType.values) {
      final w = policy.edgeTypeWeights[t] ?? kDefaultEdgeTypeWeight;
      if (w < 0.0) {
        throw ArgumentError.value(
          w,
          'GraphWalkPolicy.edgeTypeWeights[${t.wireName}]',
          'edge-type weight must be >= 0 — a negative weight would '
              'invert the relevance semantics (more-matching path '
              'scores lower than less-matching), which graph-walk '
              'mode does not support.',
        );
      }
      if (w > 0.0) permittedTypeWeights[t] = w;
    }
    if (permittedTypeWeights.isEmpty) {
      return const <GraphWalkRecallCandidate>[];
    }
    final permittedTypes = permittedTypeWeights.keys.toSet();

    // visited: every NodeId.value we have seen at *any* depth,
    // including seeds. The visited-set guard is what makes the walk
    // cycle-safe (see file header).
    final visited = <String>{for (final s in seeds) s.value};

    // bestScore: NodeId.value → first-visit walk score. Seeds are
    // pre-inserted with 1.0 so the depth-1 expansion sees them as
    // legitimate parents.
    final bestScore = <String, double>{};
    for (final s in seeds) {
      bestScore[s.value] = 1.0;
    }

    // The walk state bundles the collaborators every leg-evaluation
    // touches (see [_WalkState]). `currentFrontier` and `depthScores`
    // are reassigned per depth; `visited` and `bestScore` accumulate
    // across the whole walk.
    final state = _WalkState(
      policy: policy,
      permittedTypeWeights: permittedTypeWeights,
      visited: visited,
      bestScore: bestScore,
      currentFrontier: <String>{for (final s in seeds) s.value},
      depthScores: <String, double>{},
    );

    for (var depth = 1; depth <= policy.maxDepth; depth++) {
      if (state.currentFrontier.isEmpty) break;

      final edges = _selectFrontierEdges(
        frontier: state.currentFrontier,
        types: permittedTypes,
        direction: policy.direction,
      );
      if (edges.isEmpty) break;

      // Per-depth scratch: neighbour.value → best candidate score
      // discovered at THIS depth. We commit the whole depth at once
      // so an order-sensitive update can't leak between rows.
      state.depthScores = <String, double>{};

      for (final row in edges) {
        // Each row may contribute as outgoing from one frontier node,
        // or incoming to one frontier node, or (in direction=both)
        // both legs at once. We evaluate both legs that match the
        // direction policy and take the higher candidate score.
        state.considerLeg(
          parentValue: row.fromValue,
          neighbourValue: row.toValue,
          rowType: row.type,
          rowWeight: row.weight,
          isOutgoingLeg: true,
        );
        state.considerLeg(
          parentValue: row.toValue,
          neighbourValue: row.fromValue,
          rowType: row.type,
          rowWeight: row.weight,
          isOutgoingLeg: false,
        );
      }

      // Commit this depth's discoveries.
      for (final entry in state.depthScores.entries) {
        bestScore[entry.key] = entry.value;
        visited.add(entry.key);
      }
      state.currentFrontier = state.depthScores.keys.toSet();
    }

    // Collect non-seed results.
    final seedValues = <String>{for (final s in seeds) s.value};
    final discovered = <String, double>{
      for (final entry in bestScore.entries)
        if (!seedValues.contains(entry.key)) entry.key: entry.value,
    };

    if (discovered.isEmpty) return const <GraphWalkRecallCandidate>[];

    // One bulk SELECT to materialise type_name for the discovered set.
    // Any id whose row is missing (dangling edge endpoint — see
    // edge_reader.dart's "dangling-ref tolerance" note) is dropped
    // silently from the result. We do not surface it as an error
    // here; the recall surface is a relevance ranking, not a graph
    // integrity check.
    final typeByValue = readNodeTypeNames(_db, discovered.keys);

    final candidates = <GraphWalkRecallCandidate>[];
    for (final entry in discovered.entries) {
      final typeName = typeByValue[entry.key];
      if (typeName == null) continue;
      if (typeNames != null && !typeNames.contains(typeName)) continue;
      candidates.add(GraphWalkRecallCandidate(
        nodeId: NodeId.fromString(entry.key),
        typeName: typeName,
        score: entry.value,
      ));
    }

    candidates.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      return a.nodeId.value.compareTo(b.nodeId.value);
    });

    if (candidates.length > perModeK) {
      return List<GraphWalkRecallCandidate>.unmodifiable(
        candidates.sublist(0, perModeK),
      );
    }
    return List<GraphWalkRecallCandidate>.unmodifiable(candidates);
  }

  // ─── Internal: SQL ─────────────────────────────────────────────

  /// Returns every edge whose direction-relevant endpoint is in
  /// [frontier] and whose `type` is in [types]. One SQLite round-trip
  /// per depth.
  List<_FrontierEdgeRow> _selectFrontierEdges({
    required Set<String> frontier,
    required Set<EdgeType> types,
    required EdgeDirection direction,
  }) {
    if (frontier.isEmpty || types.isEmpty) return const <_FrontierEdgeRow>[];

    final idPh = sqlPlaceholders(frontier.length);
    final typePh = sqlPlaceholders(types.length);

    final String whereDir;
    final params = <Object?>[];
    switch (direction) {
      case EdgeDirection.outgoing:
        whereDir = 'from_node IN ($idPh)';
        params.addAll(frontier);
        break;
      case EdgeDirection.incoming:
        whereDir = 'to_node IN ($idPh)';
        params.addAll(frontier);
        break;
      case EdgeDirection.both:
        whereDir = '(from_node IN ($idPh) OR to_node IN ($idPh))';
        params
          ..addAll(frontier)
          ..addAll(frontier);
        break;
    }
    params.addAll(types.map((t) => t.wireName));

    final rows = _db.select(
      'SELECT from_node, to_node, type, weight FROM edges '
      'WHERE $whereDir AND type IN ($typePh)',
      params,
    );

    return rows
        .map((r) => _FrontierEdgeRow(
              fromValue: r['from_node'] as String,
              toValue: r['to_node'] as String,
              type: EdgeType.fromWireName(r['type'] as String),
              weight: (r['weight'] as num).toDouble(),
            ))
        .toList(growable: false);
  }

}

/// Mutable bundle of the collaborators a single BFS walk threads
/// through every leg evaluation.
///
/// Extracting these into one object keeps [considerLeg] to the five
/// arguments that actually vary per edge-leg, instead of re-passing
/// the six walk-scoped collaborators on every call. `visited` and
/// `bestScore` accumulate across the whole walk; `currentFrontier`
/// and `depthScores` are reassigned by the caller at each depth.
final class _WalkState {
  final GraphWalkPolicy policy;
  final Map<EdgeType, double> permittedTypeWeights;

  /// Every `NodeId.value` seen at any depth (cycle-safety guard).
  final Set<String> visited;

  /// `NodeId.value` → first-visit walk score.
  final Map<String, double> bestScore;

  /// The frontier being expanded this depth. Reassigned per depth.
  Set<String> currentFrontier;

  /// Per-depth scratch: neighbour.value → best candidate score
  /// discovered at THIS depth. Reassigned (cleared) per depth.
  Map<String, double> depthScores;

  _WalkState({
    required this.policy,
    required this.permittedTypeWeights,
    required this.visited,
    required this.bestScore,
    required this.currentFrontier,
    required this.depthScores,
  });

  /// Considers one direction-leg of an edge as a possible expansion.
  ///
  /// `parentValue` is the candidate parent (must be in frontier);
  /// `neighbourValue` is the candidate new node (must not be in
  /// visited or it is a cycle / re-discovery and is silently
  /// dropped).
  ///
  /// `isOutgoingLeg = true` evaluates `parent.from → neighbour.to`;
  /// `false` evaluates `parent.to → neighbour.from`. The direction
  /// policy decides which legs are allowed:
  ///
  ///   * `outgoing` — only the outgoing leg of each row counts.
  ///   * `incoming` — only the incoming leg of each row counts.
  ///   * `both` — both legs counted; the higher candidate score
  ///     wins via the `depthScores` map's max-update semantics.
  void considerLeg({
    required String parentValue,
    required String neighbourValue,
    required EdgeType rowType,
    required double rowWeight,
    required bool isOutgoingLeg,
  }) {
    // Direction gate.
    switch (policy.direction) {
      case EdgeDirection.outgoing:
        if (!isOutgoingLeg) return;
        break;
      case EdgeDirection.incoming:
        if (isOutgoingLeg) return;
        break;
      case EdgeDirection.both:
        break;
    }

    if (!currentFrontier.contains(parentValue)) return;
    if (visited.contains(neighbourValue)) return;

    final typeWeight = permittedTypeWeights[rowType]!;
    final parentScore = bestScore[parentValue]!;
    final candidate =
        parentScore * typeWeight * rowWeight * policy.depthDecay;

    final existing = depthScores[neighbourValue];
    if (existing == null || candidate > existing) {
      depthScores[neighbourValue] = candidate;
    }
  }
}

/// One row from the per-depth frontier-expansion SELECT.
final class _FrontierEdgeRow {
  final String fromValue;
  final String toValue;
  final EdgeType type;
  final double weight;

  const _FrontierEdgeRow({
    required this.fromValue,
    required this.toValue,
    required this.type,
    required this.weight,
  });
}
