// AgentSdkLlmProvider now lives in `tom_core_agentic`.
//
// Migrated out of the run layer into the generic agent layer (TomSpecs editor
// §20 step 3 / §19 T3) so the Anthropic-Agent-SDK provider is reusable outside
// the brain (the TomSpecs editor consumes it over the VS Code bridge). The
// provider implementation is owned by `tom_core_agentic`; this file re-exports
// it so every existing `agent_sdk_llm_provider.dart` import path keeps
// resolving to the single canonical type. No duplicate definition remains here.
export 'package:tom_core_agentic/tom_core_agentic.dart' show AgentSdkLlmProvider;
