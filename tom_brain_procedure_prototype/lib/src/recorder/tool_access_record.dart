// ToolAccessRecord — one emitted [ToolEvent] enriched with the run-correlation
// the engine knows (the trail half of "tool calls must be in the trails
// files", mirroring the §5.6 memory-access seam).
//
// Every tool call a run issues (`tool.list` / `tool.invoke`) is dispatched
// through the per-run [ToolBridge], which already emits a typed [ToolEvent]
// (`ToolListed` / `ToolInvoked` / `ToolFailed` / `ToolDenied`) on each outcome.
// But that event carries no run identity — the `ToolContext` holds the budget,
// memory client, and surfaces, not the run's `runId`, the live `trailId`, or
// the turn it serves. Those belong to the run, not the bridge, so the engine
// wraps each emitted event into this record before handing it to the run's
// [ToolAccessSink].
//
// `turnId` is `null` for a turn-less invocation (an internal / free-time /
// dream run that carries no user turn). The event keeps its own `occurredAt`
// (stamped by the bridge's clock, which the engine binds to its own clock), so
// no separate timestamp is carried here.

import '../tools/tool_event.dart';

/// One emitted tool [event] plus the run-correlation the engine supplies: the
/// `runId`, the live `trailId` the recorder opened, and the `turnId` the run
/// serves. Ready for a trail / live-trail writer to render as a tool-call line.
final class ToolAccessRecord {
  /// The tool observability event the bridge emitted (`tool.listed`,
  /// `tool.invoked`, `tool.failed`, `tool.denied`). Its `occurredAt` carries
  /// the call's UTC timestamp.
  final ToolEvent event;

  /// The run that issued the call. `null` only if the engine could not
  /// resolve it (it always can for a real run).
  final String? runId;

  /// The run's trail id (`TrailId.value`), or `null` if the run's trail was
  /// not open when the call fired.
  final String? trailId;

  /// The turn this access served (`TurnId.value`), or `null` for a turn-less
  /// invocation.
  final String? turnId;

  const ToolAccessRecord({
    required this.event,
    this.runId,
    this.trailId,
    this.turnId,
  });
}

/// The engine-level sink one [ToolAccessRecord] is handed to per emitted tool
/// event. Bound by the host to a live-trail / trail writer; `null` leaves the
/// engine wiring no `onEvent` onto the run's tool bridge, so no tool record is
/// emitted. Best-effort and non-blocking — a throwing writer is swallowed so it
/// cannot break the run.
typedef ToolAccessSink = void Function(ToolAccessRecord record);
