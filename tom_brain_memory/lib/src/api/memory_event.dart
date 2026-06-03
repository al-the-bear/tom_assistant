// MemoryEvent — typed observability events emitted by memory
// (memory_specification.md § 16).
//
// `MemoryEvent` is the memory-side base for the cross-component
// `BrainEvent` family declared in `tom_brain_shared`. The concrete
// leaves (NodePersisted, EdgeRejected, RecallCompleted,
// ShakingEvent, …) land at A.38; A.24 only declares the base so
// the abstract `TomBrainMemory.events()` stream has a typed
// element.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// Base class for every event memory emits.
///
/// Subclasses (NodePersisted, EdgeCreated, EdgeRejected,
/// StackPushed, StackPopped, StackOverflow, TrailOpened,
/// TrailEntryAppended, TrailClosed, TrailEntryCorrupted,
/// RecallCompleted, ClassificationComputed, CentroidUpdated,
/// MigrationProgressed, ShakingEvent, AuthorityUnreachable) live in
/// their owning sub-modules and arrive incrementally across Phase A.
///
/// Leaves landed so far:
///   * A.33 — `NodeTypeRegistered`
///   * A.34 — `NodePersisted`
///   * A.36 — `EdgeCreated`, `EdgeRejected`
///   * A.38 — `NodeDemoted`, `NodeForgotten` (the remaining
///     node-lifecycle leaves; rounds out the set Plan step A.38
///     committed to emitting)
///   * A.69 — `ShakingEvent` sealed family + the four sub-kinds
///     (`ContradictionDetected`, `CentroidDriftDetected`,
///     `RetrievalConflict`, `CritiqueRejected`) named in spec § 9.4 /
///     § 16. The three memory-internal sub-kinds are emitted by the
///     edge writer, the centroid store, and the recall executor;
///     `CritiqueRejected` is agent-raised via `ShakingEventEmitter`.
///   * Q-A.87.8 — the five remaining spec § 16 leaves:
///     `RecallCompleted` (recall executor), `ClassificationComputed`
///     (classifier), `CentroidUpdated` (centroid store),
///     `MigrationProgressed` (migration api), and
///     `AuthorityUnreachable`. The first four are wired to their
///     producers; `AuthorityUnreachable` is declared but not yet
///     emitted — its producer (the multi-machine heartbeat monitor,
///     build step 9) has not shipped, so the type is landed ahead of
///     the emission path the way `StackOverflowDemoted` was.
///
/// The `kind` discriminator convention for memory events is
/// `memory.<event-name>`, kebab-cased (e.g. `memory.node-persisted`).
abstract class MemoryEvent extends BrainEvent {
  const MemoryEvent({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });
}
