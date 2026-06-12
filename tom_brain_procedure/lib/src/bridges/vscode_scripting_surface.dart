// VsCodeScriptingSurface — the narrow port the `vscode.call` bridge routes
// through (`tom_brain_procedure_specification.md` § 21.9, § 6;
// `prototype_tools_mcp_extension_plan.md` step 14).
//
// Step 14 exposes the VS Code Scripting API as a bridged primitive a procedure
// calls directly — distinct from step 13's *tools* path (which merges the
// extension's tools into the `ToolRegistry`). As at step 13, the prototype
// stays **decoupled** from `tom_vscode_scripting_api`: the bridge depends only
// on this narrow port, and the concrete socket adapter that fronts the real
// scripting API is built where the prototype is colocated with the extension
// (PE-10). A memory-only or test run supplies a stub.
//
// The port is deliberately tiny: one `invoke(api, method, args)` call that
// forwards a single scripting-API method invocation and returns its result.
// The bridge layers the budget pre-charge and the `{ok}` envelope on top
// (`vscode_scripting_bridge.dart`); the port itself only does the call and
// raises [VsCodeScriptingFailure] when the extension cannot be reached.
//
// This file is intentionally NOT listed in `buildkit.yaml`'s `barrelFiles`: the
// port and its failure are host-side Dart types (the installer wiring needs
// them), not d4rt-facing bridged classes. Only `vscode_scripting_bridge.dart`
// is bridged.

/// The single VS Code scripting-API method invocation the `vscode.call` bridge
/// forwards (§ 21.9).
///
/// A concrete implementation fronts the real `tom_vscode_scripting_api` surface
/// over whatever transport the colocated extension exposes (PE-10); the
/// prototype only ever holds this contract, never the concrete API. An
/// unreachable extension is an environmental failure (PE-6) surfaced as
/// [VsCodeScriptingFailure]; the bridge maps it to a `{ok: false, error}`
/// envelope rather than letting it propagate.
abstract class VsCodeScriptingSurface {
  /// Invokes [method] on the scripting [api] namespace (e.g. `window`,
  /// `commands`) with positional [args], returning the method's result.
  ///
  /// Raises [VsCodeScriptingFailure] when the extension cannot be reached or
  /// the invocation fails on the far side.
  Future<Object?> invoke(String api, String method, List<Object?> args);
}

/// Wire-stable discriminator for a failed VS Code scripting-API invocation.
const String vsCodeScriptingFailureCode = 'vscode.scripting.failed';

/// Raised by a [VsCodeScriptingSurface] when a scripting-API invocation cannot
/// be completed — the extension is not reachable, or the far side rejected the
/// call (§ 21.9).
///
/// This is an *environmental* failure (PE-6): the `vscode.call` bridge catches
/// it and reports `{ok: false, error}`, exactly as `McpBridge.call` maps an
/// `McpFailure`. It is never a fallback trigger and never a budget refusal.
///
/// Mirrors the package exception convention (`final class … implements
/// Exception`, a wire-stable `code` constant + getter, a `message`, and a
/// `toString()` that prefixes `$code:`), matching `McpFailure` and the tool
/// failure family.
final class VsCodeScriptingFailure implements Exception {
  /// Human-readable detail of what went wrong.
  final String message;

  /// Builds the failure carrying [message].
  const VsCodeScriptingFailure(this.message);

  /// The wire-stable failure class (`vscode.scripting.failed`).
  String get code => vsCodeScriptingFailureCode;

  @override
  String toString() => '$code: $message';
}
