// Barrel for the `retrieval/` module (A.23 layout; A.24 surface).
//
// At A.24 this barrel exports:
//
//   - `RecallQuery` — input record for `TomBrainMemory.recall`,
//     plus `RecallMode`, `SymbolicFilter`, `AttrClause`,
//     `SymbolicOp`, `RecallBudget`, `FusionPolicy`,
//     `FusionStrategy`, `DiversityPolicy`, `DiversityStrategy`,
//     and the `ReRankHook` typedef.
//   - `RecallResult`, `RecallReport` — output record + cost
//     breakdown.
//   - `StreamQuery`, `StreamCursor` — cursor-backed bulk iteration.
//
// Wiring across later Phase A steps:
//
//   - A.54 – A.59 — single-mode executors, fusion, diversity,
//     `RecallReport` population.
//   - A.61 – A.62 — graph-walk mode + symbolic filter compiler.

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
