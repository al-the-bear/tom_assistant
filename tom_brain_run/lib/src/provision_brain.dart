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
        ApiKeyPersist,
        BrainAccessProcess,
        BrainProvisioner,
        IncomingTrailRecord,
        IncomingTrailSink,
        JsonFileHistoryStore,
        MemoryProfileSelector,
        ProfileResolutionException,
        ProfileResolver,
        ProvisionedBrain,
        QueueSnapshot,
        QueueSnapshotSource,
        TelegramChatApiFactory,
        TelegramCliServerPortController,
        TelegramDreamController,
        TelegramInspectors,
        TelegramStopController,
        TelegramTodosInspector,
        TelegramUsageInspector,
        defaultTelegramChatApiFactory,
        serveWithShelfIo,
        startBrainAccessProcess;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, MemoryConfigPaths, createSqliteTomBrainMemory;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        BootedBrain,
        BrainProcessBoot,
        BrainProcessConfig,
        ClassifyFallback,
        DreamLaneSessions,
        FileScope,
        DartMcpConnector,
        defaultCompactionTemplate,
        FreeTimeScheduler,
        HistoryCompactor,
        HistoryCompactionTemplateStore,
        LlmCallTrailRecord,
        LlmTrailSink,
        McpClient,
        McpClientToolSource,
        McpOfferedGate,
        McpServerConfig,
        McpServersConfig,
        McpToolDefinition,
        MemoryAccessRecord,
        MemoryAccessSink,
        MemoryProvisioningConfig,
        MemoryRetrievalConfig,
        OverlayResolverFactory,
        ProcedureTreeRecord,
        ProcedureTreeSink,
        PromptResolver,
        RouteChainResolver,
        SelectionSettings,
        SubstrateHistoryCompaction,
        ToolAccessRecord,
        ToolAccessSink,
        TurnSummary,
        TurnSummarySink;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Clock,
        defaultMemoryProfile,
        HistoryConfig,
        ResolvedProfile,
        SystemClock,
        TomBrainMemoryClient;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show
        InProcessTomBrainSubstrate,
        ReloadingRoleRegistry,
        SubstrateConfig,
        TomBrainSubstrateClient,
        bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory;

import 'package:tom_core_agentic/agent_sdk.dart' show AgentSdkSessionProvider;
import 'api_key_persist.dart' show appendApiKeyToRunConfig;
import 'brain_run_config.dart';
import 'brain_substrate_builder.dart' show buildSubstrate;
import 'embedding_boot_probe.dart' show probeEmbeddingReachableAtBoot;
import 'cli_server_port_switch.dart'
    show CliServerPortConfigWriter, TomBrainCliServerPortController;
import 'builtin_bindings.dart' show BrainBuiltins;
import 'cognition_config.dart' show CognitionConfig;
import 'cognition_config_loader.dart' show CognitionConfigLoader;
import 'legacy_store_migration.dart' show migrateLegacyMemoryRoot;
import 'cognition_prompt_resolver.dart'
    show
        buildOverlayPromptResolver,
        buildPromptResolver,
        buildRouteChainResolver;
import 'dream_cadence_driver.dart' show CadenceSchedule;
import 'dream_cadence_wiring.dart' show dreamCadenceDriverOverScheduler;
import 'dream_config.dart' show DreamConfig;
import 'dream_controller.dart' show DreamController;
import 'dream_throttle.dart' show DreamThrottle;
import 'late_dream_surface.dart' show LateDreamSurface;
import 'mcp_channel_factory.dart' show productionMcpChannelFactory;
import 'mcp_liveness_monitor.dart' show McpLivenessMonitor;
import 'mcp_offered_wiring.dart'
    show mcpLivenessMonitorOverClient, mcpOfferedGate;
