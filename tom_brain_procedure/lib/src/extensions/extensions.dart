// Barrel for the `extensions/` module
// (`tom_brain_procedure_specification.md` § 13).
//
// The Extension-F composition layer (`BrainEngineExtensions` /
// `BrainExtensionConfig`) was retired with the scripted `call_llm_v1` loop
// (increment 9): it assembled the three-layer LLM config stores for an LLM
// loop that `sub.run` / `tool_loop_v1` now own, and nothing reads it any more.
// What survives is the module's logging taxonomy.

// Extension F step 16 — the Extension-F logging categories (§ 13).
export 'extension_log.dart' show ExtensionLog, ExtensionLogCategory;
