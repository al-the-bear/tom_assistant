// AccessEventBus — the central fan-in for `AccessEvent`s emitted across the
// access edge (E.41; proto spec § 13.2).
//
// Shape mirror of `DispatcherEventBus` (D.49), itself a mirror of
// `EngineEventBus` (C.44) / `SubstrateEventBus` (B.38) / `MemoryEventBus`
// (A.85). The only intentional divergence is the event-base type
// (`AccessEvent` vs `DispatcherEvent`). Two reasons for the verbatim copy:
// (i) zero design risk — the pattern has shipped five times; (ii) zero
// divergence cost — a reader who has read one bus has read all of them.
//
// What this file owns:
//
//   - A `StreamController<AccessEvent>.broadcast(sync: false)` that fans
//     every emission out to every subscriber.
//   - The `void Function(AccessEvent)` sink ([emit]) the access edge's
//     lifecycle points call. Boot hands `bus.emit` to the `AccessAssembler`
//     (which emits `AccessCreated` / `AccessFailed`) and to the
//     `DeliveryRegistry`'s `onDelivered` sink (which emits `AccessDelivered`
//     on the final chunk), so every access-lifecycle moment lands on the
//     same controller.
//   - The `Stream<AccessEvent>` returned from [events].
//
// What this file does NOT own:
//
//   - The events themselves. `AccessEvent` and its three leaves
//     (`AccessCreated` / `AccessDelivered` / `AccessFailed`) live in
//     `tom_brain_shared`. Adding a leaf is a shared edit; the bus stays
//     generic in `AccessEvent`.
//   - Filtering. Subscribers filter with
//     `bus.events().where((e) => e is AccessFailed)`.
//   - Persistence. Events are observed live; the bus is observability-only.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Central fan-in for `AccessEvent`s emitted across the access edge.
///
/// One bus per running access layer. Boot constructs the bus, hands
/// `bus.emit` to the `AccessAssembler` and the `DeliveryRegistry`'s
/// `onDelivered` sink, and exposes `bus.events()` to observers (a Forge
/// inspector, a test).
///
/// Lifecycle: [emit] is legal up until [close]; after [close] [emit] throws
/// `StateError` and [events] subscribers receive a done-stream.
///
/// Broadcast + asynchronous (`sync: false`) + no back-pressure — the same
/// posture as `DispatcherEventBus` / `EngineEventBus` / `SubstrateEventBus` /
/// `MemoryEventBus`.
final class AccessEventBus {
  /// The backing broadcast controller. `sync: false` keeps the edge's call
  /// stack short and prevents a slow subscriber from stalling a lifecycle
  /// emit site.
  final StreamController<AccessEvent> _controller =
      StreamController<AccessEvent>.broadcast(sync: false);

  /// `true` once [close] has been called.
  bool _closed = false;

  /// Whether this bus has been closed.
  bool get isClosed => _closed;

  /// Emits [event] to every current subscriber.
  ///
  /// Asynchronous: the call enqueues the event on the controller and returns.
  /// Subscribers see the event on a future microtask.
  ///
  /// Throws `StateError` if the bus has been closed.
  void emit(AccessEvent event) {
    if (_closed) {
      throw StateError(
        'AccessEventBus.emit called after close (event kind=${event.kind})',
      );
    }
    _controller.add(event);
  }

  /// Returns the typed event stream. Broadcast — multiple subscribers see
  /// every event; missed events stay missed (observability, not a queue).
  Stream<AccessEvent> events() => _controller.stream;

  /// Closes the bus. Subsequent [emit] calls throw `StateError`; live
  /// subscribers receive a done event. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
