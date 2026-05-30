// Barrel for the `cognitive_agents/` module.
//
// Owns the cognitive-agent infrastructure surfaces — the typed
// shaking-event family (spec § 9.4 / § 16) and the emitter helper
// agents use to raise events onto memory's `events()` stream.
//
// Wiring across Phase A steps:
//
//   - A.69 ✅ — `ShakingEvent` sealed base + the four sub-kinds
//     (`ContradictionDetected`, `CentroidDriftDetected`,
//     `RetrievalConflict`, `CritiqueRejected`) and the
//     `ShakingEventEmitter` helper.
//   - A.70 — `AgentRegistration` and read/write scope enforcement.
//
// The detection sites for the three memory-internal sub-kinds live
// in their owning modules:
//
//   - `ContradictionDetected` — `lib/src/edges/edge_writer.dart`
//   - `CentroidDriftDetected` — `lib/src/classification/centroid_store.dart`
//   - `RetrievalConflict` — `lib/src/retrieval/recall_executor.dart`
//
// `CritiqueRejected` is agent-raised — see the file header on
// `shaking_events.dart` and Q-A.69.4 in
// `_ai/quests/tom_brain/prototype_implementation_questions.md`.

export 'shaking_event_emitter.dart' show ShakingEventEmitter;
export 'shaking_events.dart'
    show
        CentroidDriftDetected,
        ContradictionDetected,
        CritiqueRejected,
        RetrievalConflict,
        ShakingEvent;
