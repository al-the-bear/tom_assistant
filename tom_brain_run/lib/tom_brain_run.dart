/// The real (non-stub) higher assembly for the Tom Brain prototype.
///
/// The production sibling of `tom_brain_smoke_prototype`. Where the smoke boots
/// a *stub* substrate + an in-isolate *memory double*, this package boots the
/// **real** substrate (router → `OpenAiPassthroughProvider`@oMLX for the LLM,
/// `OllamaEmbeddingService` for embeddings) and the **real on-disk
/// `SqliteTomBrainMemory`** (isolate-hosted via the production
/// `createSqliteTomBrainMemory` factory), projects the `RunCoordinator` onto a
/// `QueueSnapshot`, and stands the access process up on a port.
///
/// It is the one production place that may legally wire `tom_brain_substrate`,
/// `tom_brain_memory`, `tom_brain_procedure`, and
/// `tom_brain_access` together — fulfilling the access package's
/// `BrainProvisioner` seam, whose default refuses because the access package
/// cannot boot a brain on its own (it must not import substrate / memory). See
/// Plan-2 steps #30 / #31 of `prototype_implementation_plan_2.md`.
///
/// Surface:
///
///   * [buildSubstrate] — the real substrate composition root: manufactures an
///     `InProcessTomBrainSubstrate` from a parsed `SubstrateConfig`
///     (openai → oMLX passthrough, ollama transports, Ollama embeddings,
///     no-web tools).
///   * [BrainRunConfig] / [BrainRunConfigLoader] — the whole-process YAML
///     config (substrate + memory + access) and the loader that parses it by
///     delegating each section to its owning loader.
///   * [provisionBrain] — boots the cognition over an injected substrate + a
///     real `MemoryConfig` and hands back a `ProvisionedBrain`.
///   * [brainProvisioner] — [provisionBrain] bound into the access package's
///     `BrainProvisioner` typedef, for the standalone `serve` path.
///   * [standUpBrainProcess] — provision + `startBrainAccessProcess`, returning
///     a [BrainProcess] handle (the production sibling of `standUpSmokeProcess`).
///   * [standUpBrainProcessFromConfig] — the single entry point from a loaded
///     [BrainRunConfig] to a running [BrainProcess].
library;

export 'src/brain_run_config.dart' show BrainRunConfig;
export 'src/builtin_bindings.dart' show BrainBuiltins;
export 'src/cognition_run_config.dart'
    show CognitionRunConfig, CognitionRunConfigException;
export 'src/cognition_run_config_loader.dart' show CognitionRunConfigLoader;
export 'src/cognition_config.dart'
    show
        CatalogueConfigFile,
        CatalogueConfigKind,
        CataloguePart,
        CatalogueRole,
        CatalogueTemplate,
        CatalogueTemplateFile,
        CognitionCatalogue,
        CognitionConfig,
        CognitionConfigException,
        CognitionRegistry,
        FragmentTemplateFiles,
        PromptKind,
        PromptSettings,
        PromptTemplateFiles,
        RegisteredProcedure,
        ResolvedPrompt,
        ResolvedTemplateFile,
        TemplateResolution,
        ToolsAll,
        ToolsExplicit,
        ToolsNone,
        ToolsReadonly,
        ToolsSetting,
        UnregisteredPromptException;
export 'src/cognition_config_loader.dart' show CognitionConfigLoader;
export 'src/cognition_prompt_resolver.dart'
    show
        buildBundledPromptResolver,
        buildOverlayPromptResolver,
        buildPromptResolver,
        buildRouteChainResolver;
export 'src/model_switch.dart'
    show
        CognitionModelWriteException,
        CognitionModelWriter,
        TomBrainModelSwitcher;
export 'src/cli_server_port_switch.dart'
    show
        CliServerPortConfigWriter,
        CliServerPortWriteException,
        TomBrainCliServerPortController;
export 'src/api_key_persist.dart'
    show ApiKeyPersistException, appendApiKeyToRunConfig;
export 'src/llm_route_config.dart' show LlmRouteConfig, UnknownLlmRouteException;
export 'src/brain_run_config_loader.dart'
    show BrainRunConfigException, BrainRunConfigLoader;
export 'src/brain_substrate_builder.dart'
    show
        NoWebFetch,
        NoWebSearch,
        buildSubstrate,
        buildWebFetch,
        buildWebSearch;
export 'src/agent_sdk_llm_provider.dart' show AgentSdkLlmProvider;
export 'src/agent_sdk_session.dart'
    show
        AgentSdkSessionStore,
        AgentSdkSessionStrategy,
        BrainSessionStrategy,
        NoSessionStrategy,
        QuestSessionStrategy,
        agentSdkLooksLikeSessionError;
export 'src/provision_brain.dart'
    show
        BrainProcess,
        brainProvisioner,
        buildDreamHistoryCompactor,
        provisionBrain,
        standUpBrainProcess,
        standUpBrainProcessFromConfig;

