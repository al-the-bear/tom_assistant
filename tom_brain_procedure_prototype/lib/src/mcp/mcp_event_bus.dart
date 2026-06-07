// `McpEventBus` — the broadcast fan-in for `McpEvent`s emitted by the MCP
// client (Extension F step 16; spec § 13).
//
// A thin, element-bound subclass of the shared [BrainEventBus] (B.2.1),
// exactly like `EngineEventBus` (C.44), `DispatcherEventBus` (D.49), and
// `ToolEventBus` (step 16): the lifecycle, broadcast/async semantics, and
// closed-after-close guard all live in the base. This file only binds the
// element type and the bus label.
//
// The composition root constructs one bus per process, hands `bus.emit` to
// the `McpClient` as its [McpEventSink], and exposes `bus.events()` to
// observers.

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'mcp_event.dart';

/// Broadcast fan-in for [McpEvent]s.
///
/// One bus per running process. Lifecycle, broadcast/async semantics, and
/// the closed-after-close guard live in the shared [BrainEventBus] — this is
/// the element-bound subclass for `McpEvent`.
final class McpEventBus extends BrainEventBus<McpEvent> {
  McpEventBus() : super(busLabel: 'McpEventBus');
}
