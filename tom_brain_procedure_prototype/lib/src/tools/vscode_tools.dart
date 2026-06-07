// VsCodeBrainTool + mergeVsCodeTools — merging a colocated VS Code extension's
// tools into the `ToolRegistry` (`tom_brain_procedure_prototype_specification.md`
// § 21.8; `prototype_tools_mcp_extension_plan.md` step 13).
//
// Behind a profile setting (the CLI-server-colocated-with-VS-Code case), each
// of the extension's tools is wrapped as a [VsCodeBrainTool] and registered
// alongside the built-in tools. Because the extension's tool descriptor
// already matches § 21.2's `BrainTool` shape, the merge is uniform: a merged
// VS Code tool and a built-in tool are indistinguishable to `tool.list` /
// `tool.invoke`, and the one `ToolPolicy` (step 5) governs both — including
// the § 21.8 motivating rule `deny: [vscode.todo.*]`, which hides the editor's
// todo tools so the brain's in-process `todo.*` (§ 21.4) wins.
//
// A merged tool is a stateless descriptor like every other `BrainTool`: it
// holds the extension's [VsCodeToolDefinition] but captures no live
// capability. Its effect is forwarded through the run's [VsCodeToolSource],
// reached only via the `ToolContext.vscode` surface (PE-1) — the same pattern
// the `procedure.*` / `web.*` tools use for their engine / web surfaces.

import 'brain_tool.dart';
import 'tool_context.dart';
import 'tool_failures.dart' show ToolSurfaceUnavailable;
import 'tool_group.dart';
import 'tool_registry.dart';
import 'vscode_tool_source.dart';

/// The surface name a [VsCodeBrainTool] reports when its run carries no
/// [ToolContext.vscode] (the `ToolSurfaceUnavailable` discriminator).
const String vsCodeToolSurfaceName = 'vscode';

/// A built-in-shaped wrapper around one colocated VS Code extension tool
/// (§ 21.8).
///
/// Group [ToolGroup.vscode] and (conservatively) `readOnly == false`: the
/// extension's descriptor carries no read/write flag, so a merged tool is
/// treated as effectful — under a `read_only` policy it is hidden, the safe
/// default. The name / description / input schema mirror the
/// [VsCodeToolDefinition]; [run] forwards the call through the run's
/// [VsCodeToolSource].
final class VsCodeBrainTool extends BrainTool {
  /// The extension tool this wraps.
  final VsCodeToolDefinition definition;

  /// Wraps [definition] as a `vscode`-group `BrainTool`.
  VsCodeBrainTool(this.definition);

  @override
  String get name => definition.name;

  @override
  ToolGroup get group => ToolGroup.vscode;

  @override
  bool get readOnly => false;

  @override
  String get description => definition.description;

  @override
  Map<String, Object?> get inputSchema => definition.inputSchema;

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async {
    final source = ctx.vscode;
    if (source == null) {
      throw ToolSurfaceUnavailable(surface: vsCodeToolSurfaceName, tool: name);
    }
    return source.invokeTool(name, args);
  }
}

/// Merges the [source] extension's tools into [registry] when [enabled].
///
/// [enabled] is the § 21.8 profile setting: when `false` (the extension is
/// colocated but the profile keeps its tools out), this is a no-op and nothing
/// is merged. When `true`, each tool the [source] lists is wrapped as a
/// [VsCodeBrainTool] and registered — a name clash with an already-registered
/// tool surfaces as `ToolAlreadyRegistered` through [ToolRegistry.register],
/// exactly as a built-in clash would.
Future<void> mergeVsCodeTools(
  ToolRegistry registry,
  VsCodeToolSource source, {
  required bool enabled,
}) async {
  if (!enabled) return;
  for (final definition in await source.listTools()) {
    registry.register(VsCodeBrainTool(definition));
  }
}
