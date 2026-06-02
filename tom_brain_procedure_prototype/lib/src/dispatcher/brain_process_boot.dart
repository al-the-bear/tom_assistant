// Startup orchestration — `BrainProcessBoot` (Plan step D.44;
// `tom_brain_procedure_prototype_specification.md` § 12).
//
// D.43 shipped the *memory provisioning seam* (`MemoryProvisioner`): one
// decision point that hands back an opened, transport-indifferent
// `TomBrainMemoryClient`. D.44 is the orchestration that *uses* that seam to
// bring the whole prototype process up in the order § 12 names:
//
//   1. substrate (in-process) — opened first, because the engine's
//      `SubstrateBridge` (`sub`) binds against it and the role registry must
//      validate before any run can issue an `llm` call;
//   2. memory (isolate by default) — provisioned through the D.43
//      `MemoryProvisioner`, so the store's SQLite + index + sleep work stays
//      off the dispatcher's event loop;
//   3. engine + dispatcher (main isolate) — the `ProcedureEngine` over the
//      two bridges + the disk procedure store, wrapped by the
//      `accept → classify → select → schedule` pipeline behind a single
//      `Dispatcher`;
//   4. the future access layer (Phase E) — an *installer seam*: the prototype
//      ships no channel, so it defaults to "none"; Phase E supplies an
//      installer that points the OpenAI HTTP/SSE + Telegram surface at the
//      booted dispatcher and returns a teardown the boot manages.
//
// ── What D.44 owns, and what it does not ──────────────────────────────
//
// D.44 owns the *bring-up sequence* and the running handle (`BootedBrain`)
// that exposes the assembled parts and a `shutdown()` that tears the brought-up
// resources down cleanly. The *full* shutdown drain — finish the current
// foreground best-effort, drain the foreground queue, close trails — is D.45,
// which layers on the minimal teardown here. The guarantee that a
// memory-isolate spawn crash surfaces as a *typed startup error* is D.46. D.44
// keeps boot's failure behaviour honest (a failure after a resource is up tears
// that resource back down so a failed boot leaks nothing) but does not yet wrap
// the failure in a typed class.
//
// ── Why the engine and coordinator share one PreemptionState ──────────
//
// Cooperative preemption only works if the object the engine *yields against*
// (`ProcedureEngine.preemptionState`, read by the `yield_if_foreground_waiting`
// primitive, C.34/C.35) is the *same* object the coordinator *writes*
// (`RunCoordinator.preemption`, set when a foreground arrival must preempt a
// live background, D.20). Boot constructs exactly one `PreemptionState` and
// threads it into both, so a foreground submission admitted mid-background
// actually reaches the running background's next checkpoint.

import 'dart:io';

import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig, TomBrainSubstrateClient;
import 'package:tom_brain_shared/tom_brain_shared.dart' show Access, PreemptionState;

import '../api/procedure_engine.dart';
import '../api/procedure_invocation.dart';
import '../bridges/memory_bridge.dart';
import '../bridges/substrate_bridge.dart';
import '../procedure_store/disk_procedure_store.dart';
import '../procedure_store/procedure_resolver.dart';
import 'dispatcher_entry.dart';
import 'inbound_classifier.dart';
import 'memory_provisioning.dart';
import 'procedure_selector.dart';
import 'run_coordinator.dart';

/// Tears a started access layer down (stop listening, close sockets).
///
/// Returned by an [AccessLayerInstaller] and invoked by [BootedBrain.shutdown]
/// *before* memory and substrate are closed, so no new inbound work arrives
/// while the brain winds down.
typedef AccessLayerShutdown = Future<void> Function();

/// Installs and starts the inbound access layer over a booted [Dispatcher].
///
/// The prototype ships no channel, so [BrainProcessConfig.installAccessLayer]
/// defaults to `null` (no access layer). Phase E supplies an installer that
/// constructs the OpenAI HTTP/SSE + Telegram surface, points it at
/// [dispatcher], starts listening, and returns the [AccessLayerShutdown] the
/// boot stores and invokes on shutdown. The installer is the single seam
/// through which a channel reaches the booted dispatcher — boot never speaks a
/// wire protocol itself.
typedef AccessLayerInstaller =
    Future<AccessLayerShutdown> Function(Dispatcher dispatcher);

/// The inbound prompt argument key the prototype's one routed procedure
/// (`answer_with_memory_v1`, § 11) reads as `text`.
///
/// Boot's route binds `access.envelope.text` under this key when it builds the
/// [ProcedureInvocation]; the procedure's `recall(text: …)` / answer steps read
/// it back. Named once here so the route and the procedure header share one
/// spelling.
const String inboundTextArgumentKey = 'text';

