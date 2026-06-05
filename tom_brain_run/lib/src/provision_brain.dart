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
        MemoryProvisioningConfig;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig, TomBrainSubstrateClient;

import 'brain_run_config.dart';
import 'brain_substrate_builder.dart' show buildSubstrate;

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
Future<ProvisionedBrain> provisionBrain({
  required TomBrainSubstrateClient substrate,
  required MemoryConfig memoryConfig,
  SubstrateConfig? substrateConfig,
  Directory? systemScriptsDir,
  ClassifyFallback? classifyFallback,
  int foregroundQueueDepth = 4,
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
      ),
      systemScriptsDir: scriptsDir,
      foregroundQueueDepth: foregroundQueueDepth,
      classifyFallback: classifyFallback,
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
}) async {
  final ProvisionedBrain provisioned = await provisionBrain(
    substrate: substrate,
    memoryConfig: memoryConfig,
    substrateConfig: substrateConfig,
    systemScriptsDir: systemScriptsDir,
    classifyFallback: classifyFallback,
    foregroundQueueDepth: foregroundQueueDepth,
  );

  final BrainAccessProcess process;
  try {
    process = await startBrainAccessProcess(
      config: config,
      brain: provisioned,
      serve: serve,
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
}) {
  final TomBrainSubstrateClient substrate = buildSubstrate(runConfig.substrate);
  return standUpBrainProcess(
    config: runConfig.access,
    substrate: substrate,
    memoryConfig: runConfig.memory,
    substrateConfig: runConfig.substrate,
    systemScriptsDir: systemScriptsDir,
    serve: serve,
    classifyFallback: classifyFallback,
    foregroundQueueDepth: foregroundQueueDepth,
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
