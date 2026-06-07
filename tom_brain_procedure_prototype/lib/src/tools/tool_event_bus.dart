// `ToolEventBus` — the broadcast fan-in for `ToolEvent`s emitted by the
// `tool.list` / `tool.invoke` bridge (Extension F step 16; spec § 13).
//
// A thin, element-bound subclass of the shared [BrainEventBus] (B.2.1),
// exactly like `EngineEventBus` (C.44) and `DispatcherEventBus` (D.49):
// the lifecycle, broadcast/async semantics, and closed-after-close guard
// all live in the base. This file only binds the element type and supplies
// the bus label that the emit-after-close diagnostic reports.
//
// The composition root constructs one bus per run/process, hands `bus.emit`
// to the `ToolBridge` as its [ToolEventSink], and exposes `bus.events()` to
// observers (the Forge tool inspector, a metrics scraper, tests).

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'tool_event.dart';

/// Broadcast fan-in for [ToolEvent]s.
///
/// One bus per running engine. Lifecycle, broadcast/async semantics, and
/// the closed-after-close guard live in the shared [BrainEventBus] — this is
/// the element-bound subclass for `ToolEvent`.
final class ToolEventBus extends BrainEventBus<ToolEvent> {
  ToolEventBus() : super(busLabel: 'ToolEventBus');
}
