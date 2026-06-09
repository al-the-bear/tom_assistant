// `HistoryEventBus` — the broadcast fan-in for `HistoryEvent`s emitted by the
// history subsystem (Extension G step 25; spec § 22.10).
//
// A thin, element-bound subclass of the shared [BrainEventBus], exactly like
// `LlmLoopEventBus` (step 16), `EngineEventBus` (C.44), and `DispatcherEventBus`
// (D.49): the lifecycle, broadcast/async semantics, and closed-after-close
// guard all live in the base. This file only binds the element type and label.
//
// Wiring lands with the emitting runtimes: the composition root constructs the
// bus, hands `bus.emit` to the engine-side `HistoryCompactor` and the
// access-edge parse/resolve/loop as their [HistoryEventSink], and exposes
// `bus.events()` to observers.

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'history_event.dart';

/// Broadcast fan-in for [HistoryEvent]s.
///
/// One bus per running engine. Lifecycle, broadcast/async semantics, and the
/// closed-after-close guard live in the shared [BrainEventBus] — this is the
/// element-bound subclass for `HistoryEvent`.
final class HistoryEventBus extends BrainEventBus<HistoryEvent> {
  HistoryEventBus() : super(busLabel: 'HistoryEventBus');
}
