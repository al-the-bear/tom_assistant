// VsCodeScriptingBridge — the d4rt-bridged `vscode.call` primitive over the
// VS Code Scripting API (`prototype_tools_mcp_extension_plan.md` step 14;
// `tom_brain_procedure_specification.md` § 21.9, § 6, § 21.10).
//
// This is a **plain Dart class** bridged exactly like `MemoryBridge` /
// `SubstrateBridge` / `ToolBridge` / `McpBridge`: `build.yaml` lists this file
// under the `all` module's `barrelFiles`, `tom_d4rt_generator` emits the
// bridge, and `BrainBridges.register` registers it under
// [BridgeLibraries.vscodeScriptingLibrary]. A procedure script that imports that
// library sees the host-injected `vscode` global
// (`D4rtDcliHost.vsCodeScriptingGlobal`) and calls
// `vscode.call(api, method, args)` directly — the same named-global convention
// `mem` / `sub` / `tool` / `mcp` use.
//
// ── Distinct from the tools path (§ 21.8 vs § 21.9) ─────────────────
//
// Step 13 (§ 21.8) merges the extension's *tools* into the `ToolRegistry`, so
// a procedure reaches them through `tool.invoke`. This bridge (§ 21.9) exposes
// the *scripting API surface itself* — a procedure calls `vscode.call('window',
// 'showInformationMessage', [...])` to drive the editor directly, not a
// pre-declared tool.
//
// ── The one method (§ 21.9) ─────────────────────────────────────────
//
//   vscode.call(api, method, args) → {ok: true, result} on success; {ok:
//                             false, error} when the extension is unreachable
//                             or the invocation fails. Counts one `toolCalls`
//                             unit.
//
// ── Why the fields are private ──────────────────────────────────────
//
// The generator emits a script-facing getter for every PUBLIC final field; the
// surface and budget are host internals a procedure must never reach, so they
// are private (`_surface` / `_budget`) and the generated bridge exposes only
// the one method. The bridge is constructed natively by the host over the run's
// surface; a script never calls the constructor.
//
// ── Budget pre-charge (PE-8) ────────────────────────────────────────
//
// `call` charges one `toolCalls` unit against the run's [BudgetLedger] *before*
// the surface call: `check` refuses a call over the run's `toolCalls` cap with
// `ProcedureBudgetExceeded` (which propagates — a budget refusal is not an
// `{ok: false}` result), and `charge` counts the call before the side effect.
// Unlike `McpBridge` there is no "unknown server" pre-flight guard — every call
// is to the one colocated extension — so the budget gate is the first thing the
// method does. An attempted-but-failed call to a reachable-then-failing surface
// is still charged ("counts the call", § 21.10).

import '../budget/budget_ledger.dart';
import 'vscode_scripting_surface.dart';

/// Bridges the VS Code Scripting API to d4rt as the `vscode.call` primitive
/// (§ 21.9).
///
/// Holds the run's [VsCodeScriptingSurface] (the narrow port to the colocated
/// extension, PE-10) and [BudgetLedger] (the budget the call charges through,
/// PE-8). The bridge owns no effect surface of its own — it routes through the
/// port, which fronts the real scripting API (PE-1). An unreachable extension
/// is an environmental failure (PE-6): `call` reports it as `{ok: false}` and
/// never triggers a fallback.
class VsCodeScriptingBridge {
  final VsCodeScriptingSurface _surface;
  final BudgetLedger _budget;

  /// Wraps the run's [surface] and [budget]. The host constructs this natively
  /// and injects the instance as the `vscode` global; a procedure script never
  /// calls this constructor.
  VsCodeScriptingBridge(this._surface, this._budget);

  /// The budget primitive name `call` charges — recognised by the
  /// `EffortAccountant` as one `toolCalls` unit so the ledger can gate it.
  /// Private so the generated bridge exposes only the one method (PE-1).
  static const String _callPrimitive = 'vscode.call';

  /// Invokes [method] on the scripting [api] namespace with [args] (§ 21.9).
  ///
  /// Returns `{ok: true, result}` when the invocation succeeds; `{ok: false,
  /// error}` when the extension is unreachable or the call fails (an
  /// environmental failure, PE-6 — not a fallback trigger). A call over the
  /// run's `toolCalls` cap throws `ProcedureBudgetExceeded` (it is not an
  /// `{ok: false}` result) — the budget is pre-charged before the surface call
  /// (PE-8), so a refused call never reaches the surface; an attempted-but-
  /// failed call is charged ("counts the call", § 21.10).
  Future<Map<String, Object?>> call(
    String api,
    String method,
    List<Object?> args,
  ) async {
    // Pre-charge one toolCall before the surface call (PE-8). `check` throws
    // and propagates when the call is over cap; `charge` counts it.
    _budget.check(_callPrimitive);
    _budget.charge(_callPrimitive);

    try {
      final result = await _surface.invoke(api, method, args);
      return <String, Object?>{'ok': true, 'result': result};
    } on VsCodeScriptingFailure catch (failure) {
      return <String, Object?>{'ok': false, 'error': failure.message};
    }
  }
}
