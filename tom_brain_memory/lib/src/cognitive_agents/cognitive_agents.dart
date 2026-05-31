// Barrel for the `cognitive_agents/` module.
//
// Owns the cognitive-agent infrastructure surfaces — the typed
// shaking-event family (spec § 9.4 / § 16), the emitter helper
// agents use to raise events onto memory's `events()` stream, and
// the in-process per-agent registry (spec § 9.5) consulted by
// every guarded write.
//
// Wiring across Phase A steps:
//
//   - A.69 ✅ — `ShakingEvent` sealed base + the four sub-kinds
//     (`ContradictionDetected`, `CentroidDriftDetected`,
//     `RetrievalConflict`, `CritiqueRejected`) and the
//     `ShakingEventEmitter` helper.
//   - A.70 ✅ — `AgentRegistry` and the `AgentScopeViolation`
//     exception that `NodePersister`, `EdgeWriter`, and
//     `SqliteStackApi` raise when a write fails the registered
//     agent's `writeScopes` check. The `AgentRegistration` value
//     type lives in `tom_brain_shared` so the dispatcher and the
//     procedure-author role can consume it without depending on
//     memory.
//
// The detection sites for the three memory-internal shaking
// sub-kinds live in their owning modules:
//
//   - `ContradictionDetected` — `lib/src/edges/edge_writer.dart`
//   - `CentroidDriftDetected` — `lib/src/classification/centroid_store.dart`
//   - `RetrievalConflict` — `lib/src/retrieval/recall_executor.dart`
//
// `CritiqueRejected` is agent-raised — see the file header on
// `shaking_events.dart` and Q-A.69.4 in
// `_ai/quests/tom_brain/prototype_implementation_questions.md`.
//
// The scope-enforcement call sites for the per-agent registry
// (A.70) live in the same three modules plus the stack api:
//
//   - node-write guard — `lib/src/nodes/node_persister.dart`
//   - edge-write guard — `lib/src/edges/edge_writer.dart`
//   - stack-push guard — `lib/src/stacks/sqlite_stack_api.dart`

export 'agent_registry.dart' show AgentRegistry;
export 'agent_scope_violation.dart'
    show AgentScopeViolation, AgentScopeViolationKind;
export 'shaking_event_emitter.dart' show ShakingEventEmitter;
export 'shaking_events.dart'
    show
        CentroidDriftDetected,
        ContradictionDetected,
        CritiqueRejected,
        RetrievalConflict,
        ShakingEvent;
