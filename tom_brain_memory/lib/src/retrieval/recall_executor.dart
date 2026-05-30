// RecallExecutor — the recall pipeline orchestrator (Plan step A.59,
// spec §§ 6.1–6.4).
//
// What this file owns:
//
//   - The orchestration that turns a `RecallQuery` into a
//     `RecallResult`: dispatch to the per-mode executors, fuse with
//     RRF, diversify with MMR, optionally invoke the caller-supplied
//     LLM re-rank hook, materialise the final node list, and populate
//     the `RecallReport` cost breakdown.
//   - The wiring contract for the four modes: which executor runs for
//     which `RecallMode`, what "degraded" means per mode, and how
//     per-mode candidate counts feed the `RecallReport`.
//   - The MMR similarity callback used in the recall pipeline. At
//     A.59 the callback is BM25-score-derived: a candidate's
//     similarity to another candidate is the *minimum* of their
//     normalised BM25 scores (the spec § 6.2 fallback for nodes
//     without embeddings). The cosine-over-embeddings primary path
//     waits for `VectorTable` to expose per-row embedding readback —
//     see "Deferred" below.
//   - The wall-clock budget check. A recall that exceeds
//     `RecallQuery.budget.wallClockMs` returns what it has so far and
//     sets `RecallReport.degraded = true`.
//
// What this file does NOT own:
//
//   - The mode executors themselves. `Bm25Recall`, `VectorRecall`,
//     `SymbolicRecall`, and the future `GraphWalkRecall` (A.61) are
//     standalone units in this package; the executor just calls them.
//   - The pure-function fusion / diversity primitives. `rrfFuse` lives
//     in `rrf.dart`; `mmrDiversify` lives in `mmr.dart`. The executor
//     is the *composer* — it knows nothing about the math beyond the
//     contracts those files document.
//   - Embedding callouts. Memory does not embed on the caller's
//     behalf at A.59. A vector-mode recall whose `query.embedding` is
//     `null` is treated as degraded (vector mode skipped, no embed
//     callout counted). The substrate-side `Embedder` integration is
//     a later step; until it lands `embeddingsCallouts` is always 0.
//   - The cosine-over-embeddings similarity. Cosine itself is in
//     `tom_brain_shared` (`Vec.cosine`), but reading a *node's*
//     embedding requires `VectorTable` to expose a `getEmbeddingsFor`
//     surface; that lookup is not yet on the table. The fallback —
//     BM25-score-derived similarity — is what the executor uses today.
//   - The graph-walk mode. The executor leaves a labelled slot for it
//     so A.61 drops in without re-shaping the dispatch.
//   - Re-rank-hook LLM instantiation. The hook is a caller-supplied
//     `Future<List<NodeId>> Function(List<Node>)`. The executor calls
//     it (when present), filters its output to known ids, and
//     reorders.
//
// Pipeline (per spec § 6):
//
//   1. Start the wall-clock timer.
//   2. For each `RecallMode` in `query.modes`:
//        a. Resolve a mode executor + run it under `budget.perModeK`.
//           - bm25      → Bm25Recall.recall(...)
//           - vector    → VectorRecall.recall(...) iff embedding ≠ null
//           - symbolic  → SymbolicRecall.recall(...)
//           - graphWalk → degraded (A.61)
//        b. Record per-mode candidate count and the ranked
//           `List<NodeId>` for RRF input.
//        c. For BM25 candidates, retain the per-NodeId score so the
//           MMR similarity callback can dereference it.
//        d. Any executor throw → mode degraded silently
//           (`degraded = true`, count = 0).
//        e. Wall-clock budget exceeded check between modes →
//           short-circuit and return partial result.
//   3. Apply fusion via `rrfFuse` (the only strategy implemented at
//      A.59 — `FusionStrategy.weighted` throws `UnimplementedError`,
//      see Q-A.57.4 in `prototype_implementation_questions.md`).
//   4. Apply diversity via `mmrDiversify` over the fused list (when
//      `DiversityStrategy.mmr`; pass-through when `off`). Cap at
//      `query.k`.
//   5. Materialise `List<Node>` via `nodeReader.getMany(...)`.
//   6. If `query.reRank != null`: invoke it with the materialised
//      nodes; filter its returned id list to ids present in the
//      input; reorder the node list accordingly. Set
//      `reRankInvoked = true`.
//   7. Truncate to `query.k`.
//   8. Stop the wall-clock timer.
//   9. Build `RecallReport(...)` and return `RecallResult(nodes,
//      report)`.
//
// Determinism:
//
//   - Per-mode executors are deterministic against the same DB state.
//   - `rrfFuse` and `mmrDiversify` are deterministic (their
//     respective files document this).
//   - The only non-determinism the executor adds is the clock
//     reading. Tests inject a `MutableTestClock` to pin
//     `elapsedMs`.
//
// Deferred (carry-forward TODO; see prototype_implementation_questions.md
// Q-A.59.*):
//
//   - **Cosine-over-embeddings MMR similarity.** Requires
//     `VectorTable` to expose `getEmbeddingsFor(List<NodeId>,
//     modelId)` so the executor can batch-fetch embeddings for the
//     post-fusion candidate set. Until then, BM25-score-derived
//     similarity is the only similarity used; spec § 6.2's "for nodes
//     without embeddings, similarity falls back to BM25 score" is the
//     *only* branch implemented.
//   - **Embedder callout.** When `query.embedding == null` AND
//     `RecallMode.vector` is requested, the executor today degrades
//     the vector mode. The future hookup will call a caller-injected
//     `Embedder` once, count the callout, and feed the result to
//     `VectorRecall.recall(...)`.
//   - **GraphWalk mode (A.61).** Currently labelled-and-degraded; the
//     A.61 file drops a `GraphWalkRecall` into the dispatch alongside
//     the other three.
//   - **`FusionStrategy.weighted`.** The policy carries optional
//     weights; the executor today routes only RRF. The gate is the
//     `FusionStrategy` switch in `_fuse`. See Q-A.57.4.

