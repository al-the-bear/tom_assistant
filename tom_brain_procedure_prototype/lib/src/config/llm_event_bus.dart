// `LlmLoopEventBus` — the broadcast fan-in for `LlmLoopEvent`s emitted by the
// scripted `call_llm_v1` loop (Extension F step 16; spec § 13).
//
// A thin, element-bound subclass of the shared [BrainEventBus] (B.2.1),
// exactly like `EngineEventBus` (C.44), `DispatcherEventBus` (D.49),
// `ToolEventBus`, and `McpEventBus` (step 16): the lifecycle, broadcast/async
// semantics, and closed-after-close guard all live in the base. This file
// only binds the element type and the bus label.
//
// Wiring lands with the loop (steps 11–12): the composition root constructs
// the bus, hands `bus.emit` to the loop as its [LlmLoopEventSink], and exposes
// `bus.events()` to observers (the Forge loop inspector, a metrics scraper,
// the step 11/12 sequence-assertion test).

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'llm_event.dart';

/// Broadcast fan-in for [LlmLoopEvent]s.
///
/// One bus per running engine. Lifecycle, broadcast/async semantics, and the
/// closed-after-close guard live in the shared [BrainEventBus] — this is the
/// element-bound subclass for `LlmLoopEvent`.
final class LlmLoopEventBus extends BrainEventBus<LlmLoopEvent> {
  LlmLoopEventBus() : super(busLabel: 'LlmLoopEventBus');
}
