// The LlmProvider contract now lives in `tom_core_agentic`.
//
// Migrated out of the substrate into the generic agent layer (TomSpecs editor
// §20 step 3 / §19 T3) so the provider seam is reusable outside the brain. The
// abstract `LlmProvider` interface is owned by `tom_core_agentic`; this file
// re-exports it so every existing `llm/llm_provider.dart` import path — and the
// `llm/` barrel surface — keeps resolving to the single canonical contract. The
// brain's HTTP / stub providers (`OllamaLlmProvider`, `OpenAiPassthroughProvider`,
// `StubLlmProvider`) still implement this interface; they stay in the substrate
// because they couple to brain-domain packages above this layer. No duplicate
// definition remains here.
export 'package:tom_core_agentic/tom_core_agentic.dart' show LlmProvider;
