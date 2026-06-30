// memory/ module — the consumer-facing memory interface and its value
// types, hoisted out of `tom_brain_memory` at A.88 (todo #16,
// Q-A.88.4).
//
// Why these live in shared: every Tom Brain component that talks to
// memory (the substrate via web tools, the procedure engine via the
// bridged `recall` / `persist` primitives, the Phase-D dispatcher as a
// primitive-act pass-through, the Phase-E access edge) needs the
// `TomBrainMemoryClient` contract and the value types it traffics in —
// without taking a runtime dependency on `tom_brain_memory`, which
// pulls `sqlite3` and `dart_mcp`. The concrete implementations
// (`SqliteTomBrainMemory`, the isolate host/client, the SQL compilers,
// the stores) stay in `tom_brain_memory`.
//
// This barrel carries only pure value types and abstract surfaces.
// `MemoryConfig`'s filesystem path getters need `dart:io`, so they
// stay in `tom_brain_memory` on the `MemoryConfigPaths` extension.

// api/ — the consumer-facing contract + observability / scope value types.
export 'api/memory_event.dart' show MemoryEvent;
export 'api/memory_profile_registry.dart' show MemoryProfileRegistry;
export 'api/memory_stats.dart' show LatencyHistogram, MemoryStats;
export 'api/scope.dart'
    show DemotionReason, ForgetReason, PromotionReason, Scope;
export 'api/tom_brain_memory_client.dart' show TomBrainMemoryClient;

// classification/ — `classify` result triad.
export 'classification/classification_result.dart'
    show ClassificationDecision, ClassificationResult, ClassificationTarget;

// config/ — root config record + sub-config value types (no `dart:io`).
export 'config/aggregation_config.dart'
    show AggregationConfig, defaultAggregationNodeTypes;
export 'config/memory_config.dart'
    show
        BudgetsConfig,
        ClassificationConfig,
        DecayConfig,
        DecayDemoteConfig,
        DefaultWriteBudgetConfig,
        McpServerConfig,
        MemoryConfig,
        RankingConfig,
        ReplicationConfig,
        ReplicationRole,
        RetrievalConfig,
        SqliteVecConfig,
        TrailsConfig;
export 'config/profile_name.dart'
    show
        defaultMemoryProfile,
        isReservedGlobalProfile,
        isValidMemoryProfileName,
        reservedGlobalProfile,
        validateMemoryProfileName;

// edges/ — read-side edge record + the closed 12-edge alphabet.
export 'edges/edge.dart' show Edge;
export 'edges/edge_type.dart' show EdgeDirection, EdgeType;

// migrations/ — forward-only migration surface + cursor / status records.
export 'migrations/migration_api.dart'
    show MigrationApi, MigrationCursor, MigrationDecl, MigrationStatus;

// nodes/ — read/write node records + node-type schema-and-policy decl.
export 'nodes/node.dart' show Node, NodeDraft, NodeStatus;
export 'nodes/node_type_decl.dart'
    show
        EmbeddingPolicy,
        FieldSpec,
        FieldType,
        IndexPolicy,
        NodeTypeDecl,
        RetentionPolicy;

// retrieval/ — recall query input, result records, and stream cursor.
export 'retrieval/recall_query.dart'
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
        RecallRanking,
        ReRankHook,
        SymbolicFilter,
        SymbolicOp;
export 'retrieval/multi_recall_query.dart' show MultiRecallQuery, RecallSeed;
export 'retrieval/recall_result.dart'
    show RecallProvenanceEntry, RecallReport, RecallResult;
export 'retrieval/stream_query.dart' show StreamCursor, StreamQuery;

// stacks/ — the mind-state CRUD surface + its value-type shapes.
export 'stacks/stack_api.dart' show StackApi;
export 'stacks/stack_types.dart'
    show
        PriorityPolicyKind,
        RetentionPolicyKind,
        StackDecl,
        StackEntry,
        StackEntryStatus,
        StackEvent,
        StackEventKind,
        StackInfo,
        StackPolicy,
        StackSummary;

// trails/ — procedure-run trail records.
export 'trails/trail.dart'
    show
        ProcedureRunRef,
        TrailEntry,
        TrailEntryKind,
        TrailOutcome,
        TrailOutcomeStatus;