import 'dart:math' as math;

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Clock, NodeId, SystemClock, Vec;

import '../nodes/node.dart';
import '../nodes/node_reader.dart';
import 'bm25_recall.dart';
import 'mmr.dart';
import 'recall_query.dart';
import 'recall_result.dart';
import 'rrf.dart';
import 'symbolic_recall.dart';
import 'vector_recall.dart';

/// Signature of the BM25 mode executor, as seen by [RecallExecutor].
///
/// Matches `Bm25Recall.recall`; the production wiring just supplies that
/// method as a tear-off. Tests inject a fake that returns canned
/// candidate lists without spinning up FTS5.
typedef Bm25ModeFn = List<Bm25RecallCandidate> Function({
  required String text,
  Set<String>? typeNames,
  int perModeK,
});

/// Signature of the vector mode executor, as seen by [RecallExecutor].
///
/// Matches `VectorRecall.recall`. Tests inject a fake; production wires
/// the method tear-off.
typedef VectorModeFn = List<VectorRecallCandidate> Function({
  required Vec query,
  Set<String>? typeNames,
  int perModeK,
});

/// Signature of the symbolic mode executor, as seen by [RecallExecutor].
///
/// Matches `SymbolicRecall.recall`. Tests inject a fake; production
/// wires the method tear-off.
typedef SymbolicModeFn = List<SymbolicRecallCandidate> Function({
  required SymbolicFilter filter,
  int perModeK,
});

/// Bulk node read for the post-fusion materialisation step.
///
/// Matches `NodeReader.getMany`. Tests inject a fake that resolves from
/// an in-memory map; production wires the method tear-off.
typedef NodeBulkReader = Future<List<Node>> Function(List<NodeId> ids);

/// Orchestrates the four-mode retrieval pipeline (memory_specification.md § 6).
///
/// One executor per open `SqliteTomBrainMemory`. Stateless across
/// calls; safe to share between callers on the same memory store.
///
/// The executor is *not* the `TomBrainMemory.recall` implementation
/// directly — the `SqliteTomBrainMemory` class (lands later in Phase
/// A) will wrap this executor + its own typed event stream + its
/// observability hooks. The split lets tests exercise the recall
/// pipeline against fake mode executors and a node reader without
/// having to spin up the full memory store.
final class RecallExecutor {
  /// BM25 mode executor function. Always required.
  final Bm25ModeFn _bm25;