import 'model_switch.dart' show CognitionModelWriter, TomBrainModelSwitcher;
import 'incoming_trail_writer.dart' show IncomingTrailWriter;
import 'llm_trail_writer.dart' show LlmTrailWriter;
import 'memory_profile_log_writer.dart' show MemoryProfileLogWriter;
import 'procedure_tree_writer.dart' show ProcedureTreeWriter;
import 'creation_trail_writer.dart' show CreationTrailWriter;
import 'profile/profile_config_errors.dart' show UnknownProfileException;
import 'streaming_live_trail.dart' show StreamingLiveTrailWriter;
import 'substrate_memory_profile_selector.dart' show buildMemoryProfileSelector;
import 'summary_fanout.dart' show SummaryFanout;
import 'telegram_inspector_impls.dart'
    show
        CognitionPromptsInspector,
        DreamControllerTelegramAdapter,
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
  HistoryConfig history = const HistoryConfig.standard(),
  Directory? historyCompactionTemplatesDir,
  PromptResolver? promptResolver,
  RouteChainResolver? routeChainOf,
  OverlayResolverFactory? overlayResolverFor,
  McpClient? mcpClient,
  List<McpToolDefinition> mcpTools = const <McpToolDefinition>[],
  McpOfferedGate? mcpOffered,
  McpLivenessMonitor? mcpMonitor,
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
  final LateDreamSurface? dreamHolder = dreamEnabled
      ? LateDreamSurface()
      : null;

  // The foreground answer lane's history compactor (HC-81 activation). Built
  // from the incoming substrate (the boot consumes the same client, so no boot
  // output is needed first) through the same gated seam the dream loop uses
  // below: an over-threshold answer session folds its `pending` batch into its
  // bounded summary through the anchored (PE-7) + budgeted (PE-8) `sub.llm`
  // path. Absent template ⇒ `null`: the safe never-fold default (the answer lane
  // loses nothing — verbatim turns stay in the durable record).
  final HistoryCompactor? foregroundCompactor = historyCompactorFor(
    templatesDir: historyCompactionTemplatesDir,
    substrate: substrate,
  );

  // Boot the cognition: real substrate → real on-disk memory (isolate-hosted
  // via the production factory) → engine → dispatcher.
  final booted = await BrainProcessBoot.boot(
    BrainProcessConfig(
      substrate: substrate,
      historyCompactor: foregroundCompactor,
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
      overlayResolverFor: overlayResolverFor,
      mcpClient: mcpClient,
      mcpTools: mcpTools,
      mcpOffered: mcpOffered,
      // Persist the per-session working todo lists under the memory root
      // (`<root>/session_todos.json`) so a session's list survives a brain
      // restart — the same durable mount the brain-mode agent-SDK session store
      // keys `agent_sdk_sessions.json` under.
      sessionTodoStoreRoot: memoryConfig.root,
    ),
  );

  // Start the MCP liveness heartbeat (request c, § 3.2): once the engine is
  // wired over the gate, the monitor owns the dynamic `isLive` half it reads.
  // It kicks an immediate probe and then re-probes every 30 s, flipping a
  // server in / out of `offered(...)` with no process restart. Stopped first in
  // teardown (below) so no probe outlives the client it reaches through.
  mcpMonitor?.start();

  // Wire the scheduled dream cadence into startup (item b) when a `dream:` block
  // is present AND enabled. The controller owns a `DreamCadenceLoop` whose
  // heartbeat gate is its window/mode test, firing each due dream agent through
  // the free-time scheduler's background slot. We build it *after* boot because
  // the scheduler reads the booted coordinator / engine / memory client, then
  // start the gated heartbeat. An absent or disabled block leaves the cognition
  // with no background cadence — the prototype's deterministic live tests never
  // spin one (so r30 / r32 / r35 / r36 stay deterministic).
  final DreamController? dreamController = dreamEnabled
      ? _startDreamLoop(
          booted,
          dream,
          history,
          memoryConfig.root,
          historyCompactionTemplatesDir,
        )
      : null;
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
      await mcpMonitor?.stop();
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
    todosInspector: SessionTodosInspector(
      stores: booted.engine.sessionTodoStores,
    ),
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
    // Surface the live dream cadence behind the access package's
    // `TelegramDreamController` port for `/dream_now` / `/dream_start` /
    // `/dream_stop` / `/dream_status`. `null` when dreaming is disabled — the
    // edge then answers those commands "not available on this deployment".
    dreamController: dreamController == null
        ? null
        : DreamControllerTelegramAdapter(dreamController),
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
DreamController _startDreamLoop(
  BootedBrain booted,
  DreamConfig dream,
  HistoryConfig history,
  String memoryRoot,
  Directory? historyCompactionTemplatesDir,
) {
  // A dreaming lane is one long session that remembers what it did across
  // firings (todo #15). Its activity history is now durable (HC-82): a
  // `JsonFileHistoryStore` under the memory root (alongside `session_todos.json`)
  // rehydrates every lane on boot and is written back after each firing, so the
  // dreaming lanes resume mid-narrative across a process restart instead of
  // forgetting what they were doing.
  final JsonFileHistoryStore dreamStore = JsonFileHistoryStore(
    '$memoryRoot/dream_lane_sessions.json',
  );
  // Each lane keeps its own compactable activity history, sized through the
  // same `history:` block, persisted through the durable store above. When a
  // `compact_history_v1` template is present in the cognition tree (I-2), wire
  // the production compactor so an over-threshold dreaming lane folds its
  // `pending` batch into its bounded summary through the anchored + budgeted
  // `sub.llm` seam (`SubstrateHistoryCompaction`) — derivation, not deletion:
  // the durable record above keeps every firing. Absent template ⇒ no compactor
  // (the answer-lane's HC-81 default): a lane's `pending` batch grows unfolded,
  // still losing nothing.
  final HistoryCompactor? dreamCompactor = historyCompactorFor(
    templatesDir: historyCompactionTemplatesDir,
    substrate: booted.substrate,
  );
  // One wall clock shared by both the *timing* driver (which lanes are due) and
  // the *pass-clock* seam (the `nowMs` stamp `dream_decay_v1` ages coldness
  // against): the lane that decides a decay pass is due and the instant that
  // pass measures against read the same source.
  const Clock clock = SystemClock();
  final scheduler = FreeTimeScheduler(
    coordinator: booted.coordinator,
    memory: booted.memory.client,
    workFactory: (_) => null,
    engine: booted.engine,
    clock: clock,
    // Each dreaming lane resolves its own prior-run window from the shared
    // `history:` block (todo #14): `history.lanes.<dreamLaneId>` sizes a lane's
    // `recentRuns` context independently of the foreground answer lane.
    historyConfig: history,
    dreamSessions: DreamLaneSessions(
      historyConfig: history,
      compactor: dreamCompactor,
      loadSnapshot: dreamStore.load,
      persistSnapshot: dreamStore.save,
    ),
  );
  // Part d: when a throttle is configured, build it over the active schedule so
  // its per-lane caps (`DreamLaneSpec.maxLlmCallsPerWindow`) are honoured on top
  // of the global budget. Absent ⇒ unthrottled.
  final CadenceSchedule schedule = dream.cadence ?? CadenceSchedule.defaults();
  final DreamThrottle? throttle = dream.throttle == null
      ? null
      : DreamThrottle(
          maxCallsPerWindow: dream.throttle!.maxCallsPerWindow,
          window: dream.throttle!.window,
          perLaneMaxCallsPerWindow: <String, int>{
            for (final lane in schedule.lanes)
              if (lane.maxLlmCallsPerWindow != null)
                lane.id: lane.maxLlmCallsPerWindow!,
          },
        );
  final controller = DreamController(
    driver: dreamCadenceDriverOverScheduler(
      scheduler,
      clock: clock,
      schedule: schedule,
      throttle: throttle,
      maxRepeatCount: dream.maxRepeatCount,
    ),
    schedule: dream.schedule,
    heartbeat: dream.heartbeat ?? const Duration(minutes: 1),
  );
  controller.start();
  return controller;
}

