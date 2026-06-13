// provisionBrain / brainProvisioner / standUpBrainProcess — the real
// (non-stub) higher assembly the access package's `BrainProvisioner` seam
// anticipates (Plan-2 step #30).
//
// This is the production sibling of `standUpSmokeProcess`
// (`tom_brain_smoke_prototype`). The smoke boots a *stub* substrate + an
// in-isolate *memory double*; this file boots the **real** substrate (built by
// `buildOmlxOllamaSubstrate`) and the **real on-disk `SqliteTomBrainMemory`**,
// isolate-hosted through the production `createSqliteTomBrainMemory` factory.
//
// ── The three surfaces ───────────────────────────────────────────────
//
//   * [provisionBrain] — boots `BrainProcessBoot` over an injected substrate +
//     a real `MemoryConfig`, projects the resulting `RunCoordinator` onto a
//     `QueueSnapshot`, and hands back a `ProvisionedBrain`. This is the core
//     "real BrainProvisioner higher assembly" work. The substrate is injected
//     (not built here) so a test can boot the real memory with a *stub LLM*,
//     exactly as Plan-2 step #30 asks.
//
//   * [brainProvisioner] — the same work bound into a value matching the
//     access package's `BrainProvisioner` typedef (`(AccessConfig) →
//     ProvisionedBrain`). The standalone `serve` path (Plan-2 step #31) injects
//     this into the running process; the bound substrate + memory config are
//     captured, the `AccessConfig` argument drives only the access layer.
//
//   * [standUpBrainProcess] — the direct convenience that mirrors
//     `standUpSmokeProcess`: provision the brain, then `startBrainAccessProcess`
//     over it, returning a [BrainProcess] handle (the bound port + graceful
//     teardown). The `serve` seam binds `config.openAiPort` by default
//     (production); a test injects a seam that binds an ephemeral port.

import 'dart:io';
import 'dart:isolate';

import 'package:tom_brain_access/tom_brain_access.dart'
    show
        AccessConfig,
        AccessServeSeam,
        BrainAccessProcess,
        BrainProvisioner,
        IncomingTrailRecord,
        IncomingTrailSink,
        ProvisionedBrain,
        QueueSnapshot,
        QueueSnapshotSource,
        TelegramInspectors,
        TelegramStopController,
        TelegramTodosInspector,
        TelegramUsageInspector,
        serveWithShelfIo,
        startBrainAccessProcess;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, createSqliteTomBrainMemory;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        BootedBrain,
        BrainProcessBoot,
        BrainProcessConfig,
        ClassifyFallback,
        FileScope,
        DartMcpConnector,
        FreeTimeScheduler,
        LlmTrailRecord,
        LlmTrailSink,
        McpClient,
        McpClientToolSource,
        McpToolDefinition,
        MemoryAccessRecord,
        MemoryAccessSink,
        MemoryProvisioningConfig,
        ProcedureTreeSink,
        PromptResolver,
        RouteChainResolver,
        ToolAccessRecord,
        ToolAccessSink,
        TurnSummary,
        TurnSummarySink;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show TomBrainMemoryClient;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        RoleRegistry,
        SubstrateConfig,
        TomBrainSubstrateClient,
        bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream,
        loadFileBackedRoleRegistry;

import 'brain_run_config.dart';
import 'brain_substrate_builder.dart' show buildSubstrate;
import 'builtin_bindings.dart' show BrainBuiltins;
import 'cognition_config.dart' show CognitionConfig;
import 'cognition_config_loader.dart' show CognitionConfigLoader;
import 'cognition_prompt_resolver.dart'
    show buildPromptResolver, buildRouteChainResolver;
import 'dream_cadence_wiring.dart' show dreamCadenceDriverOverScheduler;
import 'dream_config.dart' show DreamConfig;
import 'dream_controller.dart' show DreamController;
import 'late_dream_surface.dart' show LateDreamSurface;
import 'mcp_channel_factory.dart' show productionMcpChannelFactory;
import 'model_override.dart'
    show ModelOverrideRegistry, TomBrainModelSwitcher;
import 'incoming_trail_writer.dart' show IncomingTrailWriter;
import 'llm_trail_writer.dart' show LlmTrailWriter;
import 'memory_profile_log_writer.dart' show MemoryProfileLogWriter;
import 'procedure_tree_writer.dart' show ProcedureTreeWriter;
import 'streaming_live_trail.dart' show StreamingLiveTrailWriter;
import 'summary_fanout.dart' show SummaryFanout;
import 'telegram_inspector_impls.dart'
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
import 'trail_config.dart' show TrailConfig;
import 'trail_janitor.dart' show TrailJanitor;

