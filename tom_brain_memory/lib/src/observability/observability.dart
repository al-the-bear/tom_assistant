// Barrel for the `observability/` module (Plan step A.84).
//
// Owns the package-level logging surface — a thin, category-tagged
// wrapper over the global `tomLog` instance from `tom_basics`. See
// `memory_log.dart` for the design rationale and the six categories
// the plan names.
//
// A.84 — `memory_log.dart`: `MemoryLogCategory` (the closed enum of
// six categories — `tom_brain.memory.store`, `…retrieval`, `…stacks`,
// `…trail`, `…mcp`, `…isolate`) and `MemoryLog` (the const-instance
// facade with the six `MemoryLog.<area>` statics). Call sites use
// `MemoryLog.store.status('…')`, `MemoryLog.retrieval.debug('…')`,
// etc.; the wrapper prepends `'[tom_brain.memory.<area>] '` and
// forwards to `tomLog`.
//
// Future steps may add categories (later phases for cognitive agents,
// classification, MCP write subset). New categories are added by
// editing the enum + the matching static in `memory_log.dart`; ad-hoc
// string categories are not supported on purpose.
//
// A.85 — `memory_event_bus.dart`: `MemoryEventBus`, the central
// broadcast `Stream<MemoryEvent>` that `TomBrainMemoryClient.events()`
// returns. The composition root hands `bus.emit` to every per-
// subsystem writer (`NodePersister`, `EdgeWriter`, `RecallExecutor`,
// `SqliteStackApi`, `SqliteTrailStore`, `Classifier`, …) so every
// emission lands on the same fan-out point.
//
// A.85 — `recall_latency_tracker.dart`: per-mode p50/p95 latency
// aggregator that feeds `MemoryStats.recallLatencyPerMode`.
//
// A.85 — `classification_confidence_tracker.dart`: ten-bucket
// histogram of best-similarity values, feeds
// `MemoryStats.classificationConfidenceHistogram`.
//
// A.85 — `memory_stats_collector.dart`: assembles `MemoryStats`
// from pluggable per-slice source callbacks supplied by the
// composition root.

export 'classification_confidence_tracker.dart'
    show ClassificationConfidenceTracker;
export 'memory_event_bus.dart' show MemoryEventBus;
export 'memory_log.dart' show MemoryLog, MemoryLogCategory;
export 'memory_stats_collector.dart'
    show
        DoubleMapSource,
        IntMapSource,
        IntSource,
        LatencyMapSource,
        MemoryStatsCollector;
export 'recall_latency_tracker.dart' show RecallLatencyTracker;
