// RecallQuery — input to `TomBrainMemory.recall` (memory_specification.md
// § 6).
//
// A query carries the inputs for one or more of the four retrieval
// modes (BM25, vector, graph-walk, symbolic), plus the fusion /
// diversity policies and a wall-clock + per-mode budget. The
// optional `reRank` hook is the only LLM touchpoint — memory never
// instantiates an LLM itself.
//
// `SymbolicFilter`, `SymbolicOp`, and `AttrClause` are imported from
// `tom_brain_shared` (Plan step A.88 — reuse extraction). They live in
// shared because every Tom Brain component that constructs a
// `RecallQuery` (substrate via web tools, procedure engine via the
// bridged `recall` primitive, dispatcher as a primitive-act
// pass-through, access via REST/SSE request mapping) needs to build
// these without taking a runtime dependency on `tom_brain_memory`. The
// SQL compiler that turns a `SymbolicFilter` into a parameterised
// `WHERE` clause stays here in memory (`retrieval/symbolic_recall.dart`).

import '../../embedding/embedding.dart' show Vec;
import '../../ids/ids.dart' show NodeId;
import '../../symbolic/symbolic.dart' show SymbolicFilter;

import '../edges/edge_type.dart';
import '../nodes/node.dart';

// Re-export the three shared symbolic-filter types so that consumers
// importing this file directly (the executor, tests, the retrieval
// barrel) continue to see them on the same import path as before the
// A.88 relocation. `SymbolicFilter` is exported via the show-list of
// the import above (it is also used directly here in `RecallQuery`);
// `AttrClause` and `SymbolicOp` ride the standalone export below.
export '../../symbolic/symbolic.dart'
    show AttrClause, SymbolicFilter, SymbolicOp;

/// One of the four retrieval modes (§ 6.1).
enum RecallMode {
  /// FTS5 BM25 over indexed text fields.
  bm25,

  /// sqlite-vec ANN over indexed embedding fields.
  vector,

  /// Bounded-depth walk from a seed set across the edge graph.
  graphWalk,

  /// SQL `WHERE` over indexed columns (type, time, scope, attrs).
  symbolic,
}

/// How the fused candidate list is ordered before the result is
/// returned (memory_optimization_plan § 6.2.1 / § 7).
///
/// [relevance] is the default and preserves the historical behaviour:
/// the order produced by fusion (RRF/weighted) and the diversity step
/// (MMR) is returned unchanged. The other four re-score or re-sort that
/// list using the usage columns (`last_access_ms` / `access_count`)
/// populated by `recordAccess`:
///
///   * [recencyBoosted] — multiply each candidate's fused score by a
///     recency factor (newer last-access wins), then re-order.
///   * [frequencyBoosted] — multiply by a frequency factor (higher
///     `access_count` wins), then re-order.
///   * [oldest] — discard the fused scores and sort ascending by
///     `last_access_ms` (least-recently-accessed first). The retrieval
///     primitive a forgetting / reconsolidation pass uses to find cold
///     candidates by time.
///   * [coldest] — discard the fused scores and sort ascending by
///     `access_count` (least-frequently-accessed first).
enum RecallRanking {
  /// Fusion + diversity order, unchanged. The default.
  relevance,

  /// Fused score weighted by a recency factor over `last_access_ms`.
  recencyBoosted,

  /// Fused score weighted by a frequency factor over `access_count`.
  frequencyBoosted,

  /// Pure ascending sort on `last_access_ms` (least recent first).
  oldest,

  /// Pure ascending sort on `access_count` (least frequent first).
  coldest,
}

// `SymbolicOp`, `AttrClause`, and `SymbolicFilter` are re-exported below
// so that callers importing `package:tom_brain_memory/...recall_query.dart`
// continue to see the same surface as before the A.88 move. The runtime
// identity is the shared type — no re-declaration here.

/// Per-recall wall-clock + per-mode caps. Memory enforces these
/// strictly: a recall that exceeds [wallClockMs] returns what it has
/// so far plus a degraded flag on the [RecallReport].
final class RecallBudget {
  /// Total wall-clock allowance in milliseconds.
  final int wallClockMs;

  /// Per-mode candidate cap, before fusion. Tunes how many nodes
  /// each mode returns; the global `k` on `RecallQuery` caps the
  /// post-fusion result.
  final int perModeK;

  const RecallBudget({
    this.wallClockMs = 120,
    this.perModeK = 64,
  });
}

/// Strategy for merging per-mode result lists into a single ranking.
enum FusionStrategy {
  /// Reciprocal Rank Fusion (§ 6.2). The default.
  rrf,

  /// Caller-supplied weighted-mean over per-mode normalised scores.
  weighted,
}

/// Fusion policy attached to a recall (default `rrf` with k=60).
final class FusionPolicy {
  final FusionStrategy strategy;

  /// RRF smoothing constant. Only meaningful for [FusionStrategy.rrf].
  final int rrfK;

  /// Weight per mode for [FusionStrategy.weighted]. Modes not
  /// present default to weight 1.0.
  final Map<RecallMode, double> weights;

  const FusionPolicy({
    this.strategy = FusionStrategy.rrf,
    this.rrfK = 60,
    this.weights = const <RecallMode, double>{},
  });

  /// The system-wide default — RRF with k=60.
  static const FusionPolicy defaultRrf = FusionPolicy();
}

/// Strategy for the post-fusion diversity step.
enum DiversityStrategy {
  /// Maximal Marginal Relevance (§ 6.2). The default.
  mmr,

  /// No diversity step — pass the fused ranking through unchanged.
  off,
}