/// Boots the real cognition (the injected [substrate] + the real on-disk
/// isolate-hosted `SqliteTomBrainMemory`) and projects it into a
/// `ProvisionedBrain` (Plan-2 step #30).
///
/// [substrate] is the substrate the engine binds against — production passes
/// `buildOmlxOllamaSubstrate(...)`; the #30 test passes a stub LLM so the real
/// memory boots without a live model. [memoryConfig] points the store at its
/// on-disk root and the packaged `vec0` binary (the store loads the sqlite-vec
/// extension at `open`, so a real `binariesRoot` is required).
///
/// [substrateConfig] is the parsed `substrate:` config the boot opens the
/// substrate against — when non-null, `BrainProcessBoot.boot` calls
/// `substrate.open(substrateConfig)`, which validates that every routed role is
/// registered before any run issues an `llm` call. Production passes the same
/// config `buildSubstrate` manufactured the substrate from; the #30 stub-LLM
/// test passes `null` (its `SmokeSubstrate.open` is a no-op, so there is no
/// registry to validate against).
///
/// [systemScriptsDir] points the procedure store at the system-scripts
/// directory; the default resolves the procedure prototype's shipped
/// `scripts/system` (where `answer_with_memory_v1` lives), regardless of the
/// caller's working directory. [classifyFallback] replaces the dispatcher's
/// no-hint classifier fallback; [foregroundQueueDepth] caps the foreground
/// admission queue.
///
/// [toolFileScope] threads the configured two-tier file sandbox (§ 21.4) onto
/// the engine so the `file.*` tools resolve against it: a read tool against the
/// readable union, a write/delete tool against the writeable roots. `null` (the
/// default) leaves the engine on its neutral placeholder root;
/// [standUpBrainProcessFromConfig] threads `tools.readScope` / `tools.writeScope`
/// here when the `tools:` block is present.
///
/// [isolateLogRootPath] threads the trail log root (CWD when unconfigured,
/// `trail.root` in full mode — `tom_brain_logging.md` §4.1) into the memory
/// isolate so its own `tomLog` installs a `FanoutLogOutput` at the same root
/// (§5.1 / §10 step #3). `null` (the default) leaves the isolate's logging at
/// its console default — the path every test that does not exercise the file
/// sink takes.
///
/// [llmTrailSink] is the raw-LLM-call trail sink (`tom_brain_logging.md` §5.2 /
/// §10 step #4) the engine forwards each completed `llm` call's observation to.
/// `null` (the default) boots the engine with no raw LLM trail;
/// [standUpBrainProcessFromConfig] builds an `LlmTrailWriter.write` from the
/// `trail:` config and threads it here in full-trail mode.
///
/// [turnSummarySink] is the per-turn summary sink (`tom_brain_logging.md` §5.4 /
/// §5.5 / §10 step #5) the dispatch route fires once per completed user turn.
/// `null` (the default) boots with no per-turn narrative;
/// [standUpBrainProcessFromConfig] binds a `SummaryFanout.onTurnComplete` in
/// full-trail mode.
///
/// [memoryAccessSink] is the per-profile memory-log sink (`tom_brain_logging.md`
/// §5.6 / §10 step #8) the engine hands one record per bridged memory access
/// (recall / persist / edge / stackPush / …). `null` (the default) boots with no
/// per-profile memory log; [standUpBrainProcessFromConfig] binds a
/// `MemoryProfileLogWriter.write` in full-trail mode.
///
/// [procedureTreeSink] is the per-procedure combined run-tree sink
/// (`tom_brain_logging.md` §5.7 / §10 step #9) the engine hands one record per
/// top-level (or turn-less dream) run. `null` (the default) boots with no
/// per-procedure tree; [standUpBrainProcessFromConfig] binds a
/// `ProcedureTreeWriter.write` in full-trail mode.
///
/// [promptResolver] + [routeChainOf] are the two `sub.run` seams
/// (`prompt_configuration.md` §7.4 / §8): a named prompt → loaded,
/// placeholder-resolved `ResolvedPrompt`, and a named LLM route → its ordered
/// failover chain. Both `null` (the default) boots with no registered prompts,
/// so any `sub.run` raises `UnregisteredPromptException` (the pre-migration
/// prototype default); [standUpBrainProcessFromConfig] builds both from the
/// `cognition:` config tree when the block is present.
Future<ProvisionedBrain> provisionBrain({
  required TomBrainSubstrateClient substrate,
  required MemoryConfig memoryConfig,
  SubstrateConfig? substrateConfig,
  Directory? systemScriptsDir,
  ClassifyFallback? classifyFallback,
  int foregroundQueueDepth = 4,
  FileScope? toolFileScope,
  String? isolateLogRootPath,
  LlmTrailSink? llmTrailSink,
  TurnSummarySink? turnSummarySink,
  MemoryAccessSink? memoryAccessSink,
  ToolAccessSink? toolAccessSink,
  ProcedureTreeSink? procedureTreeSink,
  DreamConfig? dream,
  PromptResolver? promptResolver,
  RouteChainResolver? routeChainOf,
  McpClient? mcpClient,
  List<McpToolDefinition> mcpTools = const <McpToolDefinition>[],
}) async {
  final Directory scriptsDir =
      systemScriptsDir ?? await _resolveProcedurePrototypeScripts();

  // The `dream.control` tool (item c) reaches the cadence through the
  // `ToolDreamSurface` the engine's per-run `ToolContext` carries. That context
  // is wired *during* boot, before we have a coordinator to build the
  // controller from — so we hand the boot a late-bound holder now and bind it
  // to the real controller after the cadence is up (below). When dreaming is
  // off, no holder is wired and the tool raises `ToolSurfaceUnavailable`.
  final bool dreamEnabled = dream != null && dream.enabled;
  final LateDreamSurface? dreamHolder =
      dreamEnabled ? LateDreamSurface() : null;

  // Boot the cognition: real substrate → real on-disk memory (isolate-hosted
  // via the production factory) → engine → dispatcher.
  final booted = await BrainProcessBoot.boot(
    BrainProcessConfig(
      substrate: substrate,
      substrateConfig: substrateConfig,
      memoryProvisioning: MemoryProvisioningConfig.isolate(
        factory: createSqliteTomBrainMemory,
        memoryConfig: memoryConfig,
        isolateLogRootPath: isolateLogRootPath,
      ),
      systemScriptsDir: scriptsDir,
      foregroundQueueDepth: foregroundQueueDepth,
      toolFileScope: toolFileScope,
      classifyFallback: classifyFallback,
      llmTrailSink: llmTrailSink,
      turnSummarySink: turnSummarySink,
      memoryAccessSink: memoryAccessSink,
      toolAccessSink: toolAccessSink,
      procedureTreeSink: procedureTreeSink,
      toolDreamSurface: dreamHolder,
      promptResolver: promptResolver,
      routeChainOf: routeChainOf,
      mcpClient: mcpClient,
      mcpTools: mcpTools,
    ),
  );

  // Wire the scheduled dream cadence into startup (item b) when a `dream:` block
  // is present AND enabled. The controller owns a `DreamCadenceLoop` whose
  // heartbeat gate is its window/mode test, firing each due dream agent through
  // the free-time scheduler's background slot. We build it *after* boot because
  // the scheduler reads the booted coordinator / engine / memory client, then
  // start the gated heartbeat. An absent or disabled block leaves the cognition
  // with no background cadence — the prototype's deterministic live tests never
  // spin one (so r30 / r32 / r35 / r36 stay deterministic).
  final DreamController? dreamController =
      dreamEnabled ? _startDreamLoop(booted, dream) : null;
  // Bind the holder to the live controller so the `dream.control` tool drives
  // the running cadence (item c). `dreamHolder` is non-null exactly when the
  // controller is.
  if (dreamController != null) dreamHolder!.bind(dreamController);

  // Project the booted cognition: the access process holds only a `Dispatcher`
  // and a `QueueSnapshotSource`. We own the `RunCoordinator`, so we project its
  // live getters onto a `QueueSnapshot`. The teardown stops the dream loop (if
  // any) before `BootedBrain.shutdown` drains the coordinator, so no dream tick
  // is admitted while the cognition is tearing down.
  return ProvisionedBrain(
    dispatcher: booted.dispatcher,
    queueSnapshot: () => QueueSnapshot(
      foregroundRunning: booted.coordinator.hasForegroundRun,
      foregroundWaiting: booted.coordinator.foregroundQueueLength,
      foregroundQueueDepth: booted.coordinator.foregroundQueueDepth,
      backgroundRunning: booted.coordinator.hasBackgroundRun,
      draining: booted.coordinator.isDraining,
    ),
    // Teardown order: stop the dream loop (if any), drain + dispose the
    // cognition, then close the MCP client's connection pool (request f). The
    // client is the run assembly's to own — the engine only uses it — so its
    // pooled child processes / sockets are released here, last.
    shutdown: () async {
      if (dreamController != null) await dreamController.stop();
      await booted.shutdown();
      if (mcpClient != null) await mcpClient.close();
    },
    // Surface the booted memory's read client so the running process can build
    // the Telegram `/memory_status` inspector over it. `TomBrainMemoryClient` is
    // a `tom_brain_shared` type, so this does not pull `tom_brain_memory` into
    // the access package.
    memoryClient: booted.memory.client,
    // Surface the engine's per-session working todo lists behind the access
    // package's `TelegramTodosInspector` port, so the running process can build
    // the Telegram `/todos_list` / `/todos_clear` commands over the engine's
    // `SessionTodoStores` without the access package depending on
    // `tom_brain_procedure`.
    todosInspector:
        SessionTodosInspector(stores: booted.engine.sessionTodoStores),
    // Surface the engine's live-run registry behind the access package's
    // `TelegramUsageInspector` port, so the running process can build the
    // Telegram `/check_usage` command over the engine's `LiveRunRegistry`
    // without the access package depending on `tom_brain_procedure`.
    usageInspector: LiveUsageInspector(registry: booted.engine.liveRunRegistry),
    // Surface the engine's live-run registry behind the access package's
    // `TelegramStopController` port, so the running process can build the
    // Telegram `/stop_prompt` command over the engine's `LiveRunRegistry`
    // without the access package depending on `tom_brain_procedure`.
    stopController: LiveStopController(registry: booted.engine.liveRunRegistry),
  );
}

