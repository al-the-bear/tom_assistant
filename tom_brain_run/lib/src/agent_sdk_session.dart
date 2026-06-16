// Agent-SDK session strategies now live in `tom_core_agentic`.
//
// Migrated out of the run layer into the generic agent layer (TomSpecs editor
// §20 step 3 / §19 T3) so the Agent-SDK provider path is reusable outside the
// brain (the TomSpecs editor consumes it over the VS Code bridge). The session
// strategy interface, its three implementations, the session store, and the
// session-error classifier are owned by `tom_core_agentic`; this file
// re-exports them so every existing `agent_sdk_session.dart` import path keeps
// resolving to the single canonical types. No duplicate definition remains here.
export 'package:tom_core_agentic/tom_core_agentic.dart'
    show
        AgentSdkSessionStrategy,
        NoSessionStrategy,
        AgentSdkSessionStore,
        BrainSessionStrategy,
        QuestSessionStrategy,
        agentSdkLooksLikeSessionError;