  /// Vector mode executor function. May be `null` when the boot path
  /// detected no vector backend (`loadVecExtensionWithFailOpen` failed
  /// open — see A.50). When `null` and `RecallMode.vector` is
  /// requested, the mode is degraded; `RecallReport.degraded` is set
  /// true.
  final VectorModeFn? _vector;

  /// Symbolic mode executor function. Always required.
  final SymbolicModeFn _symbolic;

  /// Bulk-node reader for the post-fusion materialisation.
  final NodeBulkReader _nodeReader;

  /// Clock for `elapsedMs` measurement + wall-clock budget enforcement.
  final Clock _clock;

  /// Constructs the executor over the four concrete mode executors and
  /// a `NodeReader`. This is the production constructor — bound by the
  /// store opener once it lands later in Phase A.
  ///
  /// Pass [vector] = `null` when the boot path detected a missing
  /// `vec0` extension; vector-mode recalls will then surface as
  /// degraded.
  ///
  /// [clock] defaults to `SystemClock` for production. Tests inject
  /// a `MutableTestClock` to pin `elapsedMs`.
  RecallExecutor({
    required Bm25Recall bm25,
    required VectorRecall? vector,
    required SymbolicRecall symbolic,
    required NodeReader nodeReader,
    Clock clock = const SystemClock(),
  }) : this.fromCallables(
          bm25: bm25.recall,
          vector: vector?.recall,
          symbolic: symbolic.recall,
          nodeReader: nodeReader.getMany,
          clock: clock,
        );

  /// Callable-injecting constructor. Production prefers the concrete-
  /// class constructor above; tests use this one to wire fakes without
  /// having to spin up real SQLite + FTS5 + vec0 just to exercise the
  /// orchestrator's dispatch logic.
  ///
  /// [vector] may be `null` — same semantics as the concrete-class
  /// constructor (vector mode degrades when requested).
  RecallExecutor.fromCallables({
    required Bm25ModeFn bm25,
    required VectorModeFn? vector,
    required SymbolicModeFn symbolic,
    required NodeBulkReader nodeReader,
    Clock clock = const SystemClock(),
  })  : _bm25 = bm25,
        _vector = vector,
        _symbolic = symbolic,
        _nodeReader = nodeReader,
        _clock = clock;

  // ─── Public surface ──────────────────────────────────────────────

