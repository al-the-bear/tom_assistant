// The LlmStreamEvent family now lives in `tom_core_agentic`.
//
// Migrated out of the substrate into the generic agent layer (TomSpecs editor
// §20 step 3 / §19 T3) so the provider seam is reusable outside the brain. The
// sealed `LlmStreamEvent` sum, its five variants, and the `LlmFailure`
// envelope are owned by `tom_core_agentic`; this file re-exports them so every
// existing `api/llm_stream_event.dart` import path — and the `api/` barrel
// surface — keeps resolving to the single canonical types. No duplicate
// definition remains here.
export 'package:tom_core_agentic/tom_core_agentic.dart'
    show
        LlmStreamEvent,
        LlmStreamStarted,
        LlmStreamChunk,
        LlmStreamToolCallProposed,
        LlmStreamCompleted,
        LlmStreamFailed,
        LlmFailure;