/// Builds and starts the scheduled dream cadence loop over the [booted]
/// cognition per the [dream] config (item b).
///
/// The cadence fires each due dream agent through a [FreeTimeScheduler] bound to
/// the booted coordinator / engine / memory client — the same single coordinator
/// the inbound foreground path drives, so a dream pass cooperatively yields to a
/// foreground arrival (PE-5). The [DreamController] gates that cadence by the
/// configured windows; its heartbeat is the config's override or the loop's
/// one-minute default. Returns the started controller so the caller can compose
/// its `stop()` into the cognition teardown.
DreamController _startDreamLoop(BootedBrain booted, DreamConfig dream) {
  final scheduler = FreeTimeScheduler(
    coordinator: booted.coordinator,
    memory: booted.memory.client,
    workFactory: (_) => null,
    engine: booted.engine,
  );
  final controller = DreamController(
    driver: dreamCadenceDriverOverScheduler(scheduler),
    schedule: dream.schedule,
    heartbeat: dream.heartbeat ?? const Duration(minutes: 1),
  );
  controller.start();
  return controller;
}

/// Binds [provisionBrain] into a value matching the access package's
/// `BrainProvisioner` typedef (`(AccessConfig) → ProvisionedBrain`).
///
/// The standalone `serve` path injects this so the running process can boot the
/// brain through the same seam the access package defines. The [substrate] and
/// [memoryConfig] are captured at build time; the `AccessConfig` the provisioner
/// receives drives only the access layer (the prototype's substrate + memory
/// are pre-built, not derived from the access config).
BrainProvisioner brainProvisioner({
  required TomBrainSubstrateClient substrate,
  required MemoryConfig memoryConfig,
  SubstrateConfig? substrateConfig,
  Directory? systemScriptsDir,
  ClassifyFallback? classifyFallback,
  int foregroundQueueDepth = 4,
  FileScope? toolFileScope,
}) =>
    (AccessConfig config) => provisionBrain(
          substrate: substrate,
          memoryConfig: memoryConfig,
          substrateConfig: substrateConfig,
          systemScriptsDir: systemScriptsDir,
          classifyFallback: classifyFallback,
          foregroundQueueDepth: foregroundQueueDepth,
          toolFileScope: toolFileScope,
        );

