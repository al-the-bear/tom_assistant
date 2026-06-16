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
//     `SymbolicRecall`, and `GraphWalkRecall` are standalone units in
//     this package; the executor just calls them.
//   - The pure-function fusion / diversity primitives. `rrfFuse` lives
//     in `rrf.dart`; `mmrDiversify` lives in `mmr.dart`. The executor
//     is the *composer* — it knows nothing about the math beyond the
//     contracts those files document.
//   - The embedding model itself. The executor does not *own* an
//     embedder; it calls an optional injected one (`RecallEmbedder`,
//     the storage-stack model — non-generative, Q-H.1) when a
//     vector-mode seed carries `text` but no precomputed `embedding`.
//     When no embedder is wired (or the seed has no text), the vector
//     mode degrades — vector skipped, no callout counted. Each embed
//     that does happen increments `embeddingsCallouts`.
//   - The cosine-over-embeddings similarity. Cosine itself is in
//     `tom_brain_shared` (`Vec.cosine`), but reading a *node's*
//     embedding requires `VectorTable` to expose a `getEmbeddingsFor`
//     surface; that lookup is not yet on the table. The fallback —
//     BM25-score-derived similarity — is what the executor uses today.
//   - The graph-walk traversal itself. `GraphWalkRecall` owns the
//     BFS-with-decay logic, the cycle-detection visited-set, and the
//     per-edge-type weight table; the executor's only job is to hand
//     it the seeds + per-query `GraphWalkPolicy` + optional typeNames
//     filter, then thread the resulting ranking into RRF.
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
//           - graphWalk → GraphWalkRecall.recall(...) iff seeds ≠ null
//                         and non-empty
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
//   - **`FusionStrategy.weighted`.** The policy carries optional
//     weights; the executor today routes only RRF. The gate is the
//     `FusionStrategy` switch in `_fuse`. See Q-A.57.4.
//
// What this file owns since A.69:
//
//   - `RetrievalConflict` shaking-event emission (spec § 9.4). After
//     the per-mode dispatch loop completes but BEFORE fusion, the
//     executor inspects the set of modes that returned non-empty
//     candidate lists. When at least two such modes exist AND the
//     intersection of their top-`min(5, perModeK)` `NodeId`s is
//     empty, a `RetrievalConflict` is emitted onto the optional
//     `_eventSink`. See Q-A.69.3 for the disagreement-rule
//     rationale. RRF will still fuse the disjoint lists; the event is
//     a typed signal that the resulting ordering is structurally
//     fragile and a `dream_reconsolidate_v1` pass should look at the
//     query. The optional `Scope` parameter on `recall()` only
//     supplies `runId` / `causedBy` for the emitted event; it is not
//     consulted by the executor for any other purpose.

import 'dart:math' as math;

import 'package:tom_brain_shared/tom_brain_shared.dart' show Clock, DiversityStrategy, FusionStrategy, GraphWalkPolicy, MemoryEvent, MultiRecallQuery, Node, NodeId, RecallBudget, RecallMode, RecallProvenanceEntry, RecallQuery, RecallRanking, RecallReport, RecallResult, RecallSeed, ReRankHook, Scope, SymbolicFilter, SystemClock, Vec;

import '../cognitive_agents/shaking_events.dart';

import '../nodes/node_reader.dart';
import '../observability/memory_log.dart';
import 'bm25_recall.dart';
import 'graph_walk_recall.dart';
import 'mmr.dart';
import 'ranking_rescore.dart';
import 'recall_events.dart';

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

/// Signature of the graph-walk mode executor, as seen by
/// [RecallExecutor].
///
/// Matches `GraphWalkRecall.recall`. Tests inject a fake; production
/// wires the method tear-off.
typedef GraphWalkModeFn = List<GraphWalkRecallCandidate> Function({
  required Set<NodeId> seeds,
  GraphWalkPolicy policy,
  Set<String>? typeNames,
  int perModeK,
});

/// Bulk node read for the post-fusion materialisation step.
///
/// Matches `NodeReader.getMany`. Tests inject a fake that resolves from
/// an in-memory map; production wires the method tear-off.
typedef NodeBulkReader = Future<List<Node>> Function(List<NodeId> ids);

