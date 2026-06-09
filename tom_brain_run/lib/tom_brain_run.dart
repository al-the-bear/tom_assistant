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
/// `tom_brain_memory`, `tom_brain_procedure_prototype`, and
/// `tom_brain_access_prototype` together — fulfilling the access package's
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
export 'src/brain_run_config_loader.dart'
    show BrainRunConfigException, BrainRunConfigLoader;
export 'src/brain_substrate_builder.dart'
    show
        NoWebFetch,
        NoWebSearch,
        buildSubstrate,
        buildWebFetch,
        buildWebSearch;
export 'src/provision_brain.dart'
    show
        BrainProcess,
        brainProvisioner,
        provisionBrain,
        standUpBrainProcess,
        standUpBrainProcessFromConfig;

// ── Trail config + mode + banner (logging-spec §4.1 / §8; §10 step #1) ─
export 'src/trail_banner.dart' show TrailBanner;
export 'src/tools_config.dart' show ToolsConfig, ToolsConfigException;
export 'src/tools_config_loader.dart' show ToolsConfigLoader;
export 'src/trail_config.dart' show TrailConfig, TrailConfigException, TrailMode;
export 'src/trail_config_loader.dart' show TrailConfigLoader;

// ── Raw LLM-call trail writer (logging-spec §5.2 / §5.1; §10 step #4) ──
export 'src/llm_trail_writer.dart'
    show LlmTrailHeadlineSink, LlmTrailWriter;

// ── Raw incoming-prompt trail writer (logging-spec §5.3; §10 step #7) ──
export 'src/incoming_trail_writer.dart' show IncomingTrailWriter;

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
