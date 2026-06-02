// D.49 — `DispatcherEventBus`: central fan-in for `DispatcherEvent`s
// emitted across the dispatcher (spec § 13 observability surface).
//
// Shape mirror of `EngineEventBus` (C.44), itself a mirror of
// `SubstrateEventBus` (B.38) / `MemoryEventBus` (A.85). The only
// intentional divergence is the event-base type (`DispatcherEvent` vs
// `EngineEvent`). Two reasons for the verbatim copy: (i) zero design
// risk — the pattern has shipped four times; (ii) zero divergence cost —
// a reader who has read one bus has read all of them.
//
// What this file owns:
//
//   - A `StreamController<DispatcherEvent>.broadcast()` that fans every
//     emission out to every subscriber.
//   - The `void Function(DispatcherEvent)` sink ([emit]) the dispatcher's
//     lifecycle points call. The composition root (the boot-wiring step)
//     hands `bus.emit` to the entry surface, the coordinator, and the
//     fallback executor so every lifecycle moment lands on the same
//     controller.
//   - The `Stream<DispatcherEvent>` returned from [events].
//
// What this file does NOT own:
//
//   - The events themselves. `DispatcherEvent` and its seven leaves live
//     in `dispatcher_event.dart`. Adding a leaf is a `dispatcher_event.dart`
//     edit; the bus stays generic in `DispatcherEvent`.
//   - Filtering. Subscribers filter with
//     `bus.events().where((e) => e is RunCompleted)`.
//   - Persistence. Events are observed live; the run recorder persists the
//     trail entries that survive for replay. The bus is observability-only.

import 'dart:async';

import 'dispatcher_event.dart';

/// Central fan-in for `DispatcherEvent`s emitted across the dispatcher.
///
/// One bus per running dispatcher. The composition root constructs the
/// bus, hands `bus.emit` to the entry surface / coordinator / fallback
/// executor, and exposes `bus.events()` to observers.
///
/// Lifecycle: [emit] is legal up until [close]; after [close] [emit]
/// throws `StateError` and [events] subscribers receive a done-stream.
///
/// Broadcast + asynchronous (`sync: false`) + no back-pressure — the same
/// posture as `EngineEventBus` / `SubstrateEventBus` / `MemoryEventBus`.
final class DispatcherEventBus {
  /// The backing broadcast controller. `sync: false` keeps the
  /// dispatcher's call stack short and prevents a slow subscriber from
  /// stalling a lifecycle emit site.
  final StreamController<DispatcherEvent> _controller =
      StreamController<DispatcherEvent>.broadcast(sync: false);

  /// `true` once [close] has been called.
  bool _closed = false;

  /// Whether this bus has been closed.
  bool get isClosed => _closed;

  /// Emits [event] to every current subscriber.
  ///
  /// Asynchronous: the call enqueues the event on the controller and
  /// returns. Subscribers see the event on a future microtask.
  ///
  /// Throws `StateError` if the bus has been closed.
  void emit(DispatcherEvent event) {
    if (_closed) {
      throw StateError(
        'DispatcherEventBus.emit called after close '
        '(event kind=${event.kind})',
      );
    }
    _controller.add(event);
  }

  /// Returns the typed event stream. Broadcast — multiple subscribers see
  /// every event; missed events stay missed (observability, not a queue).
  Stream<DispatcherEvent> events() => _controller.stream;

  /// Closes the bus. Subsequent [emit] calls throw `StateError`; live
  /// subscribers receive a done event. Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
