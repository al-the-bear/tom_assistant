// Barrel for the `obs/` module (Plan step B.37).
//
// Owns the package-level logging surface — a thin, category-tagged
// wrapper over the global `tomLog` instance from `tom_basics`. See
// `substrate_log.dart` for the design rationale and the six categories
// spec § 10.1 names.
//
// B.37 — `substrate_log.dart`: `SubstrateLogCategory` (the closed enum
// of six categories — `tom_brain.substrate.llm`, `…roles`, `…embed`,
// `…web`, `…mcp`, `…router`) and `SubstrateLog` (the const-instance
// facade with the six `SubstrateLog.<area>` statics). Call sites use
// `SubstrateLog.llm.status('…')`, `SubstrateLog.router.warn('…')`,
// etc.; the wrapper prepends `'[tom_brain.substrate.<area>] '` and
// forwards to `tomLog`.
//
// Spec-vs-plan note: plan step B.37 lists five categories
// (`llm` / `roles` / `embed` / `web` / `mcp`); spec § 10.1 lists six
// (the same five plus `router`). The wrapper includes all six — the
// spec is authoritative and the router subsystem (B.18+) is a
// first-class category. See Q-B.37.1 in
// `prototype_implementation_questions.md`.
//
// Future steps may add categories. New categories are added by editing
// the enum + the matching static in `substrate_log.dart`; ad-hoc
// string categories are not supported on purpose.
//
// B.38 — `substrate_event_bus.dart`: `SubstrateEventBus`, the central
// broadcast `Stream<SubstrateEvent>` that `TomBrainSubstrateClient.
// events()` returns. The composition root hands `bus.emit` to every
// per-subsystem emitter (router, providers, embedding service, web
// tools, MCP client) so every emission lands on the same fan-out
// point. Mirrors `MemoryEventBus` (A.85) exactly in shape; the only
// intentional divergence is the event-base type.
//
// Spec-vs-plan note (B.38): plan step B.38 names five subtypes
// (`LlmCallStarted`, `LlmCallCompleted`, `ProviderFailover`,
// `EmbeddingComputed`, `WebFetchCompleted`); spec § 10.2 names
// twelve (the same five plus seven more — the sealed sum in
// `api/substrate_event.dart`). The bus is typed on the abstract
// base, so the same controller fans every variant out without any
// per-variant code. The divergence is locked in the tests
// (`b38_substrate_event_bus_test.dart`), not in the bus itself.
// See Q-B.38.1 in `prototype_implementation_questions.md`.
//
// Pending B.38 follow-ups:
//
//   - B.39 will pair behavioural tests (config roundtrip + event
//     ordering + logger categorisation) around the full
//     observability triple (logger + events + stats).
//   - The third leg of the triple (`SubstrateStats` collection
//     surface mirroring `MemoryStatsCollector` from A.85) is not
//     listed as a separate plan step at B.38; it lands when the
//     B.40+ facade needs to populate the stats snapshot. The
//     `SubstrateStats` value class itself already exists at B.9
//     (`api/substrate_stats.dart`) — the collector is the missing
//     piece.

export 'substrate_event_bus.dart' show SubstrateEventBus;
export 'substrate_log.dart' show SubstrateLog, SubstrateLogCategory;