/// The gated production [HistoryCompactor] both lanes wire in (HC-81 foreground
/// / I-2 dream): a compactor built over [templatesDir] + [substrate] when a
/// `compact_history_v1` template is actually present there, else `null` — the
/// safe never-fold default (a session's `pending` batch then grows unfolded but
/// loses nothing, since the durable record keeps every turn / firing).
/// [templatesDir] is `null` when no cognition tree is configured.
///
/// This is the single decision both the foreground answer lane (its
/// `BrainProcessConfig.historyCompactor` seam) and `_startDreamLoop` (the
/// `DreamLaneSessions.compactor` seam) make, factored out so the gate is one
/// place and both lanes degrade identically.
HistoryCompactor? historyCompactorFor({
  required Directory? templatesDir,
  required TomBrainSubstrateClient substrate,
}) => templatesDir != null && _hasCompactionTemplate(templatesDir)
    ? buildHistoryCompactor(templatesDir: templatesDir, substrate: substrate)
    : null;

/// Whether [dir] holds the production `compact_history_v1` template the
/// compactor folds through. The store resolves `<dir>/<type>.yaml`, so the file
/// is the load-bearing artifact: an absent template would silently degrade a
/// fold to a never-fold (the compactor swallows the load error), so a lane only
/// builds a compactor when the file is actually present.
bool _hasCompactionTemplate(Directory dir) =>
    File('${dir.path}/$defaultCompactionTemplate.yaml').existsSync();