/// A booted, running brain process — the bound socket plus the graceful
/// teardown that tears the cognition (and its memory isolate) down.
///
/// Returned by [standUpBrainProcess]. Call [stop] once when finished; it tears
/// the access process and the booted cognition down in order (channels first,
/// then the cognition's `shutdown`). Idempotent.
final class BrainProcess {
  /// The live access process — the bound OpenAI + `/healthz` socket.
  final BrainAccessProcess _process;

  BrainProcess._(this._process);

  /// The port the OpenAI + `/healthz` socket actually bound (OS-assigned when
  /// the caller's serve seam requested the ephemeral port `0`).
  int get port => _process.port;

  /// Completes when the process has fully stopped (after [stop] or a watched
  /// shutdown signal), carrying the process exit code.
  Future<int> get completed => _process.completed;

  /// Tears the process down: stop the access channels and the access layer,
  /// then the booted cognition (drain foreground, dispose the memory isolate,
  /// close the substrate). Idempotent.
  Future<void> stop() => _process.stop();
}

/// Provisions the real brain and stands the access process up over it on a
/// local port — the production sibling of `standUpSmokeProcess` (Plan-2 #30).
///
/// [config] is the access config (ports, tokens, the edge-security policies);
/// [substrate] and [memoryConfig] are handed to [provisionBrain]. The [serve]
/// seam binds the socket — the default ([serveWithShelfIo]) binds
/// `config.openAiPort` (production); a test injects a seam that binds an
/// ephemeral port and reads it back from [BrainProcess.port].
///
/// If the access process fails to bind, the already-booted cognition is torn
/// down before the error propagates, so a bind failure never leaks the memory
/// isolate.
Future<BrainProcess> standUpBrainProcess({
  required AccessConfig config,
  required TomBrainSubstrateClient substrate,
  required MemoryConfig memoryConfig,
  SubstrateConfig? substrateConfig,
  Directory? systemScriptsDir,
  AccessServeSeam serve = serveWithShelfIo,
  ClassifyFallback? classifyFallback,
  int foregroundQueueDepth = 4,
  FileScope? toolFileScope,
  String? isolateLogRootPath,
  String? trailRoot,
  LlmTrailSink? llmTrailSink,
  TurnSummarySink? turnSummarySink,
  IncomingTrailSink? incomingTrailSink,
  MemoryAccessSink? memoryAccessSink,
  ToolAccessSink? toolAccessSink,
  ProcedureTreeSink? procedureTreeSink,
  DreamConfig? dream,
  PromptResolver? promptResolver,
  RouteChainResolver? routeChainOf,
  CognitionConfig? cognitionConfig,
  McpClient? mcpClient,
  List<McpToolDefinition> mcpTools = const <McpToolDefinition>[],
  ModelOverrideRegistry? modelOverrides,
}) async {
  final ProvisionedBrain provisioned = await provisionBrain(
    substrate: substrate,
    memoryConfig: memoryConfig,
    substrateConfig: substrateConfig,
    systemScriptsDir: systemScriptsDir,
    classifyFallback: classifyFallback,
    foregroundQueueDepth: foregroundQueueDepth,
    toolFileScope: toolFileScope,
    isolateLogRootPath: isolateLogRootPath,
    llmTrailSink: llmTrailSink,
    turnSummarySink: turnSummarySink,
    memoryAccessSink: memoryAccessSink,
    toolAccessSink: toolAccessSink,
    procedureTreeSink: procedureTreeSink,
    dream: dream,
    promptResolver: promptResolver,
    routeChainOf: routeChainOf,
    mcpClient: mcpClient,
    mcpTools: mcpTools,
  );

  final BrainAccessProcess process;
  try {
    process = await startBrainAccessProcess(
      config: config,
      brain: provisioned,
      serve: serve,
      incomingTrailSink: incomingTrailSink,
      telegramInspectors: _telegramInspectorsFor(
        trailRoot: trailRoot,
        memoryClient: provisioned.memoryClient,
        queueSnapshot: provisioned.queueSnapshot,
        todos: provisioned.todosInspector,
        usage: provisioned.usageInspector,
        stop: provisioned.stopController,
        substrateConfig: substrateConfig,
        cognitionConfig: cognitionConfig,
        mcpClient: mcpClient,
        modelOverrides: modelOverrides,
      ),
    );
  } on Object {
    // The cognition is booted but never reached a running access process —
    // tear it down so the bind failure does not leak the memory isolate.
    await provisioned.shutdown();
    rethrow;
  }

  return BrainProcess._(process);
}

