// Barrel for the `retrieval/` module.
//
// As of A.61 this barrel exports:
//
//   - `RecallQuery` — input record for `TomBrainMemory.recall`,
//     plus `RecallMode`, `SymbolicFilter`, `AttrClause`,
//     `SymbolicOp`, `RecallBudget`, `FusionPolicy`,
//     `FusionStrategy`, `DiversityPolicy`, `DiversityStrategy`,
//     `GraphWalkPolicy`, and the `ReRankHook` typedef.
//   - `RecallResult`, `RecallReport` — output record + cost
//     breakdown.
//   - `StreamQuery`, `StreamCursor` — cursor-backed bulk iteration.
//   - `Fts5Catalog` — per-type FTS5 virtual-table layout owner.
//   - `Fts5Writer` — per-type FTS5 INSERT path called by the
//     persister.
//   - `Bm25Recall`, `Bm25RecallCandidate` — BM25-mode executor for
//     `RecallQuery.text`.
//   - `VectorRecall`, `VectorRecallCandidate` — vector-mode executor
//     for `RecallQuery.embedding`. Groups embedding-bearing types by
//     `EmbeddingPolicy.modelIdentity`, queries each per-model index
//     in `vectors.db` once, enriches with `type_name` from `nodes`,
//     and merges into a single ascending-distance ranking.
//   - `SymbolicRecall`, `SymbolicRecallCandidate`,
//     `CompiledSymbolicFilter`, `compileSymbolicFilter` —
//     symbolic-mode executor for `RecallQuery.filter`. Compiles a
//     `SymbolicFilter` into a parameterised SQL `WHERE` clause over
//     the `nodes` table (type, time window, scope, attribute
//     equality / comparison / IN-list).
//   - `GraphWalkRecall`, `GraphWalkRecallCandidate`,
//     `kDefaultEdgeTypeWeight` — graph-walk-mode executor for
//     `RecallQuery.seeds`. Runs a bounded-depth BFS over
//     `memory.db.edges` with per-edge-type weights, depth decay, an
//     optional direction filter, and an optional `typeNames` post-
//     filter. Seeds are excluded from the result; cycles are broken
//     at first re-entry via a visited-set guard.
//   - `rrfFuse`, `RrfFusedCandidate`, `kDefaultRrfK` — Reciprocal
//     Rank Fusion (pure function, spec § 6.2). Takes one ranked
//     `List<NodeId>` per `RecallMode` and returns the descending-
//     score fused list. Default `k_rrf = 60`. The fusion stage runs
//     after the mode executors and before the diversifier (A.58).
//   - `mmrDiversify`, `MmrInput`, `MmrSelected`, `kDefaultMmrLambda`
//     — Maximal Marginal Relevance diversifier (pure function,
//     spec § 6.2). Generic over the candidate item type; takes a
//     caller-supplied similarity callback. Default `λ = 0.7`. Runs
//     after RRF and before the optional re-rank hook (A.59).
//   - `RecallExecutor` — the recall-pipeline orchestrator (A.59).
//     Dispatches the four-mode executors, fuses with `rrfFuse`,
//     diversifies with `mmrDiversify`, optionally invokes the
//     caller-supplied `ReRankHook`, materialises nodes via
//     `NodeReader.getMany`, and populates the `RecallReport` cost
//     breakdown. The full `TomBrainMemory.recall` wrapper (event
//     stream, observability hooks) lands in a later Phase A step;
//     `RecallExecutor` is the testable composition core.
//
// Wiring across later Phase A steps:
//
//   - A.62 — graph-walk-mode test bench (cycle safety, depth bound,
//     mixed-edge walks). The mode itself lands at A.61 and exports
//     `GraphWalkRecall` / `GraphWalkRecallCandidate` here.

export 'bm25_recall.dart' show Bm25Recall, Bm25RecallCandidate;
export 'fts5_catalog.dart' show Fts5Catalog;
export 'fts5_writer.dart' show Fts5Writer;
export 'graph_walk_recall.dart'
    show GraphWalkRecall, GraphWalkRecallCandidate, kDefaultEdgeTypeWeight;
export 'recall_executor.dart'
    show
        Bm25ModeFn,
        GraphWalkModeFn,
        NodeBulkReader,
        RecallExecutor,
        SymbolicModeFn,
        VectorModeFn;
export 'recall_query.dart'
    show
        AttrClause,
        DiversityPolicy,
        DiversityStrategy,
        FusionPolicy,
        FusionStrategy,
        GraphWalkPolicy,
        RecallBudget,
        RecallMode,
        RecallQuery,
        ReRankHook,
        SymbolicFilter,
        SymbolicOp;
export 'recall_result.dart' show RecallReport, RecallResult;
export 'mmr.dart'
    show MmrInput, MmrSelected, kDefaultMmrLambda, mmrDiversify;
export 'rrf.dart' show RrfFusedCandidate, kDefaultRrfK, rrfFuse;
export 'stream_query.dart' show StreamCursor, StreamQuery;
export 'symbolic_recall.dart'
    show
        CompiledSymbolicFilter,
        SymbolicRecall,
        SymbolicRecallCandidate,
        compileSymbolicFilter;
export 'vector_recall.dart' show VectorRecall, VectorRecallCandidate;
