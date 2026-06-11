// Barrel for the `tools/` module
// (`tom_brain_procedure_specification.md` § 21.2; Extension F
// step 4).
//
// The tool-calling core the scripted LLM loop (`call_llm_v1`, § 21.1) runs
// on: a `BrainTool` descriptor, the closed `ToolGroup` family, the
// `ToolRegistry` the `tool.list` / `tool.invoke` primitives read, the
// `ToolContext` that is a tool's *entire* effect surface (PE-1), the
// `validateToolArgs` gate `tool.invoke` applies before running, and the
// typed `ToolAlreadyRegistered` wiring failure.
//
// Extension F step 5 layers the four-profile `ToolPolicy` (and its
// `ToolPolicyConfig` / typed `ToolDenial` refusal) on top of `group` +
// `readOnly` (§ 21.8). Extension F step 7 registers the basic tool set
// (`registerBasicTools`, § 21.4) — fifteen `BrainTool`s routing through the
// existing primitives, the run-scoped `TodoStore`, and the optional
// `ToolWebSurface` / `ToolEngineSurface`, raising the typed tool failures when
// a boundary is crossed. Later steps build further: § 21.3 adds the MCP
// client, and the `tool.list` / `tool.invoke` bridged primitives wire the
// registry + policy into the d4rt host.

export 'basic_tools.dart'
    show defaultToolCatalogue, registerBasicTools, writableNodeShapes;
export 'brain_tool.dart';
export 'file_scope.dart' show FileScope;
export 'todo_store.dart' show TodoEntry, TodoStore;
export 'tool_context.dart';
export 'tool_denied.dart' show ToolDenial, toolDeniedCode;
export 'tool_dream_surface.dart' show ToolDreamSurface;
export 'tool_engine_surface.dart' show ToolEngineSurface;
// Extension F step 16 — the tool observability stream (§ 13).
export 'tool_event.dart'
    show
        ToolDenied,
        ToolEvent,
        ToolEventSink,
        ToolFailed,
        ToolInvoked,
        ToolListed;
export 'tool_event_bus.dart' show ToolEventBus;
export 'tool_errors.dart' show ToolAlreadyRegistered, toolAlreadyRegisteredCode;
export 'tool_failures.dart'
    show
        FileScopeViolation,
        NodeShapeNotWritable,
        ProcessExecutableNotAllowed,
        ScriptResultNotJson,
        ToolSurfaceUnavailable,
        fileScopeViolationCode,
        nodeShapeNotWritableCode,
        processExecutableNotAllowedCode,
        scriptResultNotJsonCode,
        toolSurfaceUnavailableCode;
export 'tool_group.dart' show ToolGroup;
export 'process_run_surface.dart' show ProcessRunToolSurface;
export 'tool_process_surface.dart'
    show ProcessRunResult, ToolProcessSurface;
export 'tool_input_schema.dart' show validateToolArgs;
export 'tool_policy.dart' show ToolPolicy;
export 'tool_policy_config.dart' show ToolPolicyConfig;
export 'tool_registry.dart' show ToolRegistry;
export 'substrate_tool_web_surface.dart' show SubstrateToolWebSurface;
export 'tool_web_surface.dart' show ToolWebSurface;
// Extension F step 13 — the VS Code extension tool merge (§ 21.8).
export 'vscode_tool_source.dart' show VsCodeToolDefinition, VsCodeToolSource;
export 'vscode_tools.dart'
    show VsCodeBrainTool, mergeVsCodeTools, vsCodeToolSurfaceName;