/// Declares how to boot the prototype brain process.
///
/// Carries the brought-up-from collaborators (the in-process substrate, the
/// memory provisioning choice) and the engine/dispatcher wiring knobs. An
/// instance is consumed exactly once by [BrainProcessBoot.boot].
final class BrainProcessConfig {
  /// The in-process substrate client the engine's `sub` bridge binds against.
  ///
  /// Brought up first: boot calls `substrate.open(substrateConfig)` when
  /// [substrateConfig] is non-null. Injected by the caller — production passes
  /// an `InProcessTomBrainSubstrate`; tests pass a fake `TomBrainSubstrateClient`.
  final TomBrainSubstrateClient substrate;

  /// The config boot opens the substrate against, or `null` to skip the open
  /// call.
  ///
  /// A production boot supplies the real [SubstrateConfig] so the role registry
  /// validates before any run issues an `llm` call. A test fake that needs no
  /// open (its `open` is a no-op) may pass `null` to skip it entirely.
  final SubstrateConfig? substrateConfig;

  /// How to provision memory (§ 12 / D.43). [MemoryTransport.isolate] by
  /// default — the production topology; tests pass
  /// [MemoryProvisioningConfig.inProcess].
  final MemoryProvisioningConfig memoryProvisioning;

  /// The directory the disk procedure store reads system procedures from
  /// (`answer_with_memory_v1` lives here). Defaults to `scripts/system`.
  final Directory systemScriptsDir;

  /// The directory the disk store reads user procedures from, or `null` when
  /// the prototype ships none.
  final Directory? userScriptsDir;

  /// The foreground FIFO queue depth the [RunCoordinator] admits behind a busy
  /// foreground slot (D.19). Defaults to the coordinator's own default (4).
  final int foregroundQueueDepth;

  /// Installs the inbound access layer over the booted dispatcher, or `null`
  /// for the prototype default (no channel). See [AccessLayerInstaller].
  final AccessLayerInstaller? installAccessLayer;

  /// Builds a boot config.
  BrainProcessConfig({
    required this.substrate,
    required this.memoryProvisioning,
    this.substrateConfig,
    Directory? systemScriptsDir,
    this.userScriptsDir,
    this.foregroundQueueDepth = 4,
    this.installAccessLayer,
  }) : systemScriptsDir = systemScriptsDir ?? Directory('scripts/system');
}

/// A booted, running brain process plus its teardown.
///
/// Every collaborator is assembled and live the moment
/// [BrainProcessBoot.boot] resolves: the substrate is open, memory is
/// provisioned and open, the engine is wired over both bridges, and the
/// [dispatcher] is ready to [Dispatcher.accept] inbound `Access` objects. The
/// caller owns the lifetime — call [shutdown] exactly once when finished.
final class BootedBrain {
  /// The single inbound entry point (PE-11). A Phase-E adapter (or a test)
  /// constructs one [Access] per request and calls `dispatcher.accept(it)`;
  /// the boot-built route classifies, selects, and schedules it on the engine.
  final Dispatcher dispatcher;

  /// The procedure engine the route runs selected procedures through. Exposed
  /// for inspection / direct invocation in tests.
  final ProcedureEngine engine;

  /// The foreground/background run coordinator the route schedules through.
  /// Exposed so the free-time scheduler (D.33) and tests share the one
  /// coordinator the inbound path drives.
  final RunCoordinator coordinator;

  /// The provisioned memory handle (client + transport + optional isolate
  /// host). Exposed so D.45/D.46 can observe the worker and confirm a clean
  /// close.
  final ProvisionedMemory memory;

  /// The in-process substrate boot opened. Exposed for inspection; closed by
  /// [shutdown].
  final TomBrainSubstrateClient substrate;

  final AccessLayerShutdown? _accessLayerShutdown;
  bool _shutDown = false;

  BootedBrain._({
    required this.dispatcher,
    required this.engine,
    required this.coordinator,
    required this.memory,
    required this.substrate,
    required AccessLayerShutdown? accessLayerShutdown,
  }) : _accessLayerShutdown = accessLayerShutdown;

  /// Tears the booted process down cleanly. Idempotent — a second call is a
  /// no-op, so it is safe in a `finally` block.
  ///
  /// Order is the reverse of bring-up so nothing is torn down while still in
  /// use: (1) stop the access layer first (no new inbound arrives), (2) dispose
  /// memory (the isolate transport flushes writes + checkpoints the WAL before
  /// closing the worker), (3) close the substrate. The *full* drain — finishing
  /// the current foreground run best-effort and emptying the foreground queue
  /// before closing memory/trails — is layered on by D.45; D.44 ships the
  /// resource teardown the drain wraps.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    if (_accessLayerShutdown != null) {
      await _accessLayerShutdown();
    }
    await memory.dispose();
    await substrate.close();
  }
}

