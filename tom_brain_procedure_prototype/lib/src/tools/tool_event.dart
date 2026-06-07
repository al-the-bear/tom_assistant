// `ToolEvent` sealed sum — the tool-calling core's typed observability
// stream (Extension F step 16; `tom_brain_procedure_prototype_specification.md`
// § 13, § 21.10).
//
// Four variants, one per outcome the `tool.list` / `tool.invoke` bridge
// (`tool_bridge.dart`) can reach:
//
//   - `ToolListed`  — a `tool.list` enumeration resolved (post policy-narrow).
//   - `ToolInvoked` — a `tool.invoke` ran the named tool to a result.
//   - `ToolFailed`  — a `tool.invoke` refused (unknown tool / invalid args)
//                     or the tool threw while running.
//   - `ToolDenied`  — a `tool.invoke` was hidden by the active `ToolPolicy`.
//
// Same shape as the engine half (`EngineEvent`, C.44) and the dispatcher
// half (`DispatcherEvent`, D.49): a `sealed` `BrainEvent` subtree with a
// kebab-case `kind` discriminator and a null-omitting `payloadJson()`. The
// `ToolEventBus` (`tool_event_bus.dart`) is the broadcast fan-in.
//
// ── `runId` stays nullable ──────────────────────────────────────────
//
// A `ToolBridge` is constructed over a run's `ToolContext`, but the context
// carries no run id (it carries the budget, memory client, and surfaces, not
// the run identity). So `ToolEvent` keeps `BrainEvent`'s nullable `runId` —
// the composition root that wires a sink may set `runId` / `causedBy` when it
// has them, exactly as `DispatcherEvent`'s access-scoped variants do.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// Sink the [ToolBridge] calls with each [ToolEvent] it emits (step 16).
///
/// Injected into the bridge; the composition root wires it to a
/// [ToolEventBus] (`bus.emit`). `null` (the default) disables emission, so a
/// bridge built without observability is a pure tool router.
typedef ToolEventSink = void Function(ToolEvent event);

/// Marker / base for every typed tool observability event.
///
/// A consumer subscribed to `ToolEventBus.events()` sees only subtypes of
/// this class. Exhaustive `switch` over the closed four-variant taxonomy
/// (spec § 13) is the recommended branch surface.
sealed class ToolEvent extends BrainEvent {
  /// Builds the base of a tool event. [runId] stays nullable — see the file
  /// header.
  ToolEvent({
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });
}

/// A `tool.list` enumeration resolved (§ 21.2) — emitted once per `list`,
/// after the active [ToolPolicy] narrowed the catalogue.
final class ToolListed extends ToolEvent {
  /// The number of tools the policy-narrowed list returned.
  final int count;

  /// The [ToolGroup] wire name the list was filtered to, or `null` for an
  /// unfiltered enumeration.
  final String? filter;

  ToolListed({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.count,
    this.filter,
  });

  @override
  String get kind => 'tool.listed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'count': count,
        if (filter != null) 'filter': filter,
      };
}

/// A `tool.invoke` ran the named tool to a result (§ 21.2) — emitted after a
/// successful `tool.run`, past the unknown / denied / invalid-args guards and
/// the budget pre-charge.
final class ToolInvoked extends ToolEvent {
  /// The registered name of the tool that ran.
  final String name;

  /// The [ToolGroup] wire name the tool belongs to.
  final String group;

  ToolInvoked({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.name,
    required this.group,
  });

  @override
  String get kind => 'tool.invoked';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'name': name,
        'group': group,
      };
}

/// A `tool.invoke` failed (§ 21.2) — the named tool was unknown, its [args]
/// failed the input schema, or it threw while running. Distinct from
/// [ToolDenied], which is a deliberate policy refusal, not a failure.
final class ToolFailed extends ToolEvent {
  /// The name the invocation targeted (may name no registered tool).
  final String name;

  /// A human-readable reason — the same string the `{ok: false, error}`
  /// result carries, or the thrown error's message on a run failure.
  final String reason;

  ToolFailed({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.name,
    required this.reason,
  });

  @override
  String get kind => 'tool.failed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'name': name,
        'reason': reason,
      };
}

/// A `tool.invoke` was refused because the active [ToolPolicy] hides the
/// tool (§ 21.10) — emitted before the budget gate, so a denied call never
/// charges the ledger.
final class ToolDenied extends ToolEvent {
  /// The name of the tool the policy hid.
  final String name;

  /// The denial message the policy supplied.
  final String reason;

  ToolDenied({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.name,
    required this.reason,
  });

  @override
  String get kind => 'tool.denied';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'name': name,
        'reason': reason,
      };
}
