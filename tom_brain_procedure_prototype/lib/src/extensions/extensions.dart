// Barrel for the `extensions/` module (Extension F step 15;
// `tom_brain_procedure_prototype_specification.md` § 13, § 21.5, § 21.6).
//
// The Extension-F *composition* layer: it sits above `config/`, `tools/`, and
// `mcp/` and assembles their pieces into the one bundle the engine holds.
//
//   - `BrainExtensionConfig` — the declarative input: the `prompt_template/` +
//     `llm_configuration/` directories, the parsed `mcpServers:` registry, the
//     `ToolPolicyConfig`, and the prompt types to validate eagerly at boot.
//   - `BrainEngineExtensions` — the assembled runtime bundle (`ToolRegistry` +
//     `McpClient` + the three config stores + the tool policy), built once per
//     process by `assemble` and threaded onto `ProcedureEngine` so a future
//     `call_llm_v1` can read it. Carries no per-run state.
//
// Why this is its own module, not part of `config/`: it imports `config/`,
// `tools/`, and `mcp/`, so placing it in `config/` would make `config/` depend
// on `tools/` + `mcp/`, inverting the existing `tools → config` arrow into a
// cycle. `extensions/` sits *above* all three; `api/` imports it for the
// engine's optional bundle field, and `extensions/` never imports `api/`.

export 'brain_engine_extensions.dart' show BrainEngineExtensions;
export 'brain_extension_config.dart' show BrainExtensionConfig;