// ── Legacy-store migration (memory-session-profiles § 11; plan step 8) ─
export 'src/legacy_store_migration.dart'
    show LegacyMigrationOutcome, migrateLegacyMemoryRoot;

// ── Scheduled dream cadence driver (memory-spec § 9.7; G-M3) ──────────
export 'src/dream_cadence_driver.dart'
    show
        CadenceSchedule,
        DreamCadenceDriver,
        DreamLaneSpec,
        FireOutcome,
        MaintenanceFire;
export 'src/dream_cadence_wiring.dart'
    show
        DreamCadenceLoop,
        dreamCadenceDriverOverScheduler,
        fireThroughScheduler;
export 'src/dream_throttle.dart'
    show DreamThrottle, DreamThrottleSettings;
export 'src/dream_window_schedule.dart'
    show DreamWindow, DreamWindowSchedule;
export 'src/dream_controller.dart'
    show DreamController, DreamModeKind, DreamStatus;
export 'src/late_dream_surface.dart' show LateDreamSurface;
export 'src/dream_config.dart' show DreamConfig, DreamConfigException;
export 'src/dream_config_loader.dart' show DreamConfigLoader;

// ── Trail config + mode + banner (logging-spec §4.1 / §8; §10 step #1) ─
export 'src/trail_banner.dart' show TrailBanner;
export 'src/observatory_banner.dart' show ObservatoryBanner;
export 'src/observatory_isolate_host.dart'
    show ObservatoryHostLog, ObservatoryIsolateHost, spawnObservatoryIsolate;
// The in-process memory MCP server the observatory's /api/memory/* routes
// connect to — hosted alongside the observatory so the whole inspection surface
// comes up in one process.
export 'src/memory_mcp_isolate_host.dart'
    show MemoryMcpHostLog, MemoryMcpIsolateHost, spawnMemoryMcpIsolate;
// Re-exported so callers configure the in-process observatory without importing
// the observatory package directly (the run layer owns its lifecycle).
export 'package:tom_brain_observatory/tom_brain_observatory.dart'
    show ObservatoryOptions, RuntimeSnapshot;
// ── Compiled-in asset bundle (tom_brain_cli.md §4; CLI plan step 4) ───
export 'src/bundle/bundle_manifest.dart' show BundleManifest;
export 'src/bundle/brain_bundle.g.dart' show brainBundle;
export 'src/bundle/bundle_codegen.dart'
    show BundleCodegenException, buildBundleManifest, renderBundleSource;
export 'src/bundle/bundle_listing.dart' show renderBundleListing;
export 'src/bundle/bundled_sqlite_vec.dart'
    show
        BundledSqliteVec,
        SqliteVecOrigin,
        SqliteVecResolution,
        SqliteVecUnavailable,
        resolveSqliteVecBinariesRoot;
export 'src/scripts_config.dart' show ScriptsConfig, ScriptsConfigException;
export 'src/scripts_config_loader.dart' show ScriptsConfigLoader;

// ── The unified `tom_brain` CLI (tom_brain_cli.md § 5; CLI plan step #8) ──────
export 'src/cli/config_overlay.dart'
    show deepMergeMaps, emitYamlDoc, setDottedKey;
export 'src/cli/tom_brain_tool.dart'
    show
        defaultServeAnthropicPort,
        defaultServeOllamaPort,
        defaultServeOpenAiPort,
        normalizeSubcommand,
        tomBrainBundleCommandName,
        tomBrainCommandNames,
        tomBrainInitCommandName,
        tomBrainMemoryMcpCommandName,
        tomBrainObservatoryCommandName,
        tomBrainServeCommandName,
        tomBrainTool,
        tomBrainVersion,
        tomBrainVersionString;
export 'src/cli/serve_config_assembler.dart'
    show
        ServeAssembly,
        ServeConfigAssembler,
        ServeConfigException,
        ServeRuntimeOptions,
        assembleServeConfig;
export 'src/cli/serve_runner.dart'
    show
        BrainServeSession,
        ServeBoot,
        ServeNarrate,
        defaultServeBoot,
        runBrainServe;
export 'src/cli/cli_executors.dart'
    show
        BundleCommandExecutor,
        InitCommandExecutor,
        MemoryMcpCommandExecutor,
        ObservatoryCommandExecutor,
        ServeCommandExecutor,
        createTomBrainExecutors,
        defaultStandaloneMemoryMcpPort;
export 'src/cli/init_scaffold.dart'
    show
        InitScaffoldException,
        InitScaffoldResult,
        scaffoldAgentSkeleton;

// ── The --home/agent directory-convention resolver (tom_brain_cli.md § 2 / § 6
//    / § 8; CLI plan step #6) ─────────────────────────────────────────────
export 'src/project_home.dart'
    show HomeOverrides, PathLayer, ProjectHome, ResolvedPath;
