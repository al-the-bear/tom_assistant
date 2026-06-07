// Barrel for the `tools/` module
// (`tom_brain_procedure_prototype_specification.md` § 21.2; Extension F
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
// `readOnly` (§ 21.8). Later steps build further: § 21.3 adds the MCP client,
// § 21.4 registers the basic tool set, and the `tool.list` / `tool.invoke`
// bridged primitives wire the registry + policy into the d4rt host.

export 'brain_tool.dart';
export 'tool_context.dart';
export 'tool_denied.dart' show ToolDenial, toolDeniedCode;
export 'tool_errors.dart' show ToolAlreadyRegistered, toolAlreadyRegisteredCode;
export 'tool_group.dart' show ToolGroup;
export 'tool_input_schema.dart' show validateToolArgs;
export 'tool_policy.dart' show ToolPolicy;
export 'tool_policy_config.dart' show ToolPolicyConfig;
export 'tool_registry.dart' show ToolRegistry;
