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

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'engine_event.dart';

/// Central fan-in for `EngineEvent`s emitted across the engine.
///
/// One bus per running engine. The composition root constructs the bus,
/// hands `bus.emit` to the `ProcedureEngine`, and exposes `bus.events()`
/// to observers.
///
/// Lifecycle, broadcast/async semantics, and the closed-after-close
/// guard all live in the shared [BrainEventBus] (B.2.1) — this is the
/// element-bound subclass for `EngineEvent`.
final class EngineEventBus extends BrainEventBus<EngineEvent> {
  EngineEventBus() : super(busLabel: 'EngineEventBus');
}