/// Per-type recency half-life lookup used by the post-fusion
/// `recencyBoosted` re-score (spec § 6.1.1 / § 6.2.1, § 6.6).
///
/// Returns the half-life over which a node's recency factor decays to
/// 0.5 for a given `typeName`. The `decay` config block (plan § 12) will
/// supply the real per-type values; until then the executor passes
/// [_defaultHalfLifeForType].
typedef HalfLifeForType = Duration Function(String typeName);

/// The storage-stack embedding model, as seen by [RecallExecutor].
///
/// Non-generative (Q-H.1): it turns a vector seed's `text` into a query
/// `Vec` when the caller supplied no pre-computed `embedding`. It is part
/// of memory's storage stack, not an LLM — invoking it does **not** count
/// as instantiating a generative model.
///
/// `null` when no embedder is wired into the executor; in that case a
/// text-only vector seed degrades (vector mode skipped) exactly as it did
/// before the embedder hookup landed.
typedef RecallEmbedder = Future<Vec> Function(String text);

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
  /// Upper clamp for the recorded `elapsedMs`. Guards against a
  /// non-monotonic wall clock producing a negative or absurdly large
  /// delta; `2^31` ms (~24.8 days) is far beyond any real recall and
  /// keeps the value in a 32-bit-friendly range for consumers.
  static const int _maxElapsedMs = 1 << 31;

  /// BM25 mode executor function. Always required.
  final Bm25ModeFn _bm25;

  /// Vector mode executor function. In production it is always
  /// supplied — the brain refuses to boot when vec0 is absent
  /// (`loadVecExtensionOrRefuseToBoot`, A.50). It may be `null` only in
  /// tests that construct the executor without a vector backend; when
  /// `null` and `RecallMode.vector` is requested, the mode is degraded
  /// and `RecallReport.degraded` is set true.
  final VectorModeFn? _vector;

  /// Symbolic mode executor function. Always required.
  final SymbolicModeFn _symbolic;

  /// Graph-walk mode executor function. Always required at A.61+;
  /// previously a stub-degraded slot in the executor.
  final GraphWalkModeFn _graphWalk;

  /// Bulk-node reader for the post-fusion materialisation.
  final NodeBulkReader _nodeReader;

  /// Optional storage-stack embedder. When supplied, a `RecallMode.vector`
  /// seed that carries `text` but no pre-computed `embedding` is embedded
  /// once via this callable (counted as one `embeddingsCallouts`) before
  /// the vector executor runs. When `null`, such a seed degrades — the
  /// pre-hookup behaviour. Non-generative (Q-H.1).
  final RecallEmbedder? _embedder;

  /// Clock for `elapsedMs` measurement + wall-clock budget enforcement.
  final Clock _clock;

  /// Optional sink for `MemoryEvent`s — currently used to emit
  /// `RetrievalConflict` after the mode loop (A.69; spec § 9.4). The
  /// concrete `SqliteTomBrainMemory` wires this to the same
  /// `StreamController` that backs `TomBrainMemory.events()`; tests
  /// pass a list-backed sink to inspect emissions.
  final void Function(MemoryEvent)? _eventSink;

  /// `w_recency` — the recency weight applied by the `recencyBoosted`
  /// re-score (spec § 6.2.1). Defaults to 1.0 until the `retrieval.ranking`
  /// config block lands (plan § 12). Ignored by every other ranking.
  final double _recencyWeight;

  /// Per-type recency half-life lookup for the `recencyBoosted` re-score.
  /// Defaults to [_defaultHalfLifeForType] (a flat 30 days) until the
  /// `decay` config block lands (plan § 12). Ignored by every other
  /// ranking.
  final HalfLifeForType _halfLifeForType;

  /// Cap on the per-mode top-K window used for the empty-intersection
  /// disagreement check (A.69; see Q-A.69.3). The window the executor
  /// actually uses is `min(_retrievalConflictTopK, perModeK)`.
  static const int _retrievalConflictTopK = 5;

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
  ///
  /// [embedder] is the optional storage-stack embedding model. When
  /// supplied, a vector seed carrying only `text` (no `embedding`) is
  /// embedded through it; when `null` such a seed degrades.
  ///
  /// [eventSink] is optional — wire it to the memory store's typed
  /// event stream to receive `RetrievalConflict` signals when the
  /// per-mode results disagree (spec § 9.4; A.69).
  RecallExecutor({
    required Bm25Recall bm25,
    required VectorRecall? vector,
    required SymbolicRecall symbolic,
    required GraphWalkRecall graphWalk,
    required NodeReader nodeReader,
    RecallEmbedder? embedder,
    Clock clock = const SystemClock(),
    void Function(MemoryEvent)? eventSink,
    double recencyWeight = 1.0,
    HalfLifeForType halfLifeForType = _defaultHalfLifeForType,
  }) : this.fromCallables(
          bm25: bm25.recall,
          vector: vector?.recall,
          symbolic: symbolic.recall,
          graphWalk: graphWalk.recall,
          nodeReader: nodeReader.getMany,
          embedder: embedder,
          clock: clock,
          eventSink: eventSink,
          recencyWeight: recencyWeight,
          halfLifeForType: halfLifeForType,
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
    required GraphWalkModeFn graphWalk,
    required NodeBulkReader nodeReader,
    RecallEmbedder? embedder,
    Clock clock = const SystemClock(),
    void Function(MemoryEvent)? eventSink,
    double recencyWeight = 1.0,
    HalfLifeForType halfLifeForType = _defaultHalfLifeForType,
  })  : _bm25 = bm25,
        _vector = vector,
        _symbolic = symbolic,
        _graphWalk = graphWalk,
        _nodeReader = nodeReader,
        _embedder = embedder,
        _clock = clock,
        _eventSink = eventSink,
        _recencyWeight = recencyWeight,
        _halfLifeForType = halfLifeForType;

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
  ///   * A mode whose pre-requisites are missing (vector mode with no
  ///     embedding *and* no embedder/text to derive one, vector mode
  ///     with no vector executor, graph walk without seeds) is degraded
  ///     silently. `degraded` bit on the report reflects this. A vector
  ///     mode that embeds a text-only seed via the storage-stack
  ///     embedder counts one `embeddingsCallouts` and is **not**
  ///     degraded.
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
  ///   * `RetrievalConflict` (A.69; spec § 9.4) is emitted onto the
  ///     optional event sink — between the mode loop and fusion —
  ///     whenever at least two modes returned non-empty candidate
  ///     lists AND the intersection of their top-`min(5, perModeK)`
  ///     `NodeId`s is empty. The fused result is still returned;
  ///     the event is a typed signal, not a refusal. [scope] only
  ///     supplies `runId` / `causedBy` for the emitted event.
  Future<RecallResult> recall(RecallQuery query, {Scope? scope}) async {
    final startMs = _clock.nowMs();

    // candidatesPerMode is keyed by every mode the caller requested,
    // even when the count is 0. Modes the caller did not request are
    // absent from the map (spec § 6.4 example shows present-only).
    final candidatesPerMode = <RecallMode, int>{};
    final perModeRanked = <RecallMode, List<NodeId>>{};
    final bm25ScoreByNodeId = <String, double>{};
    var degraded = false;
    var reRankInvoked = false;
    var embeddingsCallouts = 0;

    for (final mode in query.modes) {
      // Budget short-circuit between modes.
      if (_overBudget(startMs, query.budget.wallClockMs)) {
        degraded = true;
        break;
      }
      final result = await _runMode(mode, query, bm25ScoreByNodeId);
      candidatesPerMode[mode] = result.candidateCount;
      perModeRanked[mode] = result.ranked;
      embeddingsCallouts += result.embeddingsCallouts;
      if (result.degraded) degraded = true;
    }

    // A.69 — `RetrievalConflict` shaking-event emission (spec § 9.4).
    // Runs between mode dispatch and fusion: it inspects what each
    // mode wanted before RRF blurs that signal into a single ranking.
    // Cheap (early-out when no sink wired; only iterates non-empty
    // per-mode lists; the intersection is over a top-K window <= 5).
    _maybeEmitRetrievalConflict(
      perModeRanked: perModeRanked,
      perModeK: query.budget.perModeK,
      scope: scope,
    );

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

    // Post-fusion recency/frequency re-score (spec § 6.2.1; plan § 7).
    // The usage columns live on the materialised nodes, so the re-score
    // runs here — after fusion+MMR, before the optional re-rank hook —
    // threading each node's fused relevance from `fused`. For the
    // default `RecallRanking.relevance` this is a no-op pass-through.
    final reordered =
        _applyRanking(query.ranking, materialised, _relevanceFromRrf(fused));

    // Optional re-rank.
    List<Node> finalNodes;
    if (query.reRank != null && reordered.isNotEmpty) {
      finalNodes = await _applyReRank(query.reRank!, reordered);
      reRankInvoked = true;
    } else {
      finalNodes = reordered;
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
      elapsedMs: (endMs - startMs).clamp(0, _maxElapsedMs),
      embeddingsCallouts: embeddingsCallouts,
      reRankInvoked: reRankInvoked,
      degraded: degraded,
    );

    // A.84 — observability hook. A `debug` line on every recall is
    // fine in development and filtered out in production; a `warn`
    // line on the degraded path is always visible at `still` and
    // tells an operator that a recall fell back early without having
    // to subscribe to events. Lazy evaluation keeps the formatting
    // cost off the production hot path.
    if (degraded) {
      MemoryLog.retrieval.warn(
        () => 'recall degraded after ${report.elapsedMs}ms '
            '(modes=${query.modes.map((m) => m.name).join("+")}, '
            'k=${query.k}, returned=${finalNodes.length})',
      );
    } else {
      MemoryLog.retrieval.debug(
        () => 'recall ok in ${report.elapsedMs}ms '
            '(modes=${query.modes.map((m) => m.name).join("+")}, '
            'k=${query.k}, returned=${finalNodes.length})',
      );
    }

    // Spec § 16 — `RecallCompleted` (carries `RecallReport`). One
    // event per recall call, including the empty-modes and degraded
    // paths; subscribers filter on `degraded` / `returnedCount`
    // themselves. Short-circuits on a null sink so the typical recall
    // pays a single null check.
    final sink = _eventSink;
    if (sink != null) {
      sink(
        RecallCompleted(
          requestedModes: List<RecallMode>.unmodifiable(query.modes),
          returnedCount: finalNodes.length,
          report: report,
          occurredAt: _clock.now(),
          runId: scope?.runId,
          causedBy: scope?.causedBy,
        ),
      );
    }

    return RecallResult(
      nodes: List<Node>.unmodifiable(finalNodes),
      report: report,
    );
  }

  /// Runs the multi-seed recall pipeline for [query] (memory § 6.5,
  /// Extension H) and returns the fused-and-diversified result plus the
  /// per-node seed provenance and cost report.
  ///
  /// Contract:
  ///
  ///   * Each [MultiRecallQuery.seeds] entry runs through the same
  ///     § 6.1 mode executors as single-seed `recall`, under its own
  ///     [RecallSeed.k] per-seed cap. A seed whose required payload for
  ///     its mode is absent (or whose mode degrades) contributes an
  ///     empty ranked list at its index — exactly as the equivalent
  ///     single-mode `recall` would.
  ///   * The per-seed ranked lists are fused with weighted RRF
  ///     ([rrfFuseSeeds]) honouring each [RecallSeed.weight], then
  ///     diversified with MMR (or passed through when
  ///     `DiversityStrategy.off`), and truncated to [MultiRecallQuery.k].
  ///   * The returned [RecallResult.provenance] is index-aligned with
  ///     [RecallResult.nodes]: one [RecallProvenanceEntry] per returned
  ///     node naming the seed indices that surfaced it and its fused
  ///     score.
  ///   * Instantiates no LLM. The empty-seeds list yields an empty
  ///     result. Wall-clock budget exceeded → partial result with
  ///     `degraded = true`.
  ///   * [scope] only supplies `runId` / `causedBy` for the emitted
  ///     `MultiRecallCompleted`.
  Future<RecallResult> recallMulti(
    MultiRecallQuery query, {
    Scope? scope,
  }) async {
    final startMs = _clock.nowMs();

    final seeds = query.seeds;
    final seedRankedLists = <List<NodeId>>[];
    final seedWeights = <double>[];
    final seedCandidateCounts = <int>[];
    final candidatesPerMode = <RecallMode, int>{};
    final bm25ScoreByNodeId = <String, double>{};
    var degraded = false;
    var embeddingsCallouts = 0;

    for (final seed in seeds) {
      // Budget short-circuit between seeds. A seed we skip past the
      // budget still occupies its index (empty list) so provenance
      // stays index-aligned with `MultiRecallQuery.seeds`.
      if (_overBudget(startMs, query.budget.wallClockMs)) {
        degraded = true;
        seedRankedLists.add(const <NodeId>[]);
        seedWeights.add(seed.weight);
        seedCandidateCounts.add(0);
        continue;
      }
      final synthetic = _seedToQuery(seed, query.budget.wallClockMs);
      final result = await _runMode(seed.mode, synthetic, bm25ScoreByNodeId);
      seedRankedLists.add(result.ranked);
      seedWeights.add(seed.weight);
      seedCandidateCounts.add(result.candidateCount);
      embeddingsCallouts += result.embeddingsCallouts;
      candidatesPerMode.update(
        seed.mode,
        (n) => n + result.candidateCount,
        ifAbsent: () => result.candidateCount,
      );
      if (result.degraded) degraded = true;
    }

    // Weighted-RRF fusion over the per-seed ranked lists. `rrfFuseSeeds`
    // handles the empty-seeds and all-empty cases by returning `const
    // []`.
    final fused = rrfFuseSeeds(
      seedRankedLists: seedRankedLists,
      seedWeights: seedWeights,
      kRrf: query.fusion.rrfK,
    );

    final overAfterFuse = _overBudget(startMs, query.budget.wallClockMs);
    if (overAfterFuse) degraded = true;

    // Diversify (MMR) or pass through, capped at query.k.
    final selected = overAfterFuse
        ? fused.take(query.k).toList(growable: false)
        : _diversifySeeds(query, fused, bm25ScoreByNodeId);

    final selectedIds =
        selected.map((c) => c.nodeId).toList(growable: false);

    // Bulk-materialise in selection order. `getMany` preserves input
    // order and elides missing ids.
    final materialised = await _nodeReader(selectedIds);

    // Post-fusion recency/frequency re-score (spec § 6.2.1; plan § 7).
    // Re-order the materialised nodes before building provenance, so the
    // index-aligned provenance follows the re-ordered node list. For the
    // default `RecallRanking.relevance` this is a no-op pass-through.
    final reordered = _applyRanking(
      query.ranking,
      materialised,
      <String, double>{for (final c in selected) c.nodeId.value: c.score},
    );

    // Build provenance aligned with the *returned* node list (a node
    // elided by `getMany` drops out of both the node list and its
    // provenance entry).
    final candidateByNode = <String, SeedFusedCandidate>{
      for (final c in selected) c.nodeId.value: c,
    };
    final provenance = <RecallProvenanceEntry>[];
    for (final node in reordered) {
      final c = candidateByNode[node.id.value];
      if (c == null) continue; // defensive: getMany never invents ids
      provenance.add(
        RecallProvenanceEntry(
          nodeId: node.id,
          seedIndexes: c.seedIndexes,
          fusedScore: c.score,
        ),
      );
    }

    final endMs = _clock.nowMs();
    final report = RecallReport(
      candidatesPerMode: Map<RecallMode, int>.unmodifiable(candidatesPerMode),
      fusionStrategy: query.fusion.strategy,
      diversityStrategy: query.diversity.strategy,
      diversityLambda: query.diversity.strategy == DiversityStrategy.mmr
          ? query.diversity.lambda
          : null,
      elapsedMs: (endMs - startMs).clamp(0, _maxElapsedMs),
      embeddingsCallouts: embeddingsCallouts,
      reRankInvoked: false,
      degraded: degraded,
    );

    if (degraded) {
      MemoryLog.retrieval.warn(
        () => 'recallMulti degraded after ${report.elapsedMs}ms '
            '(seeds=${seeds.length}, k=${query.k}, '
            'returned=${materialised.length})',
      );
    } else {
      MemoryLog.retrieval.debug(
        () => 'recallMulti ok in ${report.elapsedMs}ms '
            '(seeds=${seeds.length}, k=${query.k}, '
            'returned=${materialised.length})',
      );
    }

    // Spec § 16 — `MultiRecallCompleted` (carries per-seed candidate
    // counts + fused-result provenance). One event per call, including
    // the empty-seeds and degraded paths.
    final sink = _eventSink;
    if (sink != null) {
      sink(
        MultiRecallCompleted(
          seedCandidateCounts:
              List<int>.unmodifiable(seedCandidateCounts),
          returnedCount: provenance.length,
          report: report,
          provenance: List<RecallProvenanceEntry>.unmodifiable(provenance),
          occurredAt: _clock.now(),
          runId: scope?.runId,
          causedBy: scope?.causedBy,
        ),
      );
    }

    return RecallResult(
      nodes: List<Node>.unmodifiable(reordered),
      report: report,
      provenance: List<RecallProvenanceEntry>.unmodifiable(provenance),
    );
  }

  /// Projects one [RecallSeed] onto a synthetic single-mode
  /// [RecallQuery] so the per-mode executors (`_runMode`) can run it
  /// unchanged. The per-seed cap [RecallSeed.k] becomes the synthetic
  /// query's `perModeK`; [wallClockMs] is the shared multi-seed budget.
  ///
  /// BM25 seeds prefer [RecallSeed.terms] (joined on space) over
  /// [RecallSeed.text], mirroring the single-payload BM25 contract.
  static RecallQuery _seedToQuery(RecallSeed seed, int wallClockMs) {
    final terms = seed.terms;
    final bm25Text =
        (terms != null && terms.isNotEmpty) ? terms.join(' ') : seed.text;
    return RecallQuery(
      modes: {seed.mode},
      text: seed.mode == RecallMode.bm25 ? bm25Text : seed.text,
      embedding: seed.embedding,
      seeds: seed.startNodes,
      filter: seed.filter,
      k: seed.k,
      budget: RecallBudget(perModeK: seed.k, wallClockMs: wallClockMs),
    );
  }

  /// MMR diversification over the weighted-RRF fused seed candidates.
  /// Mirrors [_diversify] but operates on [SeedFusedCandidate].
  List<SeedFusedCandidate> _diversifySeeds(
    MultiRecallQuery query,
    List<SeedFusedCandidate> fused,
    Map<String, double> bm25ScoreByNodeId,
  ) {
    if (fused.isEmpty) return const <SeedFusedCandidate>[];
    switch (query.diversity.strategy) {
      case DiversityStrategy.off:
        return fused.take(query.k).toList(growable: false);
      case DiversityStrategy.mmr:
        final inputs = fused
            .map((c) => MmrInput<SeedFusedCandidate>(
                  item: c,
                  relevance: c.score,
                ))
            .toList(growable: false);
        final selected = mmrDiversify<SeedFusedCandidate>(
          candidates: inputs,
          similarity: (a, b) => _bm25SimilarityByNodeId(
            a.nodeId,
            b.nodeId,
            bm25ScoreByNodeId,
          ),
          k: query.k,
          lambda: query.diversity.lambda,
        );
        return selected.map((s) => s.item).toList(growable: false);
    }
  }

  // ─── Internal: per-mode dispatch ─────────────────────────────────

  /// Dispatches one mode. Async because the vector branch may embed a
  /// text-only seed through the storage-stack [_embedder]; the other
  /// three branches are synchronous and their results are returned
  /// directly (auto-wrapped in a completed future).
  Future<_ModeResult> _runMode(
    RecallMode mode,
    RecallQuery query,
    Map<String, double> bm25ScoreByNodeId,
  ) async {
    switch (mode) {
      case RecallMode.bm25:
        return _runBm25(query, bm25ScoreByNodeId);
      case RecallMode.vector:
        return _runVector(query);
      case RecallMode.symbolic:
        return _runSymbolic(query);
      case RecallMode.graphWalk:
        return _runGraphWalk(query);
    }
  }

  _ModeResult _runGraphWalk(RecallQuery query) {
    final seeds = query.seeds;
    if (seeds == null || seeds.isEmpty) {
      // Graph walk without a seed set is meaningless. Refuse silently —
      // mirrors the symbolic-mode "no filter" branch. Treat as zero
      // candidates, not degraded: the caller asked for a mode whose
      // input was missing, which is a no-op, not a system fault.
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: false,
      );
    }
    try {
      final candidates = _graphWalk(
        seeds: seeds,
        policy: query.graphWalk,
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

  Future<_ModeResult> _runVector(RecallQuery query) async {
    final vector = _vector;
    if (vector == null) {
      // No vector backend was wired into this executor. In production
      // the brain refuses to boot when vec0 is absent
      // (`loadVecExtensionOrRefuseToBoot`), so this branch is reached
      // only by tests that construct the executor without a vector
      // backend; the recall surface degrades silently for them.
      return const _ModeResult(
        candidateCount: 0,
        ranked: <NodeId>[],
        degraded: true,
      );
    }

    // Resolve the query embedding. A caller-supplied embedding is used
    // verbatim (no callout). Otherwise, when a storage-stack embedder is
    // wired and the seed carries text, embed the text once (spec § 6.5;
    // Q-H.1 — non-generative). With no embedder or no text there is
    // nothing to embed, so the mode degrades exactly as it did before
    // the hookup.
    var embedding = query.embedding;
    var embeddingsCallouts = 0;
    if (embedding == null) {
      final embedder = _embedder;
      final text = query.text;
      if (embedder == null || text == null || text.isEmpty) {
        return const _ModeResult(
          candidateCount: 0,
          ranked: <NodeId>[],
          degraded: true,
        );
      }
      try {
        embedding = await embedder(text);
      } catch (_) {
        // An embedder failure degrades the vector mode, mirroring the
        // silent-degrade contract the mode executors already follow.
        return const _ModeResult(
          candidateCount: 0,
          ranked: <NodeId>[],
          degraded: true,
        );
      }
      embeddingsCallouts = 1;
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
        embeddingsCallouts: embeddingsCallouts,
      );
    } catch (_) {
      // The embed callout (if it happened) still counts — it was a real
      // call to the storage model — even though the vector lookup failed.
      return _ModeResult(
        candidateCount: 0,
        ranked: const <NodeId>[],
        degraded: true,
        embeddingsCallouts: embeddingsCallouts,
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
  ) =>
      _bm25SimilarityByNodeId(a.nodeId, b.nodeId, bm25ScoreByNodeId);

  /// BM25-score-derived similarity keyed directly by [NodeId] — the
  /// shared core of [_bm25Similarity], reused by the multi-seed
  /// diversifier ([_diversifySeeds]) which carries `SeedFusedCandidate`
  /// rather than `RrfFusedCandidate`.
  static double _bm25SimilarityByNodeId(
    NodeId a,
    NodeId b,
    Map<String, double> bm25ScoreByNodeId,
  ) {
    final rawA = bm25ScoreByNodeId[a.value];
    final rawB = bm25ScoreByNodeId[b.value];
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

  // ─── Internal: post-fusion ranking re-score (plan § 7) ───────────

  /// Re-orders [nodes] per [ranking] using the post-fusion recency /
  /// frequency re-score (spec § 6.2.1). [relevanceByNodeId] maps a
  /// node's id value to its fused relevance score `r(d)`; a node absent
  /// from the map (defensive — the materialised set is a subset of the
  /// fused set) is treated as relevance 0.
  ///
  /// For [RecallRanking.relevance] the function returns [nodes]
  /// unchanged (the fusion+MMR order is the answer).
  List<Node> _applyRanking(
    RecallRanking ranking,
    List<Node> nodes,
    Map<String, double> relevanceByNodeId,
  ) {
    if (ranking == RecallRanking.relevance || nodes.isEmpty) return nodes;
    final candidates = <RankingCandidate<Node>>[
      for (final n in nodes)
        RankingCandidate<Node>(
          item: n,
          relevance: relevanceByNodeId[n.id.value] ?? 0.0,
          typeName: n.typeName,
          lastAccessMs: n.lastAccess.millisecondsSinceEpoch,
          accessCount: n.accessCount,
        ),
    ];
    return rescoreByRanking<Node>(
      ranking: ranking,
      candidates: candidates,
      now: _clock.now(),
      halfLifeForType: _halfLifeForType,
      recencyWeight: _recencyWeight,
    );
  }

  /// Projects the RRF-fused candidate list onto an `id → relevance` map
  /// for [_applyRanking]. The fused list survives the diversify step
  /// (which only re-orders / truncates), so every materialised node has
  /// an entry here.
  static Map<String, double> _relevanceFromRrf(
    List<RrfFusedCandidate> fused,
  ) =>
      <String, double>{for (final c in fused) c.nodeId.value: c.score};

  // ─── Internal: shaking events (A.69) ─────────────────────────────

  /// Detects `RetrievalConflict` and emits onto [_eventSink] when
  /// warranted (spec § 9.4; Q-A.69.3).
  ///
  /// The disagreement rule: at least two modes returned non-empty
  /// candidate lists AND the intersection of their top-`min(5,
  /// perModeK)` `NodeId`s is empty. Modes whose candidate list is
  /// empty (degraded, no matches, refused for missing inputs) do not
  /// participate in the check — they did not produce a conflicting
  /// opinion, they produced no opinion.
  ///
  /// Short-circuits early when no sink is wired so the typical recall
  /// pays no cost beyond a single null check.
  void _maybeEmitRetrievalConflict({
    required Map<RecallMode, List<NodeId>> perModeRanked,
    required int perModeK,
    required Scope? scope,
  }) {
    final sink = _eventSink;
    if (sink == null) return;
    if (perModeRanked.isEmpty) return;

    // Collect modes that actually produced candidates.
    final contributingModes = <RecallMode>[];
    final topPerMode = <RecallMode, List<NodeId>>{};
    final cap = perModeK < _retrievalConflictTopK
        ? perModeK
        : _retrievalConflictTopK;
    if (cap <= 0) return;

    for (final entry in perModeRanked.entries) {
      if (entry.value.isEmpty) continue;
      contributingModes.add(entry.key);
      final topN = entry.value.length > cap
          ? entry.value.sublist(0, cap)
          : List<NodeId>.from(entry.value);
      topPerMode[entry.key] = List<NodeId>.unmodifiable(topN);
    }

    // A single contributing mode cannot disagree with itself.
    if (contributingModes.length < 2) return;

    // Intersection over `value` (the underlying String) — `NodeId` is
    // a value-equal wrapper, but using `value` keeps the set keyed by
    // a primitive type so contains-checks remain O(1) without
    // depending on `NodeId`'s `hashCode` contract surfaced elsewhere.
    var intersection = topPerMode[contributingModes.first]!
        .map((id) => id.value)
        .toSet();
    for (var i = 1; i < contributingModes.length; i++) {
      intersection = intersection
          .intersection(topPerMode[contributingModes[i]]!
              .map((id) => id.value)
              .toSet());
      if (intersection.isEmpty) break;
    }
    if (intersection.isNotEmpty) return;

    sink(
      RetrievalConflict(
        conflictingModes:
            List<RecallMode>.unmodifiable(contributingModes),
        topPerMode: Map<RecallMode, List<NodeId>>.unmodifiable(topPerMode),
        topK: cap,
        occurredAt: _clock.now(),
        runId: scope?.runId,
        causedBy: scope?.causedBy,
      ),
    );
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

  /// Number of storage-stack embed callouts this mode made (0 or 1).
  /// Only the vector mode embeds, and only when it had to embed a
  /// text-only seed; every other mode reports 0.
  final int embeddingsCallouts;

  const _ModeResult({
    required this.candidateCount,
    required this.ranked,
    required this.degraded,
    this.embeddingsCallouts = 0,
  });
}

/// Fallback recency half-life used by the `recencyBoosted` re-score
/// until the `decay` config block lands (plan § 12): a flat 30 days for
/// every node type. [typeName] is accepted to match [HalfLifeForType]
/// but is not consulted yet — per-type half-lives arrive with the config
/// wiring.
Duration _defaultHalfLifeForType(String typeName) => const Duration(days: 30);
