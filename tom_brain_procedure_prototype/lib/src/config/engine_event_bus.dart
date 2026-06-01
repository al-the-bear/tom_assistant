// C.44 — `EngineEventBus`: central fan-in for `EngineEvent`s emitted
// across the engine (spec § 13 observability surface).
//
// What this file owns:
//
//   - A `StreamController<EngineEvent>.broadcast()` that fans every
//     emission out to every subscriber.
//   - The `void Function(EngineEvent)` sink (`emit`) that the engine's
//     lifecycle points call. The composition root (Phase D's
//     `BrainProcessBoot`) hands `bus.emit` to the `ProcedureEngine` so
//     every lifecycle moment lands on the same controller — mirroring
//     how substrate wires `bus.emit` to its producers at its
//     `InProcessTomBrainSubstrate` root (B.40+). See Q-C.44.1.
//   - The `Stream<EngineEvent>` returned from [events].
//
// What this file does NOT own:
//
//   - The events themselves. `EngineEvent` and its five leaves live in
//     `engine_event.dart` (C.44 sealed sum). Adding a new leaf is an
//     `engine_event.dart` edit; the bus stays generic in `EngineEvent`.
//   - Filtering. Subscribers filter with
//     `bus.events().where((e) => e is InvocationCompleted)`.
//   - Persistence. Events are observed live; the run recorder
//     (`recorder/`) persists the trail entries that survive for replay.
//     The bus is observability-only — it holds no history.
//
// Design choices (a direct mirror of substrate's `SubstrateEventBus`
// at plan step B.38, itself a mirror of memory's `MemoryEventBus` at
// A.85 — same "consumers vary, producers don't" framing):
//
//   - **Broadcast**, not single-subscription. Multiple observers (the
//     dispatcher trail, the Forge procedure-run inspector, tests) can
//     subscribe simultaneously; one slow observer must not starve the
//     others.
//   - **Asynchronous** (`sync: false`). Emission is a constant-time
//     enqueue, not an O(observers) fan-out under the producer's lock —
//     the engine emits inside the run pipeline and must not stall on a
//     slow subscriber.
//   - **Closed after `close()`**. Subsequent `emit` calls throw
//     `StateError`; subsequent subscribers get a done-stream. The
//     composition root closes the bus during shutdown so `await for`
//     loops terminate cleanly.
//   - **No back-pressure**. Broadcast streams in `dart:async` do not
//     implement back-pressure; a slow subscriber falls behind but drops
//     nothing structurally. Events are an observability stream, not a
//     durable queue — durability lives in the trail on the memory side.
//     This matches the posture on `BrainEvent`, `MemoryEventBus`, and
//     `SubstrateEventBus`.

import 'dart:async';

import 'engine_event.dart';

/// Central fan-in for `EngineEvent`s emitted across the engine.
///
/// One bus per running engine. The composition root constructs the bus,
/// hands `bus.emit` to the `ProcedureEngine`, and exposes `bus.events()`
/// to observers.
///
/// Lifecycle: [emit] is legal up until [close]; after [close] [emit]
/// throws `StateError` and [events] subscribers receive a done-stream.
///
/// Shape mirror of `SubstrateEventBus` (B.38) / `MemoryEventBus` (A.85).
/// Two reasons: (i) zero design risk — the pattern has shipped twice and
/// is exercised by every test that goes through an emitter; (ii) zero
/// divergence cost — a reader who has read one bus has read all three.
/// The only intentional divergence is the event-base type (`EngineEvent`
/// vs `SubstrateEvent` / `MemoryEvent`).
final class EngineEventBus {
  /// The backing broadcast controller.
  ///
  /// `sync: false` is the default; named explicitly to make the design
  /// choice visible. Asynchronous emission keeps the engine's run-pipeline
  /// call stack short and prevents a slow subscriber from stalling a
  /// lifecycle emit site.
  final StreamController<EngineEvent> _controller =
      StreamController<EngineEvent>.broadcast(sync: false);

  /// `true` once [close] has been called.
  bool _closed = false;

  /// Whether this bus has been closed.
  bool get isClosed => _closed;

  /// Emits [event] to every current subscriber.
  ///
  /// Asynchronous: the call enqueues the event on the controller and
  /// returns. Subscribers see the event on a future microtask, not
  /// inside the producer's call stack.
  ///
  /// Throws `StateError` if the bus has been closed. The expected
  /// pattern is that the composition root closes the bus *after* the
  /// engine is quiesced, so the race should not happen in practice;
  /// producers that race shutdown should guard with [isClosed].
  void emit(EngineEvent event) {
    if (_closed) {
      throw StateError(
        'EngineEventBus.emit called after close (event kind=${event.kind})',
      );
    }
    _controller.add(event);
  }

  /// Returns the typed event stream.
  ///
  /// Broadcast — multiple subscribers see every event. Subscriptions can
  /// come and go; missed events stay missed (this is an observability
  /// stream, not a durable queue).
  ///
  /// Each call returns the *same* underlying stream; subscribing multiple
  /// times produces multiple independent subscriptions. This matches
  /// `StreamController.broadcast()` semantics.
  Stream<EngineEvent> events() => _controller.stream;

  /// Closes the bus.
  ///
  /// Subsequent [emit] calls throw `StateError`; live subscribers receive
  /// a done event and any `await for` loop over [events] terminates.
  ///
  /// Idempotent — calling `close` on an already-closed bus returns
  /// immediately.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
