// Barrel for the `history/` module (Plan step G.21; hub spec § 22.4).
//
// The engine-side half of conversation-history compaction: the
// `HistoryCompactor` that folds a session's `pending` batch into its bounded
// `compactedSummary` via the `compact_history_v1` substrate call, plus the
// assembled-prompt / result / outcome value types and the note categories it
// records. The `ConversationHistory` store the compactor reads + mutates lives
// in `tom_brain_shared` (two components, one contract); the substrate call is
// an injectable seam wired through `sub.llm` at G.23.
export 'history_compaction_template.dart'
    show
        HistoryCompactionTemplate,
        HistoryCompactionTemplateMissing,
        HistoryCompactionTemplateStore;
export 'history_compactor.dart'
    show
        HistoryCompactionOutcome,
        HistoryCompactionPrompt,
        HistoryCompactionResult,
        HistoryCompactionSubstrate,
        HistoryCompactor,
        defaultCompactionTemplate,
        historyCompactionFailedCategory,
        historyCompactionTruncatedCategory;
