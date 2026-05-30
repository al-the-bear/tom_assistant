// RecallQuery — input to `TomBrainMemory.recall` (memory_specification.md
// § 6).
//
// A query carries the inputs for one or more of the four retrieval
// modes (BM25, vector, graph-walk, symbolic), plus the fusion /
// diversity policies and a wall-clock + per-mode budget. The
// optional `reRank` hook is the only LLM touchpoint — memory never
// instantiates an LLM itself.

import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, Vec;

import '../nodes/node.dart';

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

/// Comparator operators usable in a `SymbolicFilter` attribute clause.
enum SymbolicOp {
  eq,
  ne,
  lt,
  lte,
  gt,
  gte,
  inList,
  notInList,
}

/// One attribute clause in a `SymbolicFilter`.
final class AttrClause {
  final String field;
  final SymbolicOp op;
  final Object? value;

  const AttrClause(this.field, this.op, this.value);
}

/// Compiled-down `WHERE`-shape used by the symbolic mode.
///
/// At A.24 only the shape exists; the compiler that turns this into
/// SQL lands at A.56.
final class SymbolicFilter {
  /// Node type names to include. Empty = no type filter.
  final Set<String> typeNames;

  /// Lower bound (inclusive) on `createdAt`. `null` = open.
  final DateTime? createdAfter;

  /// Upper bound (exclusive) on `createdAt`. `null` = open.
  final DateTime? createdBefore;

  /// Producer-scope filter (a `Scope.producer` value).
  final String? producer;

  /// Attribute clauses; ANDed together.
  final List<AttrClause> attributes;

  const SymbolicFilter({
    this.typeNames = const <String>{},
    this.createdAfter,
    this.createdBefore,
    this.producer,
    this.attributes = const <AttrClause>[],
  });
}

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

  /// Optional LLM re-rank hook.
  final ReRankHook? reRank;

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
    this.reRank,
  });
}