  /// Runs the recall pipeline for [query] and returns the
  /// fused-and-diversified result plus the cost report.
  ///
  /// Contract:
  ///
  ///   * Returns at most [RecallQuery.k] nodes.
  ///   * `RecallResult.report` is **always** present.
  ///   * Empty `query.modes` → empty result, report with zero counts
  ///     and `degraded = false`.
  ///   * A mode whose pre-requisites are missing (vector mode
  ///     without an embedding, vector mode with no vector executor,
  ///     graph walk before A.61) is degraded silently. `degraded`
  ///     bit on the report reflects this.
  ///   * Wall-clock budget exceeded → partial result, `degraded =
  ///     true`. The check runs between modes and after fusion; an
  ///     individual mode executor cannot be cancelled mid-call.
  ///   * `FusionStrategy.weighted` throws `UnimplementedError`. See
  ///     Q-A.57.4. RRF is the only fusion path at A.59.
  ///   * `DiversityStrategy.off` skips MMR; the fused list passes
  ///     through unchanged (truncated to `query.k`).
  ///   * `query.reRank`, when present, sees the *materialised
  ///     nodes* list (post-MMR, post-truncate). The returned id
  ///     list is filtered to ids present in the input; unknown ids
  ///     are dropped silently. `reRankInvoked = true` after the
  ///     call returns, regardless of whether the hook reordered.
  Future<RecallResult> recall(RecallQuery query) async {
    final startMs = _clock.nowMs();

    // candidatesPerMode is keyed by every mode the caller requested,
    // even when the count is 0. Modes the caller did not request are
    // absent from the map (spec § 6.4 example shows present-only).
    final candidatesPerMode = <RecallMode, int>{};
    final perModeRanked = <RecallMode, List<NodeId>>{};
    final bm25ScoreByNodeId = <String, double>{};
    var degraded = false;
    var reRankInvoked = false;

    for (final mode in query.modes) {
      // Budget short-circuit between modes.
      if (_overBudget(startMs, query.budget.wallClockMs)) {
        degraded = true;
        break;
      }
      final result = _runMode(mode, query, bm25ScoreByNodeId);
      candidatesPerMode[mode] = result.candidateCount;
      perModeRanked[mode] = result.ranked;
      if (result.degraded) degraded = true;
    }

    // Fusion. Empty per-mode map → empty fused list (rrfFuse handles
    // this explicitly). A budget-exceeded post-modes still gets a
    // valid fusion + report; we just won't run the diversify /
    // re-rank stages if we're already over budget.
    final fused = _fuse(query, perModeRanked);

    final overAfterFuse = _overBudget(startMs, query.budget.wallClockMs);
    if (overAfterFuse) degraded = true;

    // Diversify (or pass through). Capped at query.k.
    final selectedIds = overAfterFuse
        ? _idsOfFused(fused).take(query.k).toList(growable: false)
        : _diversify(query, fused, bm25ScoreByNodeId);

    // Bulk-materialise nodes in selection order. `getMany` already
    // preserves input order and elides missing ids; we keep its order.
    final materialised = await _nodeReader(selectedIds);

    // Optional re-rank.
    List<Node> finalNodes;
    if (query.reRank != null && materialised.isNotEmpty) {
      finalNodes = await _applyReRank(query.reRank!, materialised);
      reRankInvoked = true;
    } else {
      finalNodes = materialised;
    }

    // Final truncate to query.k. MMR already truncated; this is the
    // belt-and-braces step against a misbehaving re-rank hook that
    // somehow returns more ids than it was given.
    if (finalNodes.length > query.k) {
      finalNodes = finalNodes.sublist(0, query.k);
    }

    final endMs = _clock.nowMs();
    final report = RecallReport(
      candidatesPerMode: Map<RecallMode, int>.unmodifiable(candidatesPerMode),
      fusionStrategy: query.fusion.strategy,
      diversityStrategy: query.diversity.strategy,
      diversityLambda: query.diversity.strategy == DiversityStrategy.mmr
          ? query.diversity.lambda
          : null,
      elapsedMs: (endMs - startMs).clamp(0, 1 << 31),
      embeddingsCallouts: 0,
      reRankInvoked: reRankInvoked,
      degraded: degraded,
    );

    return RecallResult(
      nodes: List<Node>.unmodifiable(finalNodes),
      report: report,
    );
  }

  // ─── Internal: per-mode dispatch ─────────────────────────────────

  _ModeResult _runMode(
    RecallMode mode,
    RecallQuery query,
    Map<String, double> bm25ScoreByNodeId,
  ) {
    switch (mode) {
      case RecallMode.bm25:
        return _runBm25(query, bm25ScoreByNodeId);
      case RecallMode.vector:
        return _runVector(query);
      case RecallMode.symbolic:
        return _runSymbolic(query);
      case RecallMode.graphWalk:
        // A.61 lands graphWalk. Until then it is degraded silently.
        return const _ModeResult(
          candidateCount: 0,
          ranked: <NodeId>[],
          degraded: true,
        );
    }
  }