/// Builds the production [HistoryCompactor] both lanes fold through: the
/// `compact_history_v1` template store over [templatesDir] folded through the
/// anchored (PE-7) + budgeted (PE-8) `sub.llm` seam ([SubstrateHistoryCompaction])
/// over [substrate].
///
/// This is the exact construction both the foreground answer lane (its
/// `BrainProcessConfig.historyCompactor` seam) and `_startDreamLoop` perform in
/// production once a `compact_history_v1` template is present (HC-81 / I-2): an
/// over-threshold session folds its `pending` batch into its bounded summary
/// through the real substrate call. The build is lane-agnostic — the compactor
/// only ever sees a `ConversationHistory` — so a single builder serves both.
/// It is exported so a test can pin the production wiring seam without a vec0
/// boot.
HistoryCompactor buildHistoryCompactor({
  required Directory templatesDir,
  required TomBrainSubstrateClient substrate,
}) => HistoryCompactor(
  templates: HistoryCompactionTemplateStore(templatesDir),
  substrate: SubstrateHistoryCompaction(client: substrate).call,
);

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
  HistoryConfig history = const HistoryConfig.standard(),
  Directory? historyCompactionTemplatesDir,
  PromptResolver? promptResolver,
  RouteChainResolver? routeChainOf,
  OverlayResolverFactory? overlayResolverFor,
  CognitionConfig? cognitionConfig,
  McpClient? mcpClient,
  List<McpToolDefinition> mcpTools = const <McpToolDefinition>[],
  McpOfferedGate? mcpOffered,
  McpLivenessMonitor? mcpMonitor,
  CognitionModelWriter? modelWriter,
  TelegramCliServerPortController? cliServerPortController,
  ApiKeyPersist? apiKeyPersist,
  ProfileResolver? profileResolver,
  List<String> Function()? configuredProfiles,
  TelegramChatApiFactory? telegramChatApiFactory,
  MemoryProfileSelector? profileSelector,
  SelectionSettings? selection,
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
    history: history,
    historyCompactionTemplatesDir: historyCompactionTemplatesDir,
    promptResolver: promptResolver,
    routeChainOf: routeChainOf,
    overlayResolverFor: overlayResolverFor,
    mcpClient: mcpClient,
    mcpTools: mcpTools,
    mcpOffered: mcpOffered,
    mcpMonitor: mcpMonitor,
  );

  final BrainAccessProcess process;
  try {
    process = await startBrainAccessProcess(
      config: config,
      brain: provisioned,
      serve: serve,
      incomingTrailSink: incomingTrailSink,
      apiKeyPersist: apiKeyPersist,
      profileResolver: profileResolver,
      configuredProfiles: configuredProfiles,
      profileSelector: profileSelector,
      selection: selection,
      // Default to the real long-polling bot; a test injects a loopback
      // `ChatApi` so the Telegram edge can be driven without a live bot.
      telegramChatApiFactory:
          telegramChatApiFactory ?? defaultTelegramChatApiFactory,
      telegramInspectors: _telegramInspectorsFor(
        trailRoot: trailRoot,
        memoryClient: provisioned.memoryClient,
        queueSnapshot: provisioned.queueSnapshot,
        todos: provisioned.todosInspector,
        usage: provisioned.usageInspector,
        stop: provisioned.stopController,
        dream: provisioned.dreamController,
        substrateConfig: substrateConfig,
        cognitionConfig: cognitionConfig,
        mcpClient: mcpClient,
        modelWriter: modelWriter,
        cliServerPort: cliServerPortController,
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
  required TelegramDreamController? dream,
  required SubstrateConfig? substrateConfig,
  required CognitionConfig? cognitionConfig,
  required McpClient? mcpClient,
  required CognitionModelWriter? modelWriter,
  required TelegramCliServerPortController? cliServerPort,
}) {
  final Directory? root = trailRoot == null ? null : Directory(trailRoot);
  return TelegramInspectors(
    prompts: root == null
        ? null
        : TrailIncomingPromptInspector(trailRoot: root),
    logs: root == null ? null : TrailLogInspector(trailRoot: root),
    memory: memoryClient == null
        ? null
        : MemoryStatsInspector(client: memoryClient),
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
    // The dream controller drives the live cadence (not the trail), so it is
    // wired whenever the provisioner ran a dream loop (dreaming enabled).
    dream: dream,
    // The models inspector reads the parsed substrate config (not the trail),
    // so it is wired whenever the boot threaded one in.
    models: substrateConfig == null
        ? null
        : SubstrateModelsInspector(config: substrateConfig),
    // The prompt-types inspector reads the parsed cognition config (not the
    // trail), so it is wired whenever a `cognition:` tree was loaded. A
    // `/switch_model` change is already reflected in that live config (the
    // prompt's `llm:` route is rewritten in place), so the inspector renders the
    // switched model from the config itself — no separate override surface.
    promptTypes: cognitionConfig == null
        ? null
        : CognitionPromptsInspector(config: cognitionConfig),
    // The tool-catalogue inspector reads the engine's shipped default tool set
    // — a process constant, so it is always wired.
    tools: ToolCatalogueInspector(),
    // The MCP-servers inspector reads the live outbound MCP client (request f),
    // so it is wired exactly when the cognition has an MCP client — i.e. when at
    // least one `mcpServers:` entry was configured.
    mcp: mcpClient == null ? null : McpServersInspector(client: mcpClient),
    // The model switcher (request e) needs both the cognition config (the valid
    // prompt-id space) and the substrate config (the valid provider/model
    // space), so it is wired only when both are present. The [modelWriter]
    // persists a validated switch into the normal cognition config (a route file
    // + the prompt's `llm:` binding + the live config) so it survives a restart;
    // absent → the switch reports as unavailable rather than half-applied.
    modelSwitcher: cognitionConfig == null || substrateConfig == null
        ? null
        : TomBrainModelSwitcher(
            cognition: cognitionConfig,
            substrate: substrateConfig,
            writer: modelWriter,
          ),
    // The CLI-server-port controller (`/cli_server_port`) rebinds the live
    // agent-SDK providers and persists the chosen port to the run config. It is
    // wired by the from-config entry point whenever there are agent-SDK
    // providers to rebind; absent → the command reports as unavailable.
    cliServerPort: cliServerPort,
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
  String? runConfigPath,
  TelegramChatApiFactory? telegramChatApiFactory,
}) async {
  // Resolve the scripts dir once so the boot's procedure store and the §6
  // `${scripts_folder}` built-in the prompt resolver carries agree on the same
  // directory. Precedence: an explicit [systemScriptsDir] (tests / embedders)
  // → the configured `scripts.systemDir` (CLI plan step 3) → the package-
  // relative prototype fallback (kept until a real bundle lands at step 4;
  // CLP decision).
  final Directory scriptsDir =
      systemScriptsDir ??
      runConfig.scripts?.systemDir ??
      await _resolveProcedurePrototypeScripts();

  // Build the two `sub.run` seams + the file-backed role registry from the
  // `cognition:` config tree (§7.1 / §7.4 / §8) when the block is present.
  PromptResolver? promptResolver;
  RouteChainResolver? routeChainOf;
  OverlayResolverFactory? overlayResolverFor;
  ReloadingRoleRegistry? roleProseReload;
  CognitionConfig? cognitionConfig;
  // The `/switch_model` config writer (request e). Built only when a cognition
  // tree is loaded — a switch re-points a registered prompt id at a model by
  // editing the normal cognition config (a per-prompt route file + the prompt's
  // `llm:` binding) and mutating the live [cognitionConfig], so without a
  // cognition root there is nothing to write. No separate override file or
  // registry: the switch *is* the configuration, so it survives a restart
  // because the standard loader reads it back at boot.
  CognitionModelWriter? modelWriter;
  final cognition = runConfig.cognition;
  final Map<String, String> environment = Platform.environment;
  if (cognition != null) {
    cognitionConfig = CognitionConfigLoader.loadFromDir(
      cognition.root,
      env: environment,
    );
    // §7.1 / §11: role prose (persona + objective) is sourced from
    // `cognition/<rolesFolder>/<role>.persona.md` + `<role>.objective.md`,
    // overlaid on the full live roster. The in-code roster supplies the
    // capability surface and the fallback for any role (or half) whose file
    // is absent or blank. Wrapped in a *reloading* holder so an operator can
    // edit a role's prose file and have the next LLM call pick it up without a
    // restart (`prompt_tracing.md` § 6.3, AUTH-5) — the same pull-based pickup
    // the prompt *template body* already has (`buildPromptResolver` re-reads it
    // per `sub.run`).
    roleProseReload = ReloadingRoleRegistry.reloading(
      base:
          bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory(),
      rolesDir: Directory(
        '${cognition.root}/${cognitionConfig.registry.rolesFolder}',
      ),
    );
    final builtins = BrainBuiltins.fromRunConfig(
      runConfig,
      configFolder: cognition.root,
      scriptsFolder: scriptsDir.path,
    );
    // The `/switch_model` writer edits the live [cognitionConfig] (and the
    // matching on-disk config files). Because the resolvers below read
    // `config.prompts` / `config.route` fresh on every `sub.run`, a switch the
    // writer applies takes effect on the next run with no resolver re-wiring,
    // and survives a restart because the standard loader reads the rewritten
    // config back at boot — there is no separate override layer to seed.
    modelWriter = CognitionModelWriter(
      cognitionRoot: cognition.root,
      config: cognitionConfig,
    );
    promptResolver = buildPromptResolver(
      cognitionConfig,
      builtins,
      environment: environment,
    );
    routeChainOf = buildRouteChainResolver(cognitionConfig);
    // The per-run template-overlay seam (session_configuration.md § 5.2, plan
    // step 8 (b)): a profile's `templateOverlay` name selects a shadow tree under
    // `<cognition.root>/overlays/<name>/`. The engine layers it over the base
    // resolver per run; a profile-less request never names an overlay, so this
    // is bound but inert until a profile uses it.
    overlayResolverFor = buildOverlayPromptResolver(
      cognitionConfig,
      builtins,
      environment: environment,
    );
  }

  // Profile selection axis boot validation (session_configuration.md § 3 / § 8,
  // plan step 3). Reject an unknown `role` / missing `templateOverlay` dir, and
  // warn (not reject) a profile whose budget/rate-limits exceed the global
  // ceiling (SC-8). Guarded-by-construction: a config with no `profiles:` block
  // carries only the built-in `default` (no role, no overlay, no budget), so
  // this is a true no-op for a pre-feature config. The known-role set is the
  // shipped roster's ids (a file-backed overlay only adds prose to existing
  // ids, never new ones); the overlay predicate tests
  // `<cognition.root>/overlays/<name>/`, which cannot exist when no cognition
  // tree is configured. No global ceiling exists yet, so none is passed (the
  // clamp composes against the real ceilings once they are wired, SCP-12).
  final Set<String> knownRoles =
      (roleProseReload?.latest ??
              bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory())
          .ids
          .toSet();
  final String? cognitionRoot = cognition?.root;
  runConfig.profiles.validateAtBoot(
    knownRoles: knownRoles,
    overlayDirExists: (name) =>
        cognitionRoot != null &&
        Directory('$cognitionRoot/overlays/$name').existsSync(),
    warn: (message) => stderr.writeln('[profile] $message'),
  );

  // The profile-resolution seam the access edge stamps onto `Access` (SCP-18 /
  // SCP-20, plan step 5). A `null` selector means the request carried no
  // `profile-` marker → the built-in `default` profile. An unknown selector's
  // run-side `UnknownProfileException` is translated to the access-local
  // `ProfileResolutionException` the edge maps to `400` / `profile.unknown`.
  // No global ceilings / exposed-MCP ids are passed yet — the same posture as
  // `validateAtBoot` above; clamping and the offered-MCP set are wired with the
  // engine binding that consumes them (SCP-12, plan steps 6/8).
  ResolvedProfile profileResolver(String? profileSelector) {
    try {
      return runConfig.profiles.resolve(profileSelector ?? 'default');
    } on UnknownProfileException catch (error) {
      throw ProfileResolutionException(
        error.name,
        'no profile named "${error.name}"',
      );
    }
  }

  // The substrate uses the file-backed registry when a cognition tree was
  // loaded; otherwise `buildSubstrate` falls back to its in-code full roster.
  // Typed as the concrete facade (not the `TomBrainSubstrateClient` interface)
  // so the live agent-SDK providers can be reached for the `/cli_server_port`
  // rebind below.
  final InProcessTomBrainSubstrate substrate = buildSubstrate(
    runConfig.substrate,
    roleProseReload: roleProseReload,
    // The run's storage root: a `sessionMode: brain` agent-SDK provider keys
    // its persisted conversation ids under `<root>/agent_sdk_sessions.json`
    // (agent-SDK design spec § 1.4).
    agentSdkSessionRoot: runConfig.memory.root,
  );

  // Boot-time embedding-substrate reachability check. The embedding backend is
  // a *separate* service from the chat LLM (on bomber: chat = omlx, embeddings
  // = Ollama on :11434); it can be down while chat is up, in which case the
  // first embedding-dependent work — a vector recall or a dreaming lane that
  // re-embeds — crashes with `Connection refused`. The probe does one real
  // embed round-trip here so an unreachable backend is reported once, clearly,
  // at boot instead of as a flood of errored dream lanes. Non-fatal: chat needs
  // no embeddings, so a dead backend warns and boot continues.
  await probeEmbeddingReachableAtBoot(
    substrate,
    warn: (message) => stderr.writeln(message),
    info: (message) => stderr.writeln(message),
  );

  // The `/cli_server_port` controller: collect the live agent-SDK providers
  // (the `agent_sdk` rows) so a port switch can disconnect them from the old
  // bridge port and reconnect on the new one, and persist the change to the run
  // config (when [runConfigPath] is known) so it survives a restart. Wired only
  // when there is at least one agent-SDK provider to rebind; otherwise the
  // command reports as unavailable.
  final List<AgentSdkSessionProvider> agentSdkProviders = substrate
      .providers
      .values
      .whereType<AgentSdkSessionProvider>()
      .toList();
  final TelegramCliServerPortController? cliServerPortController =
      agentSdkProviders.isEmpty
      ? null
      : TomBrainCliServerPortController(
          providers: agentSdkProviders,
          configWriter: runConfigPath == null
              ? null
              : CliServerPortConfigWriter(File(runConfigPath)),
        );

  // The `/create_api_key` durable-persist closure (MSP-7, MSPP-42…47). The live
  // admission half is the access layer's own `AccessAssembler` operation; the
  // run layer supplies only this closure, which appends the minted key to the
  // run config so it survives a restart. Gated on a known [runConfigPath] —
  // without a config path on disk there is nowhere to persist to, so
  // `/create_api_key` reports as unavailable rather than minting a key that
  // would vanish on the next boot. The closure throws on a write failure, which
  // is what triggers the access-side §13 rollback.
  final ApiKeyPersist? apiKeyPersist = runConfigPath == null
      ? null
      : (config) => appendApiKeyToRunConfig(File(runConfigPath), config);

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
  // Merge the per-profile `defineMcpServers` (each namespaced `<profileId>/
  // <serverName>`) into the global registry before building the client, so a
  // profile's private servers are connected once at boot alongside the global
  // ones — profiles are operator config known at boot, so they carry no
  // per-request connection cost (§ 3.6). Guarded: with no profile defines this
  // is `runConfig.mcpServers` unchanged. (Strict-connect for an
  // `exposeToLlms: true` define that fails to connect is deferred to step 8,
  // SCP-11; this path uses the existing connect-tolerant merge.)
  final List<McpServerConfig> profileServers =
      runConfig.profiles.namespacedDefinedServers;
  final McpServersConfig mcpServersConfig = profileServers.isEmpty
      ? runConfig.mcpServers
      : McpServersConfig(<McpServerConfig>[
          ...runConfig.mcpServers.servers,
          ...profileServers,
        ]);
  final McpClient? mcpClient = mcpServersConfig.servers.isEmpty
      ? null
      : McpClient(
          mcpServersConfig,
          DartMcpConnector(channelFactory: productionMcpChannelFactory()),
        );
  // The dynamic availability gate (request c, § 3.3): the liveness monitor
  // holds the `isLive` half, the `exposeToLlms` config holds the static half,
  // and `mcpOfferedGate` folds them into `offered = exposeToLlms && isLive`. The
  // monitor is built here (it needs the parsed `mcpServers:` config) and started
  // inside the provisioner, which also stops it in teardown. Each configured id
  // starts optimistically live, so the boot-time tool merge below offers every
  // exposed server before the first probe.
  final McpLivenessMonitor? mcpMonitor = mcpClient == null
      ? null
      : mcpLivenessMonitorOverClient(mcpClient, mcpServersConfig);
  final McpOfferedGate? mcpOffered = mcpMonitor == null
      ? null
      : mcpOfferedGate(mcpServersConfig, mcpMonitor);
  // Pre-fetch the merged tool descriptors once, through the same gate: an
  // unexposed (or boot-dead) server contributes no `mcp__*` tools to the
  // registry, while the per-run invoke path re-checks the gate so a server that
  // later goes dead drops out of the tool loop live.
  final List<McpToolDefinition> mcpTools = mcpClient == null
      ? const <McpToolDefinition>[]
      : await McpClientToolSource(mcpClient, offered: mcpOffered).listTools();

  // One-shot legacy-store migration (memory-session-profiles § 11, plan step 8,
  // MSPP-26/MSPP-27): if a pre-profiles bare-root store exists and
  // `<root>/profiles/` does not, relocate it into the default profile directory
  // before the default store is opened. Idempotent — a second boot is a no-op.
  // The default store is then provisioned against the *profiled* default config
  // so it reads the migrated data back; every `.root`-keyed non-memory store
  // (session todos, agent-SDK / dream sessions, the Telegram edge state) keeps
  // using the bare root because `withProfile` preserves `.root`.
  migrateLegacyMemoryRoot(runConfig.memory);
  final memoryConfig = runConfig.memory.withProfile(defaultMemoryProfile);

  // Extension-H memory-profile selection (I-10; access spec § 7.4). The access
  // surface owns the conversation session, so it is the surface that runs
  // history-driven profile selection. Resolve the `selection:` block from the
  // cognition tree's `memory_retrieval/` family (the access surface = `defaults
  // ← access`); a deployment with no such tree gets the disabled default, so
  // the gate below builds no selector. The selector lists the *memory* profiles
  // (`<memory-root>/profiles/`, the recall axis) live, distinct from the SCP
  // processing-profile axis the channels operate over.
  final SelectionSettings selection = _resolveMemoryProfileSelection(
    cognitionRoot,
  );
  final MemoryProfileSelector? profileSelector = buildMemoryProfileSelector(
    substrate: substrate,
    knownProfiles: () async =>
        _listMemoryProfiles(runConfig.memory.profilesDir),
    selection: selection,
  );

  return standUpBrainProcess(
    config: runConfig.access,
    substrate: substrate,
    memoryConfig: memoryConfig,
    profileSelector: profileSelector,
    selection: selection,
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
    history: runConfig.history,
    // Both lanes' history compactors fold through the `compact_history_v1`
    // template resolved under the cognition tree (HC-81 foreground / I-2 dream).
    // Pass the cognition root when one is configured; each lane guards on the
    // template's actual presence, so a cognition tree without the template still
    // boots compactor-less (the safe never-fold default).
    historyCompactionTemplatesDir: cognition != null
        ? Directory(cognition.root)
        : null,
    promptResolver: promptResolver,
    routeChainOf: routeChainOf,
    overlayResolverFor: overlayResolverFor,
    cognitionConfig: cognitionConfig,
    mcpClient: mcpClient,
    mcpTools: mcpTools,
    mcpOffered: mcpOffered,
    mcpMonitor: mcpMonitor,
    modelWriter: modelWriter,
    cliServerPortController: cliServerPortController,
    apiKeyPersist: apiKeyPersist,
    profileResolver: profileResolver,
    // The operator-configured processing-profile names the Telegram
    // `/list_profiles` / `/switch_profile` commands operate over (§ 6). Profiles
    // are operator config, not user-minted, so the candidate set is the run's
    // `profiles:` registry, read live so a config reload is picked up.
    configuredProfiles: () => runConfig.profiles.names.toList(),
    // Forwarded so a test can drive the Telegram edge through a loopback
    // `ChatApi` (null → the real long-polling bot, the production default).
    telegramChatApiFactory: telegramChatApiFactory,
  );
}

/// Resolves the Extension-H memory-profile `selection:` block for the access
/// surface from the cognition tree's `memory_retrieval/` family (I-10; access
/// spec § 7.4).
///
/// The access surface is the `defaults ← access` layer pair, so this layers
/// `memory_retrieval/defaults.yml` then `memory_retrieval/access.yml` through
/// [MemoryRetrievalConfig.resolveYaml] and returns the composed `.selection`.
/// A deployment with no cognition tree, no `memory_retrieval/` directory, or no
/// layer files gets the disabled [SelectionSettings] default — the off-by-default
/// path the provisioner's selector gate reads to build no selector at all.
SelectionSettings _resolveMemoryProfileSelection(String? cognitionRoot) {
  if (cognitionRoot == null) return const SelectionSettings();
  final Directory dir = Directory('$cognitionRoot/memory_retrieval');
  if (!dir.existsSync()) return const SelectionSettings();
  final List<String> layers = <String>[];
  final File defaultsFile = File('${dir.path}/defaults.yml');
  if (defaultsFile.existsSync()) layers.add(defaultsFile.readAsStringSync());
  final File accessFile = File('${dir.path}/access.yml');
  if (accessFile.existsSync()) layers.add(accessFile.readAsStringSync());
  if (layers.isEmpty) return const SelectionSettings();
  return MemoryRetrievalConfig.resolveYaml(layers).selection;
}

/// Lists the live *memory* profile names under [profilesDir]
/// (`<memory-root>/profiles/`), one per directory, for the profile selector's
/// `knownProfiles` input.
///
/// Read live (not cached) so a profile minted after boot is offered to the
/// selector on the next selection. Mirrors `SqliteMemoryProfileRegistry.list()`:
/// each immediate sub-directory name is a profile. A missing directory (no
/// profiles materialised yet) yields the empty list.
List<String> _listMemoryProfiles(String profilesDir) {
  final Directory dir = Directory(profilesDir);
  if (!dir.existsSync()) return <String>[];
  return dir
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path.split(Platform.pathSeparator).last)
      .where((name) => name.isNotEmpty)
      .toList();
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
})
_trailSinksFor(TrailConfig? trail) {
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
  final creationWriter = CreationTrailWriter(root: root);

  // The one combined run-tree record fans out to both the §5.7 per-procedure
  // `.log` tree and — for a `create_v1` run only — the creation trail
  // (creation-spec §9.2 / §12; UB5). The creation writer self-guards on the
  // procedure id, so every non-creation run is a cheap no-op.
  void procedureTreeSink(ProcedureTreeRecord record) {
    treeWriter.write(record);
    creationWriter.write(record);
  }

  // Single source (§5.8): one record both lands as the raw §5.2 dump and fans
  // out to the summary projections — and now also streams into the live-trail.
  void llmTrailSink(LlmCallTrailRecord record) {
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
    procedureTreeSink: procedureTreeSink,
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
    Uri.parse('package:tom_brain_procedure/tom_brain_procedure.dart'),
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