/// Builds the Telegram inspection bundle the edge drives for the
/// `/observatory_*`, `/show_logs`, `/memory_status`, `/check_status`, and
/// `/todos_list` / `/todos_clear` commands.
///
/// The prompt + log inspectors read the on-disk trail, so they are wired only
/// when a [trailRoot] is configured (full-trail mode); the memory inspector is
/// wired whenever the provisioned [memoryClient] is available. The status
/// inspector stitches the live [queueSnapshot] (always available) with the
/// trail's `incoming/` + `procedures/` trees, so it too is wired only when a
/// [trailRoot] is configured. The [todos] inspector reads the engine's live
/// `SessionTodoStores` (not the trail), so it is wired whenever the provisioner
/// exposed one. The [usage] inspector reads the engine's live `LiveRunRegistry`
/// (not the trail), so it too is wired whenever the provisioner exposed one. An
/// absent member makes the edge answer the corresponding command with "not
/// available on this deployment" — the honest report for a process that did not
/// configure that surface.
TelegramInspectors _telegramInspectorsFor({
  required String? trailRoot,
  required TomBrainMemoryClient? memoryClient,
  required QueueSnapshotSource queueSnapshot,
  required TelegramTodosInspector? todos,
  required TelegramUsageInspector? usage,
  required TelegramStopController? stop,
  required SubstrateConfig? substrateConfig,
  required CognitionConfig? cognitionConfig,
  required McpClient? mcpClient,
  required ModelOverrideRegistry? modelOverrides,
}) {
  final Directory? root = trailRoot == null ? null : Directory(trailRoot);
  return TelegramInspectors(
    prompts:
        root == null ? null : TrailIncomingPromptInspector(trailRoot: root),
    logs: root == null ? null : TrailLogInspector(trailRoot: root),
    memory:
        memoryClient == null ? null : MemoryStatsInspector(client: memoryClient),
    status: root == null
        ? null
        : TrailStatusInspector(queueSnapshot: queueSnapshot, trailRoot: root),
    // The working-todo inspector does not read the trail — it reads the
    // engine's live `SessionTodoStores` — so it is wired whenever the
    // provisioner exposed one, independent of `trailRoot`.
    todos: todos,
    // The usage inspector reads the engine's live `LiveRunRegistry`, also
    // independent of `trailRoot`, so it is wired whenever one is exposed.
    usage: usage,
    // The stop controller acts on the same live `LiveRunRegistry`, also
    // independent of `trailRoot`, so it is wired whenever one is exposed.
    stop: stop,
    // The models inspector reads the parsed substrate config (not the trail),
    // so it is wired whenever the boot threaded one in.
    models: substrateConfig == null
        ? null
        : SubstrateModelsInspector(config: substrateConfig),
    // The prompt-types inspector reads the parsed cognition config (not the
    // trail), so it is wired whenever a `cognition:` tree was loaded. It also
    // reads the live override registry to call out an active `/switch_model`.
    promptTypes: cognitionConfig == null
        ? null
        : CognitionPromptsInspector(
            config: cognitionConfig,
            overrides: modelOverrides,
          ),
    // The tool-catalogue inspector reads the engine's shipped default tool set
    // — a process constant, so it is always wired.
    tools: ToolCatalogueInspector(),
    // The MCP-servers inspector reads the live outbound MCP client (request f),
    // so it is wired exactly when the cognition has an MCP client — i.e. when at
    // least one `mcpServers:` entry was configured.
    mcp: mcpClient == null ? null : McpServersInspector(client: mcpClient),
    // The model switcher (request e) needs both the cognition config (the valid
    // prompt-id space) and the substrate config (the valid provider/model
    // space) plus the live override registry it mutates, so it is wired only
    // when all three are present.
    modelSwitcher:
        cognitionConfig == null || substrateConfig == null || modelOverrides == null
            ? null
            : TomBrainModelSwitcher(
                cognition: cognitionConfig,
                substrate: substrateConfig,
                overrides: modelOverrides,
              ),
  );
}

