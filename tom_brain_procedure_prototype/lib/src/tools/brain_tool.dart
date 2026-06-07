// BrainTool — one tool the LLM loop can call
// (`tom_brain_procedure_prototype_specification.md` § 21.2, § 21.4).
//
// A `BrainTool` is the unit the `ToolRegistry` holds and the `tool.list` /
// `tool.invoke` primitives expose. The shape matches § 21.2 exactly:
//
//   BrainTool { name; group; readOnly; description; inputSchema;
//               run(args, ctx) }
//
// `group` (§ 21.2) and `readOnly` drive the `ToolPolicy` profiles (§ 21.8).
// `inputSchema` is the JSON-Schema fragment `tool.invoke` validates `args`
// against before running (§ 21.2); its shape mirrors VS Code's
// `ToolDefinitionJson` so the two tool registries unify (§ 21.8). `run`
// receives the validated `args` and the run's [ToolContext] — the only
// surface it may touch (PE-1).

import 'tool_context.dart';
import 'tool_group.dart';

/// A single tool the scripted LLM loop can list and invoke (§ 21.2).
///
/// Subclasses are stateless descriptors: the five getters describe the tool,
/// and [run] performs its effect using only what [ToolContext] hands it. A
/// tool never reaches past its context (PE-1), so registering a tool widens
/// the loop's vocabulary but not its effect surface.
abstract class BrainTool {
  /// The tool's unique name (`memory.read`, `file.write`, …). The registry
  /// key and the `tool.invoke` selector.
  String get name;

  /// The group this tool belongs to — one policy axis (§ 21.8).
  ToolGroup get group;

  /// Whether this tool only reads. The other policy axis: a `read_only`
  /// profile admits exactly the tools whose [readOnly] is `true` (§ 21.8).
  bool get readOnly;

  /// A one-line description surfaced through `tool.list` and (for
  /// `json_text` providers) rendered into the prompt catalogue.
  String get description;

  /// The JSON-Schema fragment `args` are validated against before [run]
  /// (§ 21.2). Mirrors VS Code's `ToolDefinitionJson` input schema.
  Map<String, Object?> get inputSchema;

  /// Runs the tool against the already-validated [args], using only the
  /// bridges [ctx] exposes. Returns a JSON-serialisable result (or `null`).
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx);
}