/// Diversity policy attached to a recall.
final class DiversityPolicy {
  final DiversityStrategy strategy;

  /// MMR's lambda. 1.0 favours relevance; 0.0 favours diversity.
  final double lambda;

  const DiversityPolicy({
    this.strategy = DiversityStrategy.mmr,
    this.lambda = 0.7,
  });

  /// The system-wide default — MMR at lambda 0.7.
  static const DiversityPolicy defaultMmr = DiversityPolicy();
}

/// Per-call policy for the `graphWalk` retrieval mode (spec § 6.1).
///
/// The walk is BFS from `RecallQuery.seeds` across the edge graph
/// stored in `memory.db.edges`. Each visited node is scored as
/// `parentScore * edgeTypeWeight * edge.weight * depthDecay` and the
/// best score across all reaching paths wins. Seeds are excluded from
/// the result candidates — graph walk returns *related* nodes, not the
/// seed set itself.
///
/// Defaults are tuned for the spec's "two-hop neighbour expansion"
/// reading: depth 2, `0.5` decay per hop, every edge type weighted 1.0,
/// both directions traversed.
final class GraphWalkPolicy {
  /// Maximum hop count from any seed. Depth 0 = seeds (always excluded
  /// from results); depth 1 = direct neighbours; depth 2 = neighbours
  /// of neighbours. A `maxDepth <= 0` causes the executor to return
  /// no candidates without touching the database.
  final int maxDepth;
  ///
  /// Multiplicative decay applied per hop. `1.0` = no decay (a 5-hop
  /// path scores the same as a 1-hop path with the same edge weights);
  /// `0.0` would zero-out anything past depth 0. The default `0.5`
  /// halves the contribution per additional hop, so a 2-hop neighbour
  /// must have ~2x the edge-weight product to outrank a 1-hop one.
  final double depthDecay;

  /// Per-edge-type multiplier applied at every traversal step.
  ///
  /// Edge types absent from this map default to `1.0`. A weight of
  /// `0.0` removes the edge type from the walk entirely (the executor
  /// skips edges of that type — they neither propagate score nor
  /// expand the frontier). Negative weights are rejected at executor
  /// construction time.
  final Map<EdgeType, double> edgeTypeWeights;

  /// Which direction to traverse from each frontier node.
  ///
  /// `both` (default) walks the undirected graph — the conventional
  /// reading of "graph walk for relatedness". `outgoing` follows only
  /// `from → to` (consequence-style); `incoming` follows only
  /// `to → from` (provenance-style).
  final EdgeDirection direction;

  const GraphWalkPolicy({
    this.maxDepth = 2,
    this.depthDecay = 0.5,
    this.edgeTypeWeights = const <EdgeType, double>{},
    this.direction = EdgeDirection.both,
  });

  /// System-wide default — depth 2, decay 0.5, every edge weighted
  /// 1.0, undirected walk.
  static const GraphWalkPolicy defaultPolicy = GraphWalkPolicy();
}

/// Signature of the optional caller-supplied re-rank hook.
///
/// The hook receives the post-diversity candidate list and returns
/// the desired final order as a list of `NodeId`s. Memory never
/// instantiates an LLM — procedures that want LLM re-ranking
/// instantiate substrate themselves and supply this hook.
typedef ReRankHook = Future<List<NodeId>> Function(List<Node> candidates);

/// Input record for `TomBrainMemory.recall`.
final class RecallQuery {
  /// Query text used by BM25 and (after caller-supplied or
  /// memory-side embedding) by vector mode.
  final String? text;

  /// Pre-computed query embedding. When non-null, memory skips the
  /// embed callout entirely for vector mode.
  final Vec? embedding;

  /// Seed set for graph-walk.
  final Set<NodeId>? seeds;

  /// Symbolic filter applied across every mode's candidate set.
  final SymbolicFilter? filter;

  /// Which modes to run.
  final Set<RecallMode> modes;

  /// Post-fusion cap on the total result list.
  final int k;

  /// Wall-clock + per-mode caps.
  final RecallBudget budget;

  /// Fusion policy.
  final FusionPolicy fusion;

  /// Diversity policy.
  final DiversityPolicy diversity;

  /// Per-call graph-walk policy (depth, decay, per-edge-type weights,
  /// direction). Only meaningful when [RecallMode.graphWalk] is in
  /// [modes] and [seeds] is non-empty.
  final GraphWalkPolicy graphWalk;

  /// Optional LLM re-rank hook.
  final ReRankHook? reRank;

  /// How the fused list is ordered before it is returned
  /// (memory_optimization_plan § 6.2.1 / § 7). Defaults to
  /// [RecallRanking.relevance] — the historical fusion + diversity
  /// order.
  final RecallRanking ranking;

  /// Whether the nodes this recall returns should be marked as accessed
  /// (their usage columns bumped via `recordAccess`). Defaults to
  /// `false`: most recalls are read-only inspections that must not
  /// perturb the recency / frequency signal the [ranking] strategies
  /// read. A recall that genuinely represents "the system used these
  /// memories" sets this to `true`.
  final bool countsAsAccess;

  const RecallQuery({
    required this.modes,
    this.text,
    this.embedding,
    this.seeds,
    this.filter,
    this.k = 20,
    this.budget = const RecallBudget(),
    this.fusion = FusionPolicy.defaultRrf,
    this.diversity = DiversityPolicy.defaultMmr,
    this.graphWalk = GraphWalkPolicy.defaultPolicy,
    this.reRank,
    this.ranking = RecallRanking.relevance,
    this.countsAsAccess = false,
  });
}
