// VsCodeToolSource — the host-side seam onto a colocated VS Code extension's
// tools (`tom_brain_procedure_specification.md` § 21.8;
// `prototype_tools_mcp_extension_plan.md` step 13).
//
// When the prototype runs as the CLI server colocated with a VS Code
// extension, the extension's tools (`TomToolsApi`, socket JSON-RPC,
// `getToolsJson()` / `invokeTool(name, args)`) are merged into the
// `ToolRegistry` as additional `BrainTool`s (`mergeVsCodeTools`). The merge
// reaches the extension only through this narrow port — the prototype never
// depends on `tom_vscode_scripting_api`. The concrete socket adapter that
// maps `TomToolsApi`'s `ToolDefinitionJson` onto a [VsCodeToolDefinition] and
// forwards `invokeTool` over the wire is implemented where the two are
// colocated (the colocation wiring step), exactly as `ToolEngineSurface`
// fronts the engine without the tools knowing the engine's internals (PE-10).
//
// The port is method-only and exchanges plain values (PE-1): a merged tool
// reaches the extension through the run's [VsCodeToolSource] (carried on the
// `ToolContext`), never a raw socket or `dart:io` handle.

/// One VS Code extension tool's descriptor, as the merge sees it.
///
/// The same `{name, description, input_schema}` shape `TomToolsApi`'s
/// `ToolDefinitionJson` carries (§ 21.8), so a merged VS Code tool and a
/// built-in `BrainTool` are indistinguishable to `tool.list` / `tool.invoke`.
/// Immutable; built by the socket adapter from the extension's reply.
final class VsCodeToolDefinition {
  /// The tool's unique name (the `tool.invoke` selector and registry key).
  final String name;

  /// The one-line description surfaced through `tool.list`.
  final String description;

  /// The JSON-Schema fragment `tool.invoke` validates `args` against before
  /// the call is forwarded to the extension. Defaults to the empty object.
  final Map<String, Object?> inputSchema;

  /// Builds a descriptor for [name] with its [description] and optional
  /// [inputSchema] (defaulting to an open object schema).
  const VsCodeToolDefinition({
    required this.name,
    required this.description,
    this.inputSchema = const <String, Object?>{},
  });
}

/// The narrow VS Code extension capability the merge and the `vscode`-group
/// tools route through (PE-1, PE-10).
///
/// Method-only and result-as-data: `listTools` enumerates the extension's
/// current tool set, and `invokeTool` forwards a validated call. The socket
/// adapter over `TomToolsApi` implements this at the colocation wiring step;
/// tests substitute an in-process stub.
abstract interface class VsCodeToolSource {
  /// The extension's current tools, each as a plain [VsCodeToolDefinition].
  /// Read at merge time to register one `BrainTool` per tool.
  Future<List<VsCodeToolDefinition>> listTools();

  /// Forwards a call to the extension tool named [name] with [arguments] (the
  /// args already validated against the tool's `inputSchema`), returning the
  /// extension's raw string result.
  Future<String> invokeTool(String name, Map<String, Object?> arguments);
}