/// Stands the whole cognition up from a parsed whole-process [runConfig]
/// (Plan-2 step #31) — the single entry point that takes a loaded
/// `BrainRunConfig` and returns a running [BrainProcess].
///
/// Manufactures the real substrate from `runConfig.substrate` (via
/// [buildSubstrate]), then provisions + stands the access process up over the
/// real on-disk memory (`runConfig.memory`) under the access policies
/// (`runConfig.access`). The same `runConfig.substrate` is threaded through the
/// boot as the `substrateConfig`, so `substrate.open` validates routed roles.
///
/// The [serve] seam binds the socket — the default ([serveWithShelfIo]) binds
/// `runConfig.access.openAiPort` (production); a test injects a seam that binds
/// an ephemeral port. A caller that needs to override the role registry or wire
/// real web tools calls [buildSubstrate] + [standUpBrainProcess] directly.
///
/// When `runConfig.cognition` is present, the two `sub.run` seams
/// (`prompt_configuration.md` §7.4 / §8) are built from the named cognition
/// config tree: [CognitionConfigLoader.loadFromDir] parses `registry.yaml` +
/// the per-procedure configs + the `llm/` routes, [buildPromptResolver] backs
/// the named-prompt seam over those (seeded with the §6 built-ins), and
/// [buildRouteChainResolver] backs the named-route seam. Absent → no resolvers
/// (any `sub.run` raises `UnregisteredPromptException`, the pre-migration
/// default).
Future<BrainProcess> standUpBrainProcessFromConfig(
  BrainRunConfig runConfig, {
  Directory? systemScriptsDir,
  AccessServeSeam serve = serveWithShelfIo,
  ClassifyFallback? classifyFallback,
  int foregroundQueueDepth = 4,
  String? isolateLogRootPath,
}) async {
  // Resolve the scripts dir once so the boot's procedure store and the §6
  // `${scripts_folder}` built-in the prompt resolver carries agree on the same
  // directory.
  final Directory scriptsDir =
      systemScriptsDir ?? await _resolveProcedurePrototypeScripts();

  // Build the two `sub.run` seams + the file-backed role registry from the
  // `cognition:` config tree (§7.1 / §7.4 / §8) when the block is present.
  PromptResolver? promptResolver;
  RouteChainResolver? routeChainOf;
  RoleRegistry? roleRegistry;
  CognitionConfig? cognitionConfig;
  // The process-lifetime model-override registry (request e). Built only when a
  // cognition tree is loaded — `/switch_model` re-points a registered prompt id,
  // so without a cognition config there is nothing to override. Both `sub.run`
  // resolvers read it, and the `/switch_model` switcher mutates it.
  ModelOverrideRegistry? modelOverrides;
  final cognition = runConfig.cognition;
  final Map<String, String> environment = Platform.environment;
  if (cognition != null) {
    cognitionConfig =
        CognitionConfigLoader.loadFromDir(cognition.root, env: environment);
    // §7.1 / §11: role prose (persona + objective) is sourced from
    // `cognition/<rolesFolder>/<role>.persona.md` + `<role>.objective.md`,
    // overlaid on the full live roster. The in-code roster supplies the
    // capability surface and the fallback for any role (or half) whose file
    // is absent or blank.
    roleRegistry = loadFileBackedRoleRegistry(
      base:
          bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningAndDream(),
      rolesDir: Directory(
        '${cognition.root}/${cognitionConfig.registry.rolesFolder}',
      ),
    );
    final builtins = BrainBuiltins.fromRunConfig(
      runConfig,
      configFolder: cognition.root,
      scriptsFolder: scriptsDir.path,
    );
    modelOverrides = ModelOverrideRegistry();
    promptResolver = buildPromptResolver(
      cognitionConfig,
      builtins,
      environment: environment,
      overrides: modelOverrides,
    );
    routeChainOf =
        buildRouteChainResolver(cognitionConfig, overrides: modelOverrides);
  }

  // The substrate uses the file-backed registry when a cognition tree was
  // loaded; otherwise `buildSubstrate` falls back to its in-code full roster.
  final TomBrainSubstrateClient substrate =
      buildSubstrate(runConfig.substrate, roleRegistry: roleRegistry);

  // Boot-time trail sweep (§8 / §10 step #10): write the §7 `.gitignore` and
  // enforce the raw-tier count / aggregate-size caps before any writer appends
  // a new file this run. Full-trail mode only — unconfigured mode writes no raw
  // tree to police (§4.1). Best-effort: the janitor swallows its own failures.
  final TrailConfig? trail = runConfig.trail;
  if (trail != null) TrailJanitor.fromConfig(trail).sweep();
  final sinks = _trailSinksFor(trail);

  // Build the outbound MCP client from the `mcpServers:` config (request f) and
  // pre-fetch its tool descriptors *once* here so every run merges them into
  // its tool registry without a per-run network round-trip. An unreachable
  // server is omitted (PE-6, in `McpClientToolSource.listTools`) rather than
  // failing boot. When no server is configured, no client is built and the MCP
  // surface is simply absent (the `mcp.*` bridge raises `ToolSurfaceUnavailable`
  // and the `/mcp_*` commands report "not available on this deployment").
  final McpClient? mcpClient = runConfig.mcpServers.servers.isEmpty
      ? null
      : McpClient(
          runConfig.mcpServers,
          DartMcpConnector(channelFactory: productionMcpChannelFactory()),
        );
  final List<McpToolDefinition> mcpTools = mcpClient == null
      ? const <McpToolDefinition>[]
      : await McpClientToolSource(mcpClient).listTools();

  return standUpBrainProcess(
    config: runConfig.access,
    substrate: substrate,
    memoryConfig: runConfig.memory,
    substrateConfig: runConfig.substrate,
    systemScriptsDir: scriptsDir,
    serve: serve,
    classifyFallback: classifyFallback,
    foregroundQueueDepth: foregroundQueueDepth,
    toolFileScope: runConfig.tools?.toFileScope(),
    isolateLogRootPath: isolateLogRootPath,
    trailRoot: trail?.root,
    llmTrailSink: sinks.llmTrailSink,
    turnSummarySink: sinks.turnSummarySink,
    incomingTrailSink: sinks.incomingTrailSink,
    memoryAccessSink: sinks.memoryAccessSink,
    toolAccessSink: sinks.toolAccessSink,
    procedureTreeSink: sinks.procedureTreeSink,
    dream: runConfig.dream,
    promptResolver: promptResolver,
    routeChainOf: routeChainOf,
    cognitionConfig: cognitionConfig,
    mcpClient: mcpClient,
    mcpTools: mcpTools,
    modelOverrides: modelOverrides,
  );
}

