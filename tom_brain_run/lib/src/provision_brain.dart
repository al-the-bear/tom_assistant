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

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart'
    show
        AccessConfig,
        AccessServeSeam,
        BrainAccessProcess,
        BrainProvisioner,
        IncomingTrailSink,
        ProvisionedBrain,
        QueueSnapshot,
        serveWithShelfIo,
        startBrainAccessProcess;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, createSqliteTomBrainMemory;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        BrainProcessBoot,
        BrainProcessConfig,
        ClassifyFallback,
        LlmTrailRecord,
        LlmTrailSink,
        MemoryAccessSink,
        MemoryProvisioningConfig,
        ProcedureTreeSink,
        TurnSummarySink;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig, TomBrainSubstrateClient;

import 'brain_run_config.dart';
import 'brain_substrate_builder.dart' show buildSubstrate;
import 'incoming_trail_writer.dart' show IncomingTrailWriter;
import 'llm_trail_writer.dart' show LlmTrailWriter;
import 'memory_profile_log_writer.dart' show MemoryProfileLogWriter;
import 'procedure_tree_writer.dart' show ProcedureTreeWriter;
import 'summary_fanout.dart' show SummaryFanout;
import 'trail_config.dart' show TrailConfig;

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
Future<ProvisionedBrain> provisionBrain({
  required TomBrainSubstrateClient substrate,
  required MemoryConfig memoryConfig,
  SubstrateConfig? substrateConfig,
  Directory? systemScriptsDir,
  ClassifyFallback? classifyFallback,
  int foregroundQueueDepth = 4,
  String? isolateLogRootPath,
  LlmTrailSink? llmTrailSink,
  TurnSummarySink? turnSummarySink,
  MemoryAccessSink? memoryAccessSink,
  ProcedureTreeSink? procedureTreeSink,
}) async {
  final Directory scriptsDir =
      systemScriptsDir ?? await _resolveProcedurePrototypeScripts();

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
      classifyFallback: classifyFallback,
      llmTrailSink: llmTrailSink,
      turnSummarySink: turnSummarySink,
      memoryAccessSink: memoryAccessSink,
      procedureTreeSink: procedureTreeSink,
    ),
  );

  // Project the booted cognition: the access process holds only a `Dispatcher`
  // and a `QueueSnapshotSource`. We own the `RunCoordinator`, so we project its
  // live getters onto a `QueueSnapshot` and hand `BootedBrain.shutdown` as the
  // teardown.
  return ProvisionedBrain(
    dispatcher: booted.dispatcher,
    queueSnapshot: () => QueueSnapshot(
      foregroundRunning: booted.coordinator.hasForegroundRun,
      foregroundWaiting: booted.coordinator.foregroundQueueLength,
      foregroundQueueDepth: booted.coordinator.foregroundQueueDepth,
      backgroundRunning: booted.coordinator.hasBackgroundRun,
      draining: booted.coordinator.isDraining,
    ),
    shutdown: booted.shutdown,
  );
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
}) =>
    (AccessConfig config) => provisionBrain(
          substrate: substrate,
          memoryConfig: memoryConfig,
          substrateConfig: substrateConfig,
          systemScriptsDir: systemScriptsDir,
          classifyFallback: classifyFallback,
          foregroundQueueDepth: foregroundQueueDepth,
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
  String? isolateLogRootPath,
  LlmTrailSink? llmTrailSink,
  TurnSummarySink? turnSummarySink,
  IncomingTrailSink? incomingTrailSink,
  MemoryAccessSink? memoryAccessSink,
  ProcedureTreeSink? procedureTreeSink,
}) async {
  final ProvisionedBrain provisioned = await provisionBrain(
    substrate: substrate,
    memoryConfig: memoryConfig,
    substrateConfig: substrateConfig,
    systemScriptsDir: systemScriptsDir,
    classifyFallback: classifyFallback,
    foregroundQueueDepth: foregroundQueueDepth,
    isolateLogRootPath: isolateLogRootPath,
    llmTrailSink: llmTrailSink,
    turnSummarySink: turnSummarySink,
    memoryAccessSink: memoryAccessSink,
    procedureTreeSink: procedureTreeSink,
  );

  final BrainAccessProcess process;
  try {
    process = await startBrainAccessProcess(
      config: config,
      brain: provisioned,
      serve: serve,
      incomingTrailSink: incomingTrailSink,
    );
  } on Object {
    // The cognition is booted but never reached a running access process —
    // tear it down so the bind failure does not leak the memory isolate.
    await provisioned.shutdown();
    rethrow;
  }

  return BrainProcess._(process);
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
Future<BrainProcess> standUpBrainProcessFromConfig(
  BrainRunConfig runConfig, {
  Directory? systemScriptsDir,
  AccessServeSeam serve = serveWithShelfIo,
  ClassifyFallback? classifyFallback,
  int foregroundQueueDepth = 4,
  String? isolateLogRootPath,
}) {
  final TomBrainSubstrateClient substrate = buildSubstrate(runConfig.substrate);
  final sinks = _trailSinksFor(runConfig.trail);
  return standUpBrainProcess(
    config: runConfig.access,
    substrate: substrate,
    memoryConfig: runConfig.memory,
    substrateConfig: runConfig.substrate,
    systemScriptsDir: systemScriptsDir,
    serve: serve,
    classifyFallback: classifyFallback,
    foregroundQueueDepth: foregroundQueueDepth,
    isolateLogRootPath: isolateLogRootPath,
    llmTrailSink: sinks.llmTrailSink,
    turnSummarySink: sinks.turnSummarySink,
    incomingTrailSink: sinks.incomingTrailSink,
    memoryAccessSink: sinks.memoryAccessSink,
    procedureTreeSink: sinks.procedureTreeSink,
  );
}

/// Builds the trail sinks the engine + route are wired to from the `trail:`
/// config, or `(null, null)` in unconfigured mode.
///
/// In full-trail mode (a non-null [trail]) both the raw `llm/<role>/…` surface
/// (§4.1) and the §5.4 / §5.5 / §5.8 summary surfaces are active. A single
/// composed `LlmTrailSink` is the single source the spec's §5.8 calls for: each
/// completed call is **both** dumped raw by the [LlmTrailWriter] *and* fanned
/// out to the summary projections by the [SummaryFanout]. The returned
/// `turnSummarySink` is the same fan-out's `onTurnComplete`, fired per turn by
/// the route. The `incomingTrailSink` is the §5.3 raw incoming-prompt writer,
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
    liveTrailTurns: trail.liveTrailTurns,
    captureInternalRoles: trail.captureInternalRoles,
  );
  // Single source (§5.8): one record both lands as the raw §5.2 dump and fans
  // out to the four summary projections.
  void llmTrailSink(LlmTrailRecord record) {
    writer.write(record);
    fanout.onCall(record);
  }

  final incomingWriter = IncomingTrailWriter(root: root);
  final memoryWriter = MemoryProfileLogWriter(root: root);
  final treeWriter = ProcedureTreeWriter(root: root);

  return (
    llmTrailSink: llmTrailSink,
    turnSummarySink: fanout.onTurnComplete,
    incomingTrailSink: incomingWriter.write,
    memoryAccessSink: memoryWriter.write,
    procedureTreeSink: treeWriter.write,
  );
}

/// Resolves the procedure prototype's shipped `scripts/system` directory.
///
/// The run assembly depends on `tom_brain_procedure_prototype`, whose
/// `scripts/system` folder ships `answer_with_memory_v1`. Resolving the package
/// URI (rather than a working-directory-relative path) lets the assembly find
/// those scripts no matter where the process was launched from.
Future<Directory> _resolveProcedurePrototypeScripts() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse(
      'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart',
    ),
  );
  if (libUri == null) {
    throw StateError(
      'cannot resolve the tom_brain_procedure_prototype package URI — '
      'is it on the package config?',
    );
  }
  // libUri → <package-root>/lib/tom_brain_procedure_prototype.dart; the scripts
  // live a sibling of lib/, at <package-root>/scripts/system.
  return Directory.fromUri(libUri.resolve('../scripts/system'));
}
