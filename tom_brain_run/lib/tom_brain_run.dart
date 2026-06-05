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
    show NoWebFetch, NoWebSearch, buildSubstrate;
export 'src/provision_brain.dart'
    show
        BrainProcess,
        brainProvisioner,
        provisionBrain,
        standUpBrainProcess,
        standUpBrainProcessFromConfig;
