// Barrel for the `retrieval/` module.
//
// As of A.55 this barrel exports:
//
//   - `RecallQuery` — input record for `TomBrainMemory.recall`,
//     plus `RecallMode`, `SymbolicFilter`, `AttrClause`,
//     `SymbolicOp`, `RecallBudget`, `FusionPolicy`,
//     `FusionStrategy`, `DiversityPolicy`, `DiversityStrategy`,
//     and the `ReRankHook` typedef.
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
//
// Wiring across later Phase A steps:
//
//   - A.56 – A.59 — symbolic / fusion / diversity, and
//     `RecallReport` population.
//   - A.61 – A.62 — graph-walk mode + symbolic filter compiler.

export 'bm25_recall.dart' show Bm25Recall, Bm25RecallCandidate;
export 'fts5_catalog.dart' show Fts5Catalog;
export 'fts5_writer.dart' show Fts5Writer;
export 'recall_query.dart'
    show
        AttrClause,
        DiversityPolicy,
        DiversityStrategy,
        FusionPolicy,
        FusionStrategy,
        RecallBudget,
        RecallMode,
        RecallQuery,
        ReRankHook,
        SymbolicFilter,
        SymbolicOp;
export 'recall_result.dart' show RecallReport, RecallResult;
export 'stream_query.dart' show StreamCursor, StreamQuery;
export 'vector_recall.dart' show VectorRecall, VectorRecallCandidate;