/// Builds the trail sinks the engine + route are wired to from the `trail:`
/// config, or `(null, null)` in unconfigured mode.
///
/// In full-trail mode (a non-null [trail]) the raw `llm/<role>/…` surface
/// (§4.1), the §5.4 / §5.5 / §5.8 summary surfaces, and the §5.9 streaming
/// per-session live-trail are all active. A single composed `LlmTrailSink` is
/// the single source the spec's §5.8 calls for: each completed call is dumped
/// raw by the [LlmTrailWriter], fanned out to the summary projections by the
/// [SummaryFanout], *and* streamed into the [StreamingLiveTrailWriter]. The
/// other three per-step sinks (incoming, memory, turn-summary) likewise fan out
/// to both their writer and the live-trail, so the §5.9 surface streams the
/// turn's thinking + tool calls step by step. The `incomingTrailSink` is the §5.3 raw incoming-prompt writer,
/// fired per admitted request by the access layer. The `memoryAccessSink` is the
/// §5.6 per-profile memory-log writer, fired per bridged memory access by the
/// engine. The `procedureTreeSink` is the §5.7 per-procedure combined run-tree
/// writer, fired once per top-level (or turn-less dream) run by the engine. When
/// the document carries no `trail:` block ([trail] is `null`), every surface is
/// disabled (§4.1 unconfigured mode), so no sink binds.
({
  LlmTrailSink? llmTrailSink,
  TurnSummarySink? turnSummarySink,
  IncomingTrailSink? incomingTrailSink,
  MemoryAccessSink? memoryAccessSink,
  ToolAccessSink? toolAccessSink,
  ProcedureTreeSink? procedureTreeSink,
}) _trailSinksFor(
  TrailConfig? trail,
) {
  if (trail == null) {
    return (
      llmTrailSink: null,
      turnSummarySink: null,
      incomingTrailSink: null,
      memoryAccessSink: null,
      toolAccessSink: null,
      procedureTreeSink: null,
    );
  }
  final root = Directory(trail.root);
  final writer = LlmTrailWriter(
    root: root,
    captureWireBody: trail.captureWireBody,
    captureInternalRoles: trail.captureInternalRoles,
  );
  final fanout = SummaryFanout.rootedAt(
    root,
    cap: trail.compactLogCap,
    captureInternalRoles: trail.captureInternalRoles,
  );
  // The §5.9 streaming live-trail rides the same per-step sinks as the summary
  // surfaces — one append per completed cognitive step, keyed by turnId.
  final liveTrail = StreamingLiveTrailWriter(
    root: root,
    turnsKept: trail.liveTrailTurns,
    captureInternalRoles: trail.captureInternalRoles,
  );

  final incomingWriter = IncomingTrailWriter(root: root);
  final memoryWriter = MemoryProfileLogWriter(root: root);
  final treeWriter = ProcedureTreeWriter(root: root);

  // Single source (§5.8): one record both lands as the raw §5.2 dump and fans
  // out to the summary projections — and now also streams into the live-trail.
  void llmTrailSink(LlmTrailRecord record) {
    writer.write(record);
    fanout.onCall(record);
    liveTrail.onLlmCall(record);
  }

  void incomingTrailSink(IncomingTrailRecord record) {
    incomingWriter.write(record);
    liveTrail.beginPrompt(record);
  }

  void memoryAccessSink(MemoryAccessRecord record) {
    memoryWriter.write(record);
    liveTrail.onMemoryCall(record);
  }

  // The §5.9 streaming live-trail is the only writer for tool calls today — the
  // per-profile / raw surfaces do not yet have a tool tier, so a tool access
  // streams into the live-trail and nowhere else.
  void toolAccessSink(ToolAccessRecord record) {
    liveTrail.onToolCall(record);
  }

  void turnSummarySink(TurnSummary summary) {
    fanout.onTurnComplete(summary);
    liveTrail.endPrompt(summary);
  }

  return (
    llmTrailSink: llmTrailSink,
    turnSummarySink: turnSummarySink,
    incomingTrailSink: incomingTrailSink,
    memoryAccessSink: memoryAccessSink,
    toolAccessSink: toolAccessSink,
    procedureTreeSink: treeWriter.write,
  );
}

/// Resolves the procedure prototype's shipped `scripts/system` directory.
///
/// The run assembly depends on `tom_brain_procedure`, whose
/// `scripts/system` folder ships `answer_with_memory_v1`. Resolving the package
/// URI (rather than a working-directory-relative path) lets the assembly find
/// those scripts no matter where the process was launched from.
Future<Directory> _resolveProcedurePrototypeScripts() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse(
      'package:tom_brain_procedure/tom_brain_procedure.dart',
    ),
  );
  if (libUri == null) {
    throw StateError(
      'cannot resolve the tom_brain_procedure package URI — '
      'is it on the package config?',
    );
  }
  // libUri → <package-root>/lib/tom_brain_procedure.dart; the scripts
  // live a sibling of lib/, at <package-root>/scripts/system.
  return Directory.fromUri(libUri.resolve('../scripts/system'));
}
