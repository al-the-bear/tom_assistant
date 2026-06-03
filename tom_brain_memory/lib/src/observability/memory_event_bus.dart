// MemoryEventBus — central fan-in for `MemoryEvent`s emitted across
// the memory subsystem (Plan step A.85; spec § 3.1
// `TomBrainMemory.events()`, spec § 16 observability surface).
//
// What this file owns:
//
//   - A `StreamController<MemoryEvent>.broadcast()` that fans every
//     emission out to every subscriber.
//   - The `void Function(MemoryEvent)` sink that the per-subsystem
//     writers (NodePersister, EdgeWriter, RecallExecutor,
//     SqliteStackApi, SqliteTrailStore, Classifier, …) take as
//     their `eventSink` constructor argument. The composition root
//     (`SqliteTomBrainMemory` once it lands) hands `bus.emit` to
//     every component so every event lands on the same controller.
//   - The `Stream<MemoryEvent>` returned from
//     `TomBrainMemoryClient.events()`.
//
// What this file does NOT own:
//
//   - The events themselves. `MemoryEvent` and its leaves live in the
//     subsystems that produce them (`nodes/node_events.dart`,
//     `stacks/stack_events.dart`, `trails/trail_events.dart`,
//     `cognitive_agents/shaking_events.dart`, …).
//
//   - Filtering. Subscribers filter with
//     `bus.events().where((e) => e is ShakingEvent)`. Pushing typed
//     filters into the bus would tie it to the event taxonomy and
//     turn every new leaf into an interface edit.
//
//   - Persistence. Events are observed live; the trail subsystem
//     (separately) persists the entries that matter for replay.
//
// Design choices (matches the spec's "consumers vary, producers
// don't" framing):
//
//   - **Broadcast**, not single-subscription. Multiple observers can
//     subscribe simultaneously — the dispatcher feeds
//     `dream_reconsolidate_v1` from `ShakingEvent`s; the Forge
//     brain inspector reads everything for the operator UI; tests
//     subscribe for assertions. A single-subscription controller
//     would let any one of those starve the others.
//   - **Asynchronous** (`sync: false`). Emission is a constant-time
//     enqueue, not an O(observers) fan-out under the producer's
//     lock. This matters because some producers (NodePersister,
//     EdgeWriter) emit inside a SQLite transaction; a slow
//     subscriber must never block the write path.
//   - **Closed after `close()`**. Subsequent `emit` calls throw
//     `StateError`; subsequent `events()` subscribers get a
//     done-stream. The composition root closes the bus during
//     `TomBrainMemory.close()` so the dispatcher's `await for`
//     loops terminate cleanly.
//   - **No back-pressure across the bus**. Broadcast streams in
//     dart:async do not implement back-pressure; a slow subscriber
//     drops nothing but does fall behind. The agreed posture is
//     "events are an observability stream, not a queue" — if a
//     subscriber needs durability it reads trails. This matches the
//     posture documented on `MemoryEvent` and on `BrainEvent`.

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Central fan-in for `MemoryEvent`s emitted across the memory
/// subsystem.
///
/// One bus per open `SqliteTomBrainMemory`. The composition root
/// constructs the bus, hands `bus.emit` to every per-subsystem
/// writer's `eventSink` parameter, and exposes `bus.events()` as
/// the `TomBrainMemoryClient.events()` return.
///
/// Lifecycle, broadcast/async semantics, and the closed-after-close
/// guard all live in the shared [BrainEventBus] (B.2.1) — this is the
/// element-bound subclass for `MemoryEvent`.
final class MemoryEventBus extends BrainEventBus<MemoryEvent> {
  MemoryEventBus() : super(busLabel: 'MemoryEventBus');
}