/// Brings the prototype brain process up in the § 12 order.
///
/// Stateless: [boot] is the whole surface. It is a class (not a bare function)
/// so the bring-up sequence has a named home the spec section maps onto and so
/// later steps (D.45 drain, D.46 typed-startup-error) extend one type.
abstract final class BrainProcessBoot {
  /// Boots a brain process per [config] and returns the running [BootedBrain].
  ///
  /// Sequence (§ 12): open the in-process substrate → provision memory (isolate
  /// by default) → build the engine over both bridges + the disk procedure
  /// store → wrap it in the classify→select→schedule route behind a single
  /// [Dispatcher] → install the access layer (if any).
  ///
  /// Failure hygiene: a failure *after* a resource is up tears that resource
  /// back down before the error propagates, so a failed boot leaks neither an
  /// open substrate nor a spawned memory isolate. (Wrapping the failure in a
  /// typed startup error is D.46.)
  static Future<BootedBrain> boot(BrainProcessConfig config) async {
    // ── 1. Substrate (in-process), opened first. ──
    final substrate = config.substrate;
    if (config.substrateConfig != null) {
      await substrate.open(config.substrateConfig!);
    }

    // From here a failure must close the substrate before rethrowing.
    ProvisionedMemory? memory;
    try {
      // ── 2. Memory (isolate by default), via the D.43 seam. ──
      memory = await MemoryProvisioner(config.memoryProvisioning).provision();

      // ── 3. Engine + dispatcher (main isolate). ──
      final resolver = await ProcedureResolver.fromStore(
        DiskProcedureStore(
          systemDir: config.systemScriptsDir,
          userDir: config.userScriptsDir,
        ),
      );

      // One shared preemption state for the engine (yields against it) and the
      // coordinator (drives it) — see the file header.
      final preemption = PreemptionState();

      final engine = ProcedureEngine(
        resolver: resolver,
        memory: memory.client,
        memoryBridge: MemoryBridge(memory.client),
        substrateBridge: SubstrateBridge(substrate),
        preemptionState: preemption,
      );

      final coordinator = RunCoordinator(
        preemption: preemption,
        foregroundQueueDepth: config.foregroundQueueDepth,
      );

      final classifier = InboundClassifier();
      final selector = ProcedureSelector();

      final dispatcher = Dispatcher(
        route: _buildRoute(
          classifier: classifier,
          selector: selector,
          coordinator: coordinator,
          engine: engine,
        ),
      );

      // ── 4. The future access layer (Phase E), via the installer seam. ──
      final accessLayerShutdown =
          await config.installAccessLayer?.call(dispatcher);

      return BootedBrain._(
        dispatcher: dispatcher,
        engine: engine,
        coordinator: coordinator,
        memory: memory,
        substrate: substrate,
        accessLayerShutdown: accessLayerShutdown,
      );
    } catch (_) {
      // Bring-up failed after a resource was up: tear the brought-up resources
      // back down (reverse order) so a failed boot leaks nothing, then rethrow.
      await memory?.dispose();
      await substrate.close();
      rethrow;
    }
  }

  /// Builds the `classify → select → schedule` route the [Dispatcher] hands
  /// each admitted [Access] to.
  ///
  /// The route classifies the inbound kind (kind-hint pass-through, else the
  /// `classify_inbound_v1` stub, D.15), selects the procedure id
  /// (`user_prompt` → `answer_with_memory_v1`, else `UnsupportedProcedureKind`,
  /// D.16), and schedules the run on the foreground slot of the shared
  /// [coordinator] (D.18). The procedure reads the inbound prompt off the
  /// `text` argument; per Q-D.38.1/Q-D.42.1 the answer reaches the channel
  /// through `Access.deliver` only once the access layer (Phase E) wires
  /// delivery — the prototype route runs the procedure to completion and the
  /// answer lands in memory + the run outcome.
  static DispatchRoute _buildRoute({
    required InboundClassifier classifier,
    required ProcedureSelector selector,
    required RunCoordinator coordinator,
    required ProcedureEngine engine,
  }) {
    return (Access access) async {
      final kind = classifier.classify(access);
      // `UnsupportedProcedureKind` propagates unchanged through accept (D.16).
      final procedureId = selector.select(kind);
      await coordinator.submitForeground(
        () => engine
            .invoke(
              ProcedureInvocation(
                procedureId: procedureId,
                arguments: <String, Object?>{
                  inboundTextArgumentKey: access.envelope.text,
                },
              ),
            )
            .outcome,
        procedureId: procedureId,
      );
    };
  }
}