  _ModeResult _runBm25(
    RecallQuery query,
    Map<String, double> bm25ScoreByNodeId,
  ) {
    final text = query.text;
    if (text == null || text.isEmpty) {
      // BM25 without text is a refusal in the underlying executor
      // (returns empty). We mirror that here as "no candidates,
      // not degraded" — a caller that requests BM25 without text
      // gets the same empty result they would get from calling
      // `Bm25Recall` directly.
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: false,
      );
    }
    try {
      final candidates = _bm25(
        text: text,
        typeNames: query.filter?.typeNames,
        perModeK: query.budget.perModeK,
      );
      final ranked = <NodeId>[];
      for (final c in candidates) {
        ranked.add(c.nodeId);
        // BM25 score: lower = better. Stash for the MMR similarity
        // callback to normalise.
        bm25ScoreByNodeId[c.nodeId.value] = c.bm25Score;
      }
      return _ModeResult(
        candidateCount: candidates.length,
        ranked: List<NodeId>.unmodifiable(ranked),
        degraded: false,
      );
    } catch (_) {
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: true,
      );
    }
  }

  _ModeResult _runVector(RecallQuery query) {
    final vector = _vector;
    if (vector == null) {
      // Boot detected no vector backend. Spec § 15
      // `VectorIndexUnavailable` was already emitted; the recall
      // surface degrades silently.
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: true,
      );
    }
    final embedding = query.embedding;
    if (embedding == null) {
      // Caller did not supply an embedding and we do not embed on
      // their behalf at A.59. Degrade. The future embedder hookup
      // will add an `else { embed(text); count callout; }` branch
      // here.
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: true,
      );
    }
    try {
      final candidates = vector(
        query: embedding,
        typeNames: query.filter?.typeNames,
        perModeK: query.budget.perModeK,
      );
      final ranked =
          candidates.map((c) => c.nodeId).toList(growable: false);
      return _ModeResult(
        candidateCount: candidates.length,
        ranked: List<NodeId>.unmodifiable(ranked),
        degraded: false,
      );
    } catch (_) {
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: true,
      );
    }
  }

  _ModeResult _runSymbolic(RecallQuery query) {
    final filter = query.filter;
    if (filter == null) {
      // Symbolic without a filter is meaningless. Refuse silently —
      // the underlying executor would return the newest N nodes
      // (compiled tautology), which is almost never what a caller
      // who explicitly chose `RecallMode.symbolic` but forgot to
      // provide a filter wanted. Treat as zero candidates, not
      // degraded.
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: false,
      );
    }
    try {
      final candidates = _symbolic(
        filter: filter,
        perModeK: query.budget.perModeK,
      );
      final ranked =
          candidates.map((c) => c.nodeId).toList(growable: false);
      return _ModeResult(
        candidateCount: candidates.length,
        ranked: List<NodeId>.unmodifiable(ranked),
        degraded: false,
      );
    } catch (_) {
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: true,
      );
    }
  }

  // ─── Internal: fusion ────────────────────────────────────────────

  List<RrfFusedCandidate> _fuse(
    RecallQuery query,
    Map<RecallMode, List<NodeId>> perModeRanked,
  ) {
    switch (query.fusion.strategy) {
      case FusionStrategy.rrf:
        return rrfFuse(
          rankedLists: perModeRanked,
          kRrf: query.fusion.rrfK,
        );
      case FusionStrategy.weighted:
        // See Q-A.57.4. Implementation intentionally deferred until
        // a procedure-authored recall asks for it.
        throw UnimplementedError(
          'FusionStrategy.weighted not implemented at A.59; only '
          'FusionStrategy.rrf is wired. See Q-A.57.4.',
        );
    }
  }

  // ─── Internal: diversity ─────────────────────────────────────────

  List<NodeId> _diversify(
    RecallQuery query,
    List<RrfFusedCandidate> fused,
    Map<String, double> bm25ScoreByNodeId,
  ) {
    if (fused.isEmpty) return const <NodeId>[];
    switch (query.diversity.strategy) {
      case DiversityStrategy.off:
        return fused
            .take(query.k)
            .map((c) => c.nodeId)
            .toList(growable: false);
      case DiversityStrategy.mmr:
        final inputs = fused
            .map((c) => MmrInput<RrfFusedCandidate>(
                  item: c,
                  relevance: c.score,
                ))
            .toList(growable: false);
        final selected = mmrDiversify<RrfFusedCandidate>(
          candidates: inputs,
          similarity: (a, b) =>
              _bm25Similarity(a, b, bm25ScoreByNodeId),
          k: query.k,
          lambda: query.diversity.lambda,
        );
        return selected
            .map((s) => s.item.nodeId)
            .toList(growable: false);
    }
  }

  /// BM25-score-derived similarity between two fused candidates.
  ///
  /// Spec § 6.2 (fallback path for nodes without embeddings): "for
  /// nodes without embeddings, similarity falls back to BM25 score."
  /// The cosine-over-embeddings primary path is deferred (see
  /// "Deferred" in this file's header).
  ///
  /// Convention:
  ///
  ///   * BM25 returns *lower-is-better* scores; we squash to [0, 1]
  ///     where 1.0 = most relevant.
  ///   * Two candidates' similarity is the *minimum* of their two
  ///     squashed relevance scores — a candidate that wasn't in the
  ///     BM25 list at all (no entry) gets 0.0 and pulls the pair
  ///     similarity to 0.0. This is the conservative reading: nodes
  ///     we have no surface-form signal for are treated as
  ///     dissimilar from everything until we have evidence
  ///     otherwise.
  ///   * Self-similarity is impossible to ask for: MMR never calls
  ///     `similarity(x, x)` (mmr.dart's loop guarantees it). We do
  ///     not insert a defensive identity check.
  ///
  /// The choice of "minimum of squashed relevances" is a deliberately
  /// weak signal — the only thing the similarity callback needs to do
  /// at A.59 is *break diversity ties* without claiming false
  /// structure between candidates. When cosine-over-embeddings lands,
  /// this function becomes the second-tier fallback, called only for
  /// candidates with no embedding.
  static double _bm25Similarity(
    RrfFusedCandidate a,
    RrfFusedCandidate b,
    Map<String, double> bm25ScoreByNodeId,
  ) {
    final rawA = bm25ScoreByNodeId[a.nodeId.value];
    final rawB = bm25ScoreByNodeId[b.nodeId.value];
    if (rawA == null || rawB == null) return 0.0;
    final relA = _squashBm25(rawA);
    final relB = _squashBm25(rawB);
    return relA < relB ? relA : relB;
  }

  /// Maps a raw FTS5 BM25 score to a [0, 1] relevance estimate.
  ///
  /// FTS5's `bm25(...)` returns negative reals for matches (lower =
  /// more relevant) and 0 for non-matches. The squash:
  ///
  ///   * 0 (non-match)      → 0.0 relevance
  ///   * any negative match → `1 - exp(score)`  ∈ (0, 1)
  ///
  /// `1 - exp(score)` is monotonically increasing in `-score`, so
  /// MMR's "more relevant = more similar" semantics survive. Picking
  /// the exact squash function is not load-bearing — any
  /// monotonically-increasing map from `-raw` to [0, 1) would do.
  static double _squashBm25(double raw) {
    if (raw >= 0.0) return 0.0;
    final r = 1.0 - math.exp(raw);
    if (r < 0.0) return 0.0;
    if (r > 1.0) return 1.0;
    return r;
  }

  // ─── Internal: re-rank ───────────────────────────────────────────

  Future<List<Node>> _applyReRank(
    ReRankHook hook,
    List<Node> materialised,
  ) async {
    final returned = await hook(materialised);
    if (returned.isEmpty) return materialised;
    // Build an id → node map so we can reorder by the hook's output
    // and silently drop unknown ids.
    final nodeById = <String, Node>{
      for (final n in materialised) n.id.value: n,
    };
    final reordered = <Node>[];
    final seen = <String>{};
    for (final id in returned) {
      final key = id.value;
      if (!seen.add(key)) continue;
      final node = nodeById[key];
      if (node != null) reordered.add(node);
    }
    // If the hook returned a strict subset, append the missing
    // originals at the end in their original order — the hook
    // expresses a preference but does not get to silently delete.
    if (reordered.length < materialised.length) {
      for (final n in materialised) {
        if (!seen.contains(n.id.value)) reordered.add(n);
      }
    }
    return reordered;
  }

  // ─── Internal: clock helpers ─────────────────────────────────────

  bool _overBudget(int startMs, int budgetMs) {
    if (budgetMs <= 0) return false;
    return _clock.nowMs() - startMs > budgetMs;
  }

  static List<NodeId> _idsOfFused(List<RrfFusedCandidate> fused) =>
      fused.map((c) => c.nodeId).toList(growable: false);
}

/// One mode's per-call outcome, threaded back from `_runMode` to the
/// orchestration body. Carried as a private value type so adding a
/// future field (e.g. per-mode elapsed) does not change the dispatch
/// signatures.
final class _ModeResult {
  final int candidateCount;
  final List<NodeId> ranked;
  final bool degraded;

  const _ModeResult({
    required this.candidateCount,
    required this.ranked,
    required this.degraded,
  });
}
