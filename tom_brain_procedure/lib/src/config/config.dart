// Barrel for the `config/` module (Plan step C.8).
//
// Owns engine configuration and observability
// (`tom_brain_procedure_specification.md` § 11, Plan steps
// C.42–C.45):
//
//   - `EngineConfig` — YAML loader for the `scripts/system/` path,
//     `scripts/user/` path, sandbox switches, and deadline defaults.
//   - `TomLogger` categories: `tom_brain.engine.host`, `…bridge`,
//     `…store`, `…recorder`, `…preemption`.
//   - `EngineEvent` stream: `InvocationStarted`, `PrimitiveCalled`,
//     `StepYielded`, `InvocationCompleted`, `InvocationFailed`.
//
// Wiring across later Phase C steps:
//
//   - C.17 ✅ — `SandboxConfig` (`sandbox_config.dart`): the two host
//     sandbox switches (`enableUnixCommands`, `enableVsCodeIntegration`),
//     both disabled by default. The full `EngineConfig` (C.42) carries
//     a `SandboxConfig` as its "sandbox switches" field.
//   - C.42 ✅ — `EngineConfig` YAML loader (`engine_config.dart`): the
//     `scripts/system/` + `scripts/user/` paths, the `SandboxConfig`
//     switches, and the hard per-step deadline, loaded from a small YAML
//     document via the `yaml` package. Malformed documents are funnelled
//     through `EngineConfigInvalid` (`engine_config_invalid.dart`).
//   - C.43 ✅ — `TomLogger` category wiring (`engine_log.dart`): the
//     closed `EngineLogCategory` enum of the five engine categories
//     (`tom_brain.engine.host`, `…bridge`, `…store`, `…recorder`,
//     `…preemption`) and the `EngineLog` const-instance facade with the
//     five `EngineLog.<area>` statics. Call sites use
//     `EngineLog.host.status('…')`; the wrapper prepends
//     `'[tom_brain.engine.<area>] '` and forwards to `tomLog`. Mirrors
//     `MemoryLog` (A.84) and `SubstrateLog` (B.37).
//   - C.44 ✅ — `EngineEvent` sealed sum (`engine_event.dart`): the five
//     typed observability variants (`InvocationStarted`,
//     `PrimitiveCalled`, `StepYielded`, `InvocationCompleted`,
//     `InvocationFailed`), each extending `BrainEvent` (shared base) with
//     a `runId`-required narrowing. The `EngineEventBus`
//     (`engine_event_bus.dart`) is the broadcast fan-in
//     (`emit` / `events()` / `close()`) the composition root wires to the
//     engine. Mirrors `SubstrateEventBus` (B.38) / `MemoryEventBus` (A.85).
//   - C.45 ✅ — config + observability slice-closure conformance suite
//     (`test/c45_config_and_observability_test.dart`): the three plan-named
//     properties (config roundtrip, event ordering, logger categorisation)
//     plus the cross-slice event+log pairing gate, asserted together on the
//     public surface only. Mirrors substrate's B.39. Subphase C.11 closed.
//   - D.47 ✅ — `DispatcherConfig` YAML loader (`dispatcher_config.dart`): the
//     dispatcher's four knobs — the `scripts/system/` + `scripts/user/` paths,
//     the foreground queue depth, the coordinator hard step deadline, and the
//     free-time-scheduler enabled flag — loaded from a small YAML document via
//     the `yaml` package, mirroring `EngineConfig` (C.42). Malformed documents
//     are funnelled through `DispatcherConfigInvalid`
//     (`dispatcher_config_invalid.dart`).
//   - D.48 ✅ — `TomLogger` dispatcher-category wiring
//     (`dispatcher_log.dart`): the closed `DispatcherLogCategory` enum of
//     the five dispatcher categories (`tom_brain.dispatcher.entry`,
//     `…coordinator`, `…fallback`, `…scheduler`, `…boot`) and the
//     `DispatcherLog` const-instance facade with the five
//     `DispatcherLog.<area>` statics. Call sites use
//     `DispatcherLog.entry.status('…')`; the wrapper prepends
//     `'[tom_brain.dispatcher.<area>] '` and forwards to `tomLog`. Mirrors
//     `EngineLog` (C.43).

export 'dispatcher_config.dart'
    show
        DispatcherConfig,
        defaultDispatcherHardStepDeadline,
        defaultForegroundQueueDepth,
        defaultSchedulerEnabled;
export 'dispatcher_config_invalid.dart'
    show DispatcherConfigInvalid, dispatcherConfigInvalidCode;
export 'dispatcher_log.dart' show DispatcherLog, DispatcherLogCategory;
export 'engine_config.dart'
    show EngineConfig, defaultSystemScriptsPath, defaultUserScriptsPath;
export 'engine_config_invalid.dart'
    show EngineConfigInvalid, engineConfigInvalidCode;
export 'engine_event.dart'
    show
        EngineEvent,
        InvocationCompleted,
        InvocationFailed,
        InvocationStarted,
        PrimitiveCalled,
        StepYielded;
export 'engine_event_bus.dart' show EngineEventBus;
export 'engine_log.dart' show EngineLog, EngineLogCategory;
// Extension G step 25 — the history config split (§ 22.6) + the history
// subsystem's typed observability taxonomy + bus (§ 22.10).
export 'history_event.dart'
    show
        HistoryCompactionFailed,
        HistoryCompactionTruncated,
        HistoryEvent,
        HistoryEventSink,
        HistoryRemoteToolNoSession,
        HistorySessionUnknown,
        HistoryWireMalformed;
export 'history_event_bus.dart' show HistoryEventBus;
export 'history_policy.dart'
    show HistoryPolicy, defaultHistoryCompactionTemplate;
// Extension F step 16 — the scripted-LLM-loop observability stream (§ 13).
export 'llm_event.dart'
    show
        LlmLoopBudgetExceeded,
        LlmLoopCompleted,
        LlmLoopEvent,
        LlmLoopEventSink,
        LlmLoopStarted,
        LlmLoopTurn,
        ToolTurnDispatched;
export 'llm_event_bus.dart' show LlmLoopEventBus;
export 'llm_config_errors.dart' show LlmConfigInvalid, llmConfigInvalidCode;
// Extension H step #31 — the `memory_retrieval/` config family (§ 23.4):
// the typed catalogue model, its strategy/budget/fusion/diversity/rerank/
// selection blocks, and the two typed load-failure wire codes.
export 'memory_retrieval_config.dart'
    show
        DiversitySettings,
        FusionSettings,
        MemoryRetrievalConfig,
        RerankSettings,
        RetrievalBudget,
        SelectionSettings,
        StrategyConfig;
export 'memory_retrieval_config_invalid.dart'
    show
        MemoryRetrievalConfigInvalid,
        memoryRetrievalConfigInvalidCode,
        retrievalConfigLlmInMemoryCode;
export 'sandbox_config.dart' show SandboxConfig;
// The provider wire tool-call protocol enum, relocated here when the three-layer
// LLM config scaffold (`provider_config.dart`) was retired with the scripted
// `call_llm_v1` loop (increment 9). The substrate bridge's `ToolProtocolResolver`
// switches on it.
export 'tool_protocol.dart' show ToolProtocol;
