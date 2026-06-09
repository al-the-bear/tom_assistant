// ToolBridge — the d4rt-bridged `tool.list` / `tool.invoke` primitive pair
// (`prototype_tools_mcp_extension_plan.md` step 6;
// `tom_brain_procedure_specification.md` § 21.2, § 5.1).
//
// This is a **plain Dart class** bridged exactly like `MemoryBridge` /
// `SubstrateBridge`: `build.yaml` lists this file under the `all` module's
// `barrelFiles`, `tom_d4rt_generator` emits the bridge, and
// `BrainBridges.register` registers it under [BrainBridges.toolLibrary]. A
// procedure script that imports that library sees the host-injected `tool`
// global (`D4rtDcliHost.toolGlobal`) and calls `tool.list()` /
// `tool.invoke(...)` directly — the same named-global convention `mem` /
// `sub` use (host § "How a procedure reaches the bridges").
//
// ── The two methods (§ 21.2) ────────────────────────────────────────
//
//   tool.list({filter})    → List<Map> of {name, group, description,
//                            input_schema}, already narrowed by the active
//                            `ToolPolicy` (step 5). An optional `filter`
//                            (a `ToolGroup` wire name) narrows to one group;
//                            an unknown filter narrows to nothing.
//   tool.invoke(name,args) → {ok: true, result} on success; {ok: false,
//                            error} when the tool is unknown, policy-denied,
//                            or its `args` fail the tool's input schema.
//
// ── Why the fields are private ──────────────────────────────────────
//
// The generator emits a script-facing getter for every PUBLIC final field;
// the registry / policy / context are host internals a procedure must never
// reach, so they are private (`_registry` / `_policy` / `_context`) and the
// generated bridge exposes only the two methods. The bridge is constructed
// natively by the engine over the run's surface; a script never calls the
// constructor.
//
// ── Budget pre-charge (PE-8) ────────────────────────────────────────
//
// `invoke` charges one `toolCalls` unit against the run's [BudgetLedger]
// (carried by the [ToolContext]) *before* the tool runs: `check` refuses a
// call over the run's `toolCalls` cap with `ProcedureBudgetExceeded` (which
// propagates — a budget refusal is not an `{ok: false}` result), and
// `charge` counts the call before the side effect. The three pre-flight
// guards (unknown / denied / invalid args) run *before* the budget gate, so
// a refused call never charges the ledger.

import '../tools/brain_tool.dart';
import '../tools/tool_context.dart';
import '../tools/tool_event.dart';
import '../tools/tool_group.dart';
import '../tools/tool_input_schema.dart' show validateToolArgs;
import '../tools/tool_policy.dart';
import '../tools/tool_registry.dart';

/// Bridges the tool-calling core (`ToolRegistry` + `ToolPolicy`) to d4rt as
/// the `tool.list` / `tool.invoke` primitive pair (§ 21.2).
///
/// Holds the run's [ToolRegistry], [ToolPolicy], and [ToolContext]; every
/// list is policy-narrowed and every invoke is policy-re-checked, so a tool
/// the policy hides is invisible to enumeration *and* refused on a direct
/// call (§ 21.10). The bridge owns no effect surface of its own — it routes
/// through the tools, which route through the [ToolContext] (PE-1).
class ToolBridge {
  final ToolRegistry _registry;
  final ToolPolicy _policy;
  final ToolContext _context;
  final ToolEventSink? _onEvent;
  final DateTime Function() _clock;

  /// Wraps the run's [registry], [policy], and [context]. The engine
  /// constructs this natively and the host injects the instance as the
  /// `tool` global; a procedure script never calls this constructor.
  ///
  /// [onEvent], when supplied, receives a typed [ToolEvent] on every `list`
  /// and `invoke` outcome (step 16); the composition root wires it to a
  /// `ToolEventBus`. [clock] stamps each event's `occurredAt` (UTC) and is
  /// injectable so a test can stamp a deterministic timestamp instead of the
  /// wall clock; it defaults to `DateTime.now().toUtc()`.
  ToolBridge(
    this._registry,
    this._policy,
    this._context, {
    ToolEventSink? onEvent,
    DateTime Function()? clock,
  })  : _onEvent = onEvent,
        _clock = clock ?? _utcNow;

