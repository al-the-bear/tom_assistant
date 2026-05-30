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
/// MigrationProgressed, ShakingEvent, VectorIndexUnavailable,
/// AuthorityUnreachable) live in their owning sub-modules and
/// arrive incrementally across Phase A.
///
/// Leaves landed so far:
///   * A.33 — `NodeTypeRegistered`
///   * A.34 — `NodePersisted`
///   * A.36 — `EdgeCreated`, `EdgeRejected`
///   * A.38 — `NodeDemoted`, `NodeForgotten` (the remaining
///     node-lifecycle leaves; rounds out the set Plan step A.38
///     committed to emitting)
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
