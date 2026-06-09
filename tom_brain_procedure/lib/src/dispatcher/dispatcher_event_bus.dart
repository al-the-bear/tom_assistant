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

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'dispatcher_event.dart';

/// Central fan-in for `DispatcherEvent`s emitted across the dispatcher.
///
/// One bus per running dispatcher. The composition root constructs the
/// bus, hands `bus.emit` to the entry surface / coordinator / fallback
/// executor, and exposes `bus.events()` to observers.
///
/// Lifecycle, broadcast/async semantics, and the closed-after-close
/// guard all live in the shared [BrainEventBus] (B.2.1) — this is the
/// element-bound subclass for `DispatcherEvent`.
final class DispatcherEventBus extends BrainEventBus<DispatcherEvent> {
  DispatcherEventBus() : super(busLabel: 'DispatcherEventBus');
}
