// `BrainEventBus<E>` — the generic broadcast fan-in for typed
// observability events (B.2.1 consolidation).
//
// Five Tom Brain components independently grew a verbatim shape-mirror
// of the same broadcast bus:
//
//   * `tom_brain_substrate`            — `SubstrateEventBus` (B.38)
//   * `tom_brain_memory`               — `MemoryEventBus` (A.85)
//   * `tom_brain_procedure`  — `EngineEventBus` (C.44) and
//                                        `DispatcherEventBus`
//   * `tom_brain_access`     — `AccessEventBus`
//
// Each was a `StreamController<E>.broadcast(sync: false)` plus an
// `emit` / `events` / `close` / `isClosed` surface and a closed-after-
// close guard, differing only in the element type and the bus label in
// the emit-after-close `StateError`. The prototype-review (B.1 / B.2.1)
// named this "the single highest-value cross-project extraction". This
// file is the one generic; each component keeps its named bus as a thin
// `final` subclass that binds the element type and supplies its label,
// so every existing construction site (`SubstrateEventBus()`,
// `MemoryEventBus()`, …) is unchanged.
//
// Design choices (carried verbatim from the five mirrors so the promoted
// generic is behaviourally identical):
//
//   - **Broadcast**, not single-subscription. Multiple observers
//     subscribe simultaneously (trail writers, the Forge inspector,
//     tests, watchdogs). A single-subscription controller would let any
//     one starve the others.
//
//   - **Asynchronous** (`sync: false`). Emission is a constant-time
//     enqueue, never an O(observers) fan-out under the producer's lock.
//     Producers emit inside tight inner loops (router rotation,
//     streaming chunk fan-out, embedding batch fan-out); a slow
//     subscriber must never block the call path.
//
//   - **Closed after `close()`**. Subsequent `emit` throws `StateError`;
//     subsequent `events()` subscribers get a done-stream. The
//     composition root closes the bus after every emitter is quiesced so
//     `await for` loops terminate cleanly. `close` is idempotent.
//
//   - **No back-pressure**. Broadcast streams in `dart:async` do not
//     implement back-pressure; a slow subscriber falls behind but drops
//     nothing. Events are an observability stream, not a durable queue —
//     durability lives in the memory-side trails.
//
// The base type is [BrainEvent]; the `kind` discriminator it requires is
// what the emit-after-close message reports, so the diagnostic names both
// the bus and the offending event in every component.

import 'dart:async';

import 'brain_event.dart';

/// Generic broadcast fan-in for [BrainEvent] subtypes.
///
/// `base` so each component can extend it with a named, element-bound
/// subclass (`SubstrateEventBus extends BrainEventBus<SubstrateEvent>`)
/// while no foreign library can `implements` it and diverge from the
/// broadcast contract.
///
/// Lifecycle: [emit] is legal up until [close]; after [close] [emit]
/// throws `StateError` and [events] subscribers receive a done-stream.
base class BrainEventBus<E extends BrainEvent> {
  /// Human-readable bus name used in the emit-after-close diagnostic
  /// (e.g. `SubstrateEventBus`). Supplied by the concrete subclass so
  /// the message names the component the producer was talking to.
  final String _busLabel;

  /// The backing broadcast controller. `sync: false` keeps the producer
  /// call stack short — see the file header for why this matters.
  final StreamController<E> _controller =
      StreamController<E>.broadcast(sync: false);

  /// `true` once [close] has been called.
  bool _closed = false;

  BrainEventBus({required String busLabel}) : _busLabel = busLabel;

  /// Whether this bus has been closed.
  bool get isClosed => _closed;

  /// Emits [event] to every current subscriber.
  ///
  /// Asynchronous: the call enqueues the event and returns; subscribers
  /// see it on a later microtask, not inside the producer's call stack.
  ///
  /// Throws `StateError` if the bus has been closed. The message names
  /// the bus ([_busLabel]) and the event's [BrainEvent.kind].
  void emit(E event) {
    if (_closed) {
      throw StateError(
        '$_busLabel.emit called after close (event kind=${event.kind})',
      );
    }
    _controller.add(event);
  }

  /// Returns the typed event stream.
  ///
  /// Broadcast — multiple subscribers see every event. Subscriptions can
  /// come and go; missed events stay missed (observability, not a durable
  /// queue). Each call returns the same underlying stream; subscribing
  /// multiple times yields independent subscriptions.
  Stream<E> events() => _controller.stream;

  /// Closes the bus.
  ///
  /// Subsequent [emit] calls throw `StateError`; live subscribers receive
  /// a done event and any `await for` over [events] terminates.
  /// Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
