// standUpSmokeProcess + SmokeProcess — the end-to-end stand-up harness (E.46).
//
// Plan step E.46 (verbatim): "Stand up the process with a stub substrate + an
// in-isolate memory + the OpenAI adapter on a local port."
//
// ── What this harness does ───────────────────────────────────────────
//
// It is the higher assembly the access package's `BrainProvisioner` seam
// anticipates: the one place that may import substrate + memory and boot the
// whole cognition, then point the access process at it.
//
//   1. Boot the cognition. `BrainProcessBoot.boot` brings up the stub
//      [SmokeSubstrate] (in-process) and an in-isolate [SmokeMemory] (the
//      production isolate transport, via the top-level [spawnSmokeMemory]
//      factory), then assembles the engine + dispatcher. No access layer is
//      installed through the boot's own installer seam — the access process is
//      stood up *separately* over the booted dispatcher.
//   2. Project the cognition into a [ProvisionedBrain]. The access process
//      holds only a `Dispatcher` and a `QueueSnapshotSource`; here — the side
//      that owns the `RunCoordinator` — we project the coordinator's live
//      getters onto a `QueueSnapshot` for the health endpoint, and hand
//      `BootedBrain.shutdown` as the teardown.
//   3. Stand the access process up. `startBrainAccessProcess` composes the
//      admission core over the dispatcher and binds the OpenAI + `/healthz`
//      socket on a local port through an injected serve seam.
//
// ── Why the serve seam binds the port, not `AccessConfig.openAiPort` ──
//
// `AccessConfig` validates `openAiPort > 0`, so it cannot carry the ephemeral
// port `0`. The smoke binds an OS-assigned port by default (no fixed-port
// flakiness), so the harness injects a serve seam that binds [port] directly
// (0 ⇒ ephemeral) and leaves `AccessConfig.openAiPort` as a satisfy-validation
// placeholder. The real bound port is read back from [SmokeProcess.port].

import 'dart:io';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart'
    show
        AccessConfig,
        AnchorPolicy,
        BrainAccessProcess,
        DailyQuotaPolicy,
        ProvisionedBrain,
        QueueSnapshot,
        RateLimitPolicy,
        serveWithShelfIo,
        startBrainAccessProcess;
import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryConfig;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show BrainProcessBoot, BrainProcessConfig, MemoryProvisioningConfig;

import 'smoke_memory.dart';
import 'smoke_substrate.dart';

/// A booted, running smoke process plus its in-process stub substrate (E.46).
///
/// Returned by [standUpSmokeProcess]. [process] is the live access process (the
/// bound socket + the graceful teardown); [substrate] is the in-process stub a
/// later E.10 step configures before driving a run. Call [stop] once when
/// finished — it tears the access process and the booted cognition (including
/// the memory isolate) down in order.
final class SmokeProcess {
  /// The live access process — the bound OpenAI + `/healthz` socket.
  final BrainAccessProcess process;

  /// The in-process stub substrate the boot bound the engine against. Exposed
  /// so a later smoke step can set [SmokeSubstrate.answerChunks] before a run.
  final SmokeSubstrate substrate;

  SmokeProcess._({required this.process, required this.substrate});

  /// The port the OpenAI + `/healthz` socket actually bound (OS-assigned when
  /// the harness requested the ephemeral port `0`).
  int get port => process.port;

  /// Tears the smoke process down: stop the access process, then the booted
  /// cognition (drain foreground, dispose the memory isolate, close the
  /// substrate). Idempotent.
  Future<void> stop() => process.stop();
}

/// Boots a whole cognition (stub substrate + in-isolate memory) and stands the
/// access process up on a local port (E.46).
///
/// [port] is the port to bind; the default `0` requests an OS-assigned
/// ephemeral port (read it back from [SmokeProcess.port]). [substrate] lets a
/// caller pass a pre-configured stub (default: a fresh [SmokeSubstrate]).
/// [systemScriptsDir] points the disk procedure store at a system-scripts
/// directory; the default (`null`) leaves `BrainProcessBoot`'s own default
/// (`scripts/system`), which resolves to an empty procedure set when absent —
/// enough for a stand-up smoke that runs no procedure.
///
/// No real OS termination signals are watched (an empty `shutdownSignals`
/// list), so the harness owns the lifecycle entirely through [SmokeProcess.stop].
Future<SmokeProcess> standUpSmokeProcess({
  int port = 0,
  SmokeSubstrate? substrate,
  Directory? systemScriptsDir,
}) async {
  final SmokeSubstrate smokeSubstrate = substrate ?? SmokeSubstrate();

  // ── 1. Boot the cognition: stub substrate + in-isolate memory. ──
  final booted = await BrainProcessBoot.boot(
    BrainProcessConfig(
      substrate: smokeSubstrate,
      memoryProvisioning: MemoryProvisioningConfig.isolate(
        factory: spawnSmokeMemory,
        memoryConfig: MemoryConfig.forTesting(root: 'ztmp/tom_brain_smoke_e46'),
      ),
      systemScriptsDir: systemScriptsDir,
    ),
  );

  // ── 2. Project the booted cognition into a ProvisionedBrain. ──
  final ProvisionedBrain provisioned = ProvisionedBrain(
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

  // ── 3. Stand the access process up on the local port. ──
  final BrainAccessProcess process = await startBrainAccessProcess(
    config: _smokeAccessConfig(port),
    brain: provisioned,
    // The serve seam binds [port] directly (0 ⇒ ephemeral); `config.openAiPort`
    // is the satisfy-validation placeholder (see the file header).
    serve: (handler, _) => serveWithShelfIo(handler, port),
    shutdownSignals: const <Stream<ProcessSignal>>[],
  );

  return SmokeProcess._(process: process, substrate: smokeSubstrate);
}

/// The permissive access config the smoke binds: no bearer bindings (every
/// `/v1/` request is admitted without auth pre-validation), no rate / quota
/// caps, and an empty anchor policy (every prompt admitted). `openAiPort` is a
/// placeholder — the harness's serve seam binds the real port.
AccessConfig _smokeAccessConfig(int port) => AccessConfig(
      openAiPort: port > 0 ? port : 1,
      rateLimitPolicy: RateLimitPolicy(
        capacity: 1000000,
        refillTokens: 1000000,
        refillPeriod: const Duration(seconds: 1),
      ),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 1000000),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const <String>[]),
    );
