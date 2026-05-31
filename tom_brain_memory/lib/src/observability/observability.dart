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
// Future steps may add categories (A.85+ stats / events surface,
// later phases for cognitive agents, classification, MCP write
// subset). New categories are added by editing the enum + the
// matching static in `memory_log.dart`; ad-hoc string categories are
// not supported on purpose.

export 'memory_log.dart' show MemoryLog, MemoryLogCategory;
