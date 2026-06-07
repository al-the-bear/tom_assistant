// McpBridge — the d4rt-bridged `mcp.servers` / `mcp.list` / `mcp.call`
// primitive trio (`prototype_tools_mcp_extension_plan.md` step 8;
// `tom_brain_procedure_prototype_specification.md` § 21.3, § 21.10).
//
// This is a **plain Dart class** bridged exactly like `MemoryBridge` /
// `SubstrateBridge` / `ToolBridge`: `build.yaml` lists this file under the
// `all` module's `barrelFiles`, `tom_d4rt_generator` emits the bridge, and
// `BrainBridges.register` registers it under [BrainBridges.mcpLibrary]. A
// procedure script that imports that library sees the host-injected `mcp`
// global (`D4rtDcliHost.mcpGlobal`) and calls `mcp.servers()` /
// `mcp.list(server)` / `mcp.call(server, tool, args)` directly — the same
// named-global convention `mem` / `sub` / `tool` use.
//
// ── The three methods (§ 21.3) ──────────────────────────────────────
//
//   mcp.servers()           → List<Map> of {id, transport, description} —
//                             the configured servers; no effect cost.
//   mcp.list(server)        → List<Map> of {name, description, input_schema}
//                             — the remote server's advertised tools. An
//                             unreachable server raises `McpFailure`
//                             (propagates: there is no {ok} envelope on a
//                             list).
//   mcp.call(server,tool,args) → {ok: true, result} on success; {ok: false,
//                             error} when the server is unknown or the call
//                             fails. Counts one `toolCalls` unit.
//
// ── Why the fields are private ──────────────────────────────────────
//
// The generator emits a script-facing getter for every PUBLIC final field;
// the client and context are host internals a procedure must never reach, so
// they are private (`_client` / `_context`) and the generated bridge exposes
// only the three methods. The bridge is constructed natively by the engine
// over the run's surface; a script never calls the constructor.
//
// ── Budget pre-charge (PE-8) ────────────────────────────────────────
//
// `call` charges one `toolCalls` unit against the run's [BudgetLedger]
// (carried by the [ToolContext]) *before* the wire call: `check` refuses a
// call over the run's `toolCalls` cap with `ProcedureBudgetExceeded` (which
// propagates — a budget refusal is not an `{ok: false}` result), and `charge`
// counts the call before the side effect. The unknown-server pre-flight guard
// runs *before* the budget gate, so a call to an unconfigured server never
// charges the ledger; an attempted-but-failed call to a *configured* server
// is still charged (it "counts the call", § 21.10).

import '../mcp/mcp_client.dart';
import '../tools/tool_context.dart';

/// Bridges the MCP client to d4rt as the `mcp.servers` / `mcp.list` /
/// `mcp.call` primitive trio (§ 21.3).
///
/// Holds the run's [McpClient] (the configured registry + connection pool)
/// and [ToolContext] (the budget the calls charge through). The bridge owns
/// no effect surface of its own — it routes through the client, which routes
/// through the pooled connections (PE-1). An unreachable server is an
/// environmental failure (PE-6): `call` reports it as `{ok: false}`, `list`
/// lets it propagate; neither triggers a fallback.
class McpBridge {
  final McpClient _client;
  final ToolContext _context;

  /// Wraps the run's [client] and [context]. The engine constructs this
  /// natively and the host injects the instance as the `mcp` global; a
  /// procedure script never calls this constructor.
  McpBridge(this._client, this._context);

  /// The budget primitive name `call` charges — recognised by the
  /// `EffortAccountant` as one `toolCalls` unit so the ledger can gate it.
  /// Private so the generated bridge exposes only the three methods (PE-1).
  static const String _callPrimitive = 'mcp.call';

  /// Lists the configured MCP servers, each as `{id, transport, description}`
  /// (§ 21.3). Carries no effect cost.
  Future<List<Map<String, Object?>>> servers() async => _client.servers();

  /// Lists the advertised tools of [server], each as `{name, description,
  /// input_schema}` (§ 21.3).
  ///
  /// An unknown or unreachable server raises [McpFailure] (it propagates —
  /// there is no `{ok}` envelope on a list). This is an environmental failure
  /// (PE-6), not a fallback trigger.
  Future<List<Map<String, Object?>>> list(String server) =>
      _client.listTools(server);

  /// Calls [tool] on [server] with [args] (§ 21.3).
  ///
  /// Returns `{ok: true, result}` when the call succeeds; `{ok: false, error}`
  /// when [server] is not configured or the call fails (an environmental
  /// failure, PE-6 — not a fallback trigger). A call over the run's
  /// `toolCalls` cap throws `ProcedureBudgetExceeded` (it is not an
  /// `{ok: false}` result) — the budget is pre-charged before the wire call
  /// (PE-8), after the unknown-server guard, so a call to an unconfigured
  /// server never charges the ledger; an attempted-but-failed call to a
  /// configured server is charged ("counts the call", § 21.10).
  Future<Map<String, Object?>> call(
    String server,
    String tool,
    Map<String, Object?> args,
  ) async {
    if (!_client.isConfigured(server)) {
      return _failure('no MCP server configured with id "$server"');
    }

    // Pre-charge one toolCall before the wire call (PE-8). `check` throws and
    // propagates when the call is over cap; `charge` counts it.
    _context.budget.check(_callPrimitive);
    _context.budget.charge(_callPrimitive);

    try {
      final result = await _client.callTool(server, tool, args);
      return <String, Object?>{'ok': true, 'result': result};
    } on McpFailure catch (failure) {
      return _failure(failure.message);
    }
  }

  /// A `{ok: false, error}` result carrying [error].
  static Map<String, Object?> _failure(String error) =>
      <String, Object?>{'ok': false, 'error': error};
}
