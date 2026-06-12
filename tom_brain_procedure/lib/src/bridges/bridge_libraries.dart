// BridgeLibraries — the canonical `package:` URIs each engine bridge is
// registered and injected under (`tom_brain_procedure_specification.md` § 3).
//
// ── Why this is host-owned, not generated ───────────────────────────
//
// These five URIs are *injection wiring*, not bridge definitions. The
// host registers every bridge under its URI (so a procedure script's
// `import 'package:tom_brain_procedure/src/bridges/<x>.dart'` resolves
// against the registered-library map) and injects each bridge instance
// as a named global (`mem` / `sub` / `tool` / `mcp` / `vscode`) under the
// same URI. The validator allow-lists imports against the same set.
//
// The generated registration entrypoint (`BrainBridges.register`, in
// `dartscript.b.dart`) hard-codes these same URIs as string literals; this
// holder names them once so the host, the validator, and the tests share
// a single source of truth and stay in lock-step with what the generator
// registers under.
//
// They must be `package:` URIs (not relative paths): d4rt's `ModuleLoader`
// resolves `package:` imports directly against the registered-library map,
// whereas a relative import requires a filesystem base URI the interpreter
// does not have at script-execute time.

/// The canonical `package:` URIs each engine bridge is registered and
/// injected under by the host.
///
/// The values match, one-for-one, the literals the generated
/// `BrainBridges.register` (`dartscript.b.dart`) registers each bridge
/// under, keeping host injection and validator allow-listing aligned with
/// generator-produced registration.
final class BridgeLibraries {
  const BridgeLibraries._();

  /// URI under which the memory bridge is importable from a d4rt script.
  static const String memoryLibrary =
      'package:tom_brain_procedure/src/bridges/memory_bridge.dart';

  /// URI under which the substrate bridge is importable from a d4rt script.
  static const String substrateLibrary =
      'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';

  /// URI under which the tool bridge is importable from a d4rt script
  /// (Extension F step 6 — the `tool.list` / `tool.invoke` primitive pair).
  static const String toolLibrary =
      'package:tom_brain_procedure/src/bridges/tool_bridge.dart';

  /// URI under which the MCP bridge is importable from a d4rt script
  /// (Extension F step 8 — the `mcp.servers` / `mcp.list` / `mcp.call` trio).
  static const String mcpLibrary =
      'package:tom_brain_procedure/src/bridges/mcp_bridge.dart';

  /// URI under which the VS Code scripting bridge is importable from a d4rt
  /// script (Extension F step 14 — the `vscode.call` primitive, § 21.9).
  static const String vscodeScriptingLibrary =
      'package:tom_brain_procedure/src/bridges/'
      'vscode_scripting_bridge.dart';

  /// URI under which the read-only budget view is importable from a d4rt
  /// script (§ 5.4.2 — the `budget` global's limit/remaining getters). It
  /// lives under `budget/` (not `bridges/`) because it is a view over the
  /// run's `BudgetLedger`, not an effect surface; the generator still
  /// registers it from the barrel file listed in `build.yaml`.
  static const String budgetLibrary =
      'package:tom_brain_procedure/src/budget/budget_view.dart';
}
