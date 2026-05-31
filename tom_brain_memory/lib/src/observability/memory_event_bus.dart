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

import 'dart:async';

import '../api/memory_event.dart';

/// Central fan-in for `MemoryEvent`s emitted across the memory
/// subsystem.
///
/// One bus per open `SqliteTomBrainMemory`. The composition root
/// constructs the bus, hands `bus.emit` to every per-subsystem
/// writer's `eventSink` parameter, and exposes `bus.events()` as
/// the `TomBrainMemoryClient.events()` return.
///
/// Lifecycle: `emit` is legal up until `close()`; after `close()`
/// `emit` throws `StateError` and `events()` subscribers receive a
/// done-stream.
final class MemoryEventBus {
  /// The backing broadcast controller.
  ///
  /// `sync: false` is the default; we name it explicitly to make the
  /// design choice visible. Asynchronous emission keeps the producer
  /// call stack short and prevents a slow subscriber from stalling a
  /// SQLite-transaction-wrapped writer.
  final StreamController<MemoryEvent> _controller =
      StreamController<MemoryEvent>.broadcast(sync: false);

  /// `true` once [close] has been called. After close, [emit] throws
  /// and the broadcast stream is in its done state.
  bool _closed = false;

  /// Whether this bus has been closed.
  bool get isClosed => _closed;

  /// Emits [event] to every current subscriber.
  ///
  /// Asynchronous: the call enqueues the event on the controller and
  /// returns. Subscribers see the event on a future microtask, not
  /// inside the producer's call stack.
  ///
  /// Throws `StateError` if the bus has been closed. Producers that
  /// race with shutdown should guard with [isClosed] — but the
  /// expected pattern is that the composition root closes the bus
  /// *after* every per-subsystem writer is quiesced, so the race
  /// should not happen in practice.
  void emit(MemoryEvent event) {
    if (_closed) {
      throw StateError(
        'MemoryEventBus.emit called after close (event kind=${event.kind})',
      );
    }
    _controller.add(event);
  }

  /// Returns the typed event stream.
  ///
  /// Broadcast — multiple subscribers see every event. Subscriptions
  /// can come and go; missed events stay missed (this is an
  /// observability stream, not a durable queue).
  ///
  /// Each call returns the *same* underlying stream; subscribing
  /// multiple times produces multiple independent subscriptions, not
  /// duplicate views of the same one. This matches
  /// `StreamController.broadcast()` semantics.
  Stream<MemoryEvent> events() => _controller.stream;

  /// Closes the bus.
  ///
  /// Subsequent [emit] calls throw `StateError`; live subscribers
  /// receive a done event and any `await for` loop over
  /// [events] terminates.
  ///
  /// Idempotent — calling `close` on an already-closed bus succeeds
  /// and returns immediately.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