  /// The wall-clock UTC default for [_clock].
  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Forwards [event] to the injected sink when observability is wired.
  void _emit(ToolEvent event) {
    final sink = _onEvent;
    if (sink != null) sink(event);
  }

  /// The budget primitive name `invoke` charges — recognised by the
  /// `EffortAccountant` as one `toolCalls` unit so the ledger can gate it.
  /// Private so the generated bridge exposes only `list` / `invoke` to a
  /// script (PE-1).
  static const String _invokePrimitive = 'tool.invoke';

  /// Lists the tools the active policy exposes, each as `{name, group,
  /// description, input_schema}` (§ 21.2).
  ///
  /// [filter], when supplied, is a [ToolGroup] wire name (`memory`, `file`,
  /// …) that narrows the catalogue to that group before the policy applies;
  /// a filter that names no known group narrows to nothing.
  Future<List<Map<String, Object?>>> list({String? filter}) async {
    final result = _listFor(filter);
    _emit(ToolListed(occurredAt: _clock(), count: result.length, filter: filter));
    return result;
  }

  /// The policy-narrowed descriptor list for [filter] (an unknown filter
  /// narrows to nothing). Split out from [list] so the emission point sees the
  /// resolved result without duplicating the branch.
  List<Map<String, Object?>> _listFor(String? filter) {
    if (filter != null) {
      final group = _groupFromWire(filter);
      if (group == null) return const <Map<String, Object?>>[];
      return _describeAll(_registry.list(group: group));
    }
    return _describeAll(_registry.list());
  }

  /// Invokes the tool registered under [name] with [args] (§ 21.2).
  ///
  /// Returns `{ok: true, result}` when the tool runs; `{ok: false, error}`
  /// when [name] is unknown, the policy hides it, or [args] fail its input
  /// schema. A call over the run's `toolCalls` cap throws
  /// `ProcedureBudgetExceeded` (it is not an `{ok: false}` result) — the
  /// budget is pre-charged before the side effect (PE-8), after the three
  /// pre-flight guards, so a refused call never charges the ledger.
  Future<Map<String, Object?>> invoke(
    String name,
    Map<String, Object?> args,
  ) async {
    final tool = _registry.lookup(name);
    if (tool == null) {
      final error = 'unknown tool "$name"';
      _emit(ToolFailed(occurredAt: _clock(), name: name, reason: error));
      return _failure(error);
    }

    final denial = _policy.denialFor(tool);
    if (denial != null) {
      _emit(ToolDenied(occurredAt: _clock(), name: name, reason: denial.message));
      return _failure(denial.message);
    }

    final violation = validateToolArgs(tool.inputSchema, args);
    if (violation != null) {
      _emit(ToolFailed(occurredAt: _clock(), name: name, reason: violation));
      return _failure(violation);
    }

    // Pre-charge one toolCall before the side effect (PE-8). `check` throws
    // and propagates when the call is over cap; `charge` counts it.
    _context.budget.check(_invokePrimitive);
    _context.budget.charge(_invokePrimitive);

    final Object? result;
    try {
      result = await tool.run(args, _context);
    } catch (error) {
      // A tool that threw while running is a `ToolFailed` (observability);
      // rethrow so the failure still propagates to the caller unchanged.
      _emit(ToolFailed(occurredAt: _clock(), name: name, reason: error.toString()));
      rethrow;
    }
    _emit(ToolInvoked(occurredAt: _clock(), name: name, group: tool.group.name));
    return <String, Object?>{'ok': true, 'result': result};
  }

  /// The policy-narrowed descriptor list for [tools].
  List<Map<String, Object?>> _describeAll(Iterable<BrainTool> tools) =>
      _policy.narrow(tools).map(_describe).toList(growable: false);

  /// A `{ok: false, error}` result carrying [error].
  static Map<String, Object?> _failure(String error) =>
      <String, Object?>{'ok': false, 'error': error};

  /// The `{name, group, description, input_schema}` descriptor for [tool].
  static Map<String, Object?> _describe(BrainTool tool) => <String, Object?>{
        'name': tool.name,
        'group': tool.group.name,
        'description': tool.description,
        'input_schema': tool.inputSchema,
      };

  /// Resolves a [ToolGroup] from its wire name, or `null` when none matches.
  static ToolGroup? _groupFromWire(String wire) {
    for (final group in ToolGroup.values) {
      if (group.name == wire) return group;
    }
    return null;
  }
}