// ── CLI `${env:…}` flag expansion (tom_brain_cli.md § 5 note / § 11.7;
//    CLI plan step #7) ──────────────────────────────────────────────────────
export 'src/cli_env_expansion.dart'
    show CliEnvExpansionException, expandCliFlag, expandCliFlags, expandSetValue;
export 'src/tools_config.dart' show ToolsConfig, ToolsConfigException;
export 'src/tools_config_loader.dart' show ToolsConfigLoader;

// ── The in-process embedding facade (tom_brain_cli.md § 10; CLI plan step
//    #10) ────────────────────────────────────────────────────────────────
export 'src/embed/tom_brain.dart'
    show
        BrainApiKey,
        BrainConfig,
        BrainEmbedding,
        BrainOverrides,
        BrainProvider,
        BrainRoute,
        PromptSource,
        ScriptSource,
        TomBrain;

// ── Profile selection axis: config DTO + boot registry (session_configuration
//    plan step 3; spec § 3) ──────────────────────────────────────────────
export 'src/profile/profile.dart' show Profile;
export 'src/profile/profile_config_errors.dart'
    show ProfileConfigException, UnknownProfileException;
export 'src/profile/profile_registry.dart'
    show ProfileAuthoringContext, ProfileRegistry;
export 'src/trail_config.dart' show TrailConfig, TrailConfigException, TrailMode;
export 'src/trail_config_loader.dart' show TrailConfigLoader;

// ── Raw LLM-call trail writer (logging-spec §5.2 / §5.1; §10 step #4) ──
export 'src/llm_trail_writer.dart'
    show LlmTrailHeadlineSink, LlmTrailWriter;

// ── Raw incoming-prompt trail writer (logging-spec §5.3; §10 step #7) ──
export 'src/incoming_trail_writer.dart' show IncomingTrailWriter;

// ── Telegram inspection ports: the run-layer reads behind the edge's
//    /observatory_*, /show_logs, /memory_status, /check_status commands ───────
export 'src/telegram_inspector_impls.dart'
    show
        CognitionPromptsInspector,
        LiveStopController,
        LiveUsageInspector,
        McpServersInspector,
        MemoryStatsInspector,
        SessionTodosInspector,
        SubstrateModelsInspector,
        ToolCatalogueInspector,
        TrailIncomingPromptInspector,
        TrailLogInspector,
        TrailStatusInspector;
export 'src/mcp_channel_factory.dart' show productionMcpChannelFactory;
export 'src/mcp_liveness_monitor.dart'
    show McpLivenessMonitor, McpProbe, McpEvict;
export 'src/mcp_offered_wiring.dart'
    show mcpLivenessMonitorOverClient, mcpOfferedGate;

// ── Per-profile memory log writer (logging-spec §5.6; §10 step #8) ────
export 'src/memory_profile_log_writer.dart' show MemoryProfileLogWriter;

// ── Per-procedure combined run-tree writer (logging-spec §5.7; §10 step #9) ─
export 'src/procedure_tree_writer.dart' show ProcedureTreeWriter;

// ── Trail janitor: raw-tier count/size caps + .gitignore (logging-spec §7 /
//    §8; §10 step #10) ──────────────────────────────────────────────────
export 'src/trail_janitor.dart' show TrailJanitor;

// ── Summary fan-out: the §5.4 / §5.5 / §5.8 versioned narratives, derived from
//    the same call records the raw writer dumps (§10 step #5) ──────────────
export 'src/summary_fanout.dart'
    show
        CallProjectionWriter,
        GlobalSummaryWriter,
        SessionSummaryWriter,
        SummaryFanout;

// ── Streaming per-session live-trail: the §5.9 quest-live-trail-format surface,
//    written step-by-step from the four per-step sinks (§10 step #6) ─────────
export 'src/streaming_live_trail.dart' show StreamingLiveTrailWriter;

// ── Retrieval eval harness (Plan-2 ext step #33; spec § 23.8) ─────────
export 'src/eval/procedure_engine_eval_environment.dart'
    show
        EvalProfileBinder,
        EvalProfileBinding,
        ProcedureEngineEvalEnvironment,
        evalDocToDraft,
        evalIdsFromRecall;
export 'src/eval/retrieval_eval_config.dart'
    show
        EvalCorpusItem,
        EvalExpectation,
        EvalQuery,
        RetrievalEvalConfig,
        RetrievalEvalConfigException,
        StrategySetSpec;
export 'src/eval/retrieval_eval_environment.dart'
    show EvalSeedDoc, RetrievalEvalEnvironment;
export 'src/eval/retrieval_eval_harness.dart' show RetrievalEvalHarness;
export 'src/eval/retrieval_eval_report.dart' show RetrievalEvalReport;
export 'src/eval/retrieval_metrics.dart'
    show
        allRetrievalMetrics,
        mrrMetric,
        ndcgAtK,
        ndcgMetric,
        precisionAtK,
        precisionAtKMetric,
        recallAtK,
        recallAtKMetric,
        reciprocalRank,
        scoreQuery;
