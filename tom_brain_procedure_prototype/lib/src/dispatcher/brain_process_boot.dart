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
// which layers on the minimal teardown here.
//
// ── What D.46 adds — the typed startup error ──────────────────────────
//
// D.44 kept boot's failure behaviour honest (a failure after a resource is up
// tears that resource back down so a failed boot leaks nothing) but let the raw
// failure propagate untyped. D.46 wraps every bring-up failure in a
// [BrainStartupError] that names the [BootPhase] it failed in and carries the
// original `cause` (+ its stack trace). A memory-isolate spawn/open crash now
// surfaces as `BrainStartupError(phase: BootPhase.memory, cause: …)` rather than
// a bare `IsolateBoundaryException`, so a caller can branch on *which* part of
// the bring-up failed without string-matching. The failure-hygiene teardown is
// unchanged — the wrapping happens around it, so a failed boot still leaks
// nothing.
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
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Access, OutboundChunk, PreemptionState;

import '../api/procedure_engine.dart';
import '../api/procedure_invocation.dart';
import '../api/procedure_outcome.dart';
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

/// The default best-effort bound [BootedBrain.shutdown] gives the coordinator
/// drain (D.45).
///
/// A graceful shutdown finishes the in-flight foreground run (and drains the
/// FIFO queue) so trails close before memory is flushed — but a genuinely-hung
/// body must not hold the process open forever. This is the wall-clock bound
/// past which the drain gives up waiting and shutdown proceeds to close memory
/// and the substrate; the abandoned body, if any, runs on untracked.
///
/// Sized to sit *above* the coordinator's own hard step deadline
/// (`defaultStepDeadline` + `defaultCoordinatorDeadlineGrace` = ~65 s) so the
/// normal bound on a run is the coordinator's force-yield — which itself frees
/// the slot and idles the coordinator — and this drain timeout fires only for a
/// run that bypassed *both* the engine and coordinator deadlines (e.g. an
/// already-abandoned force-yielded body). The exact value is a config knob D.47
/// (`DispatcherConfig`) can later surface.
const Duration defaultShutdownDrainTimeout = Duration(seconds: 90);

/// Which stage of [BrainProcessBoot.boot]'s § 12 bring-up sequence failed.
///
/// Carried by a [BrainStartupError] so a caller can tell a substrate failure
/// from a memory-isolate crash from an engine-build failure from an
/// access-layer install failure without inspecting the wrapped cause.
enum BootPhase {
  /// Opening the in-process substrate (`substrate.open(substrateConfig)`).
  substrate,

  /// Provisioning memory through the D.43 seam (`MemoryProvisioner.provision`)
  /// — the phase a spawned-isolate crash surfaces in.
  memory,

  /// Building the engine + coordinator + dispatcher (resolving the procedure
  /// store, wiring the bridges, assembling the route).
  engine,

  /// Installing the inbound access layer (`installAccessLayer(dispatcher)`).
  accessLayer,
}

/// A bring-up failure, tagged with the [BootPhase] it occurred in.
///
/// [BrainProcessBoot.boot] wraps every failure raised while bringing the
/// process up in this type (D.46), so a memory-isolate spawn/open crash
/// surfaces as `BrainStartupError(phase: BootPhase.memory, …)` rather than a
/// bare transport exception. The original failure is preserved in [cause] (with
/// its [causeStackTrace]) so nothing is lost by the wrapping.
final class BrainStartupError implements Exception {
  /// The bring-up stage that failed.
  final BootPhase phase;

  /// The original error that caused the bring-up to fail (e.g. the
  /// `IsolateBoundaryException` from a crashing memory factory).
  final Object cause;

  /// The stack trace captured where [cause] was caught, or `null` when none was
  /// available.
  final StackTrace? causeStackTrace;

  /// Wraps [cause] (raised in [phase]) as a typed startup error.
  BrainStartupError({
    required this.phase,
    required this.cause,
    this.causeStackTrace,
  });

  @override
  String toString() => 'BrainStartupError(phase: ${phase.name}): $cause';
}

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

  /// The fallback the dispatcher's [InboundClassifier] runs when an admitted
  /// [Access] carries no kind-hint, or `null` for the default
  /// ([classifyInboundV1] — every un-hinted inbound is a `user_prompt`, D.15).
  ///
  /// `classify_inbound_v1` is the prototype's stand-in for the LLM classifier
  /// path: an access edge that attaches a confident kind-hint (E.33) makes the
  /// dispatcher take the pass-through branch and *not* call this fallback. The
  /// seam is exposed here so the E.50 end-to-end smoke can inject a spy and
  /// prove that short-circuit — the `InboundClassifier` itself has always taken
  /// an injectable fallback; this only threads it through boot.
  final ClassifyFallback? classifyFallback;

  /// Builds a boot config.
  BrainProcessConfig({
    required this.substrate,
    required this.memoryProvisioning,
    this.substrateConfig,
    Directory? systemScriptsDir,
    this.userScriptsDir,
    this.foregroundQueueDepth = 4,
    this.installAccessLayer,
    this.classifyFallback,
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
  /// use (D.45):
  ///
  ///   1. **Stop the access layer first** — no new inbound `Access` arrives,
  ///      so the coordinator's live work can only shrink.
  ///   2. **Drain the coordinator** ([RunCoordinator.drain]) — refuse new
  ///      submissions and best-effort wait for the in-flight foreground run
  ///      (plus everything already queued behind it) and any live background
  ///      run to reach their natural end, so each run's `RunRecorder` closes
  ///      its trail durably *before* memory is flushed. Bounded by
  ///      [drainTimeout] so a genuinely-hung body cannot hold shutdown hostage.
  ///   3. **Dispose memory** — the isolate transport flushes writes +
  ///      checkpoints the WAL before closing the worker, persisting the trails
  ///      the drain let close.
  ///   4. **Close the substrate.**
  ///
  /// [drainTimeout] bounds step 2's best-effort wait; it defaults to
  /// [defaultShutdownDrainTimeout]. Pass a `null` timeout
  /// (`shutdown(drainTimeout: null)`) to wait for the coordinator to fall fully
  /// idle with no bound.
  Future<void> shutdown({
    Duration? drainTimeout = defaultShutdownDrainTimeout,
  }) async {
    if (_shutDown) return;
    _shutDown = true;
    if (_accessLayerShutdown != null) {
      await _accessLayerShutdown();
    }
    await coordinator.drain(timeout: drainTimeout);
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
  /// open substrate nor a spawned memory isolate.
  ///
  /// Typed failure (D.46): every bring-up failure is wrapped in a
  /// [BrainStartupError] that names the [BootPhase] it failed in (the original
  /// error is preserved in [BrainStartupError.cause]). A memory-isolate
  /// spawn/open crash therefore surfaces as
  /// `BrainStartupError(phase: BootPhase.memory, …)`.
  static Future<BootedBrain> boot(BrainProcessConfig config) async {
    final substrate = config.substrate;

    // ── 1. Substrate (in-process), opened first. ──
    if (config.substrateConfig != null) {
      await _inPhase(
        BootPhase.substrate,
        () => substrate.open(config.substrateConfig!),
      );
    }

    // From here a failure must close the substrate (and any provisioned memory)
    // before rethrowing.
    ProvisionedMemory? memory;
    try {
      // ── 2. Memory (isolate by default), via the D.43 seam. ──
      final provisioned = await _inPhase(
        BootPhase.memory,
        () => MemoryProvisioner(config.memoryProvisioning).provision(),
      );
      memory = provisioned;

      // ── 3. Engine + dispatcher (main isolate). ──
      final built = await _inPhase(
        BootPhase.engine,
        () => _buildEngine(config: config, memory: provisioned, substrate: substrate),
      );

      // ── 4. The future access layer (Phase E), via the installer seam. ──
      final accessLayerShutdown = await _inPhase<AccessLayerShutdown?>(
        BootPhase.accessLayer,
        () async {
          final installer = config.installAccessLayer;
          if (installer == null) return null;
          return installer(built.dispatcher);
        },
      );

      return BootedBrain._(
        dispatcher: built.dispatcher,
        engine: built.engine,
        coordinator: built.coordinator,
        memory: provisioned,
        substrate: substrate,
        accessLayerShutdown: accessLayerShutdown,
      );
    } catch (_) {
      // Bring-up failed after a resource was up: tear the brought-up resources
      // back down (reverse order) so a failed boot leaks nothing, then rethrow
      // (the error is already a `BrainStartupError` from `_inPhase`).
      await memory?.dispose();
      await substrate.close();
      rethrow;
    }
  }

  /// Runs one bring-up [phase] and wraps any non-[BrainStartupError] failure it
  /// raises in a [BrainStartupError] tagged with [phase] (D.46).
  ///
  /// An already-typed [BrainStartupError] propagates unchanged (never
  /// double-wrapped), so a phase that itself called `boot` would surface the
  /// inner phase tag.
  static Future<T> _inPhase<T>(
    BootPhase phase,
    Future<T> Function() body,
  ) async {
    try {
      return await body();
    } on BrainStartupError {
      rethrow;
    } catch (error, stackTrace) {
      throw BrainStartupError(
        phase: phase,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  /// Builds the engine + coordinator + dispatcher over the provisioned [memory]
  /// and the open [substrate] (bring-up phase 3).
  ///
  /// The engine and coordinator share *one* [PreemptionState] (the engine
  /// yields against it; the coordinator drives it — see the file header).
  static Future<({Dispatcher dispatcher, ProcedureEngine engine, RunCoordinator coordinator})>
      _buildEngine({
    required BrainProcessConfig config,
    required ProvisionedMemory memory,
    required TomBrainSubstrateClient substrate,
  }) async {
    final resolver = await ProcedureResolver.fromStore(
      DiskProcedureStore(
        systemDir: config.systemScriptsDir,
        userDir: config.userScriptsDir,
      ),
    );

    // One shared preemption state for the engine (yields against it) and the
    // coordinator (drives it).
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

    final dispatcher = Dispatcher(
      route: _buildRoute(
        // The kind-hint pass-through is unconditional; only the no-hint
        // fallback is configurable. A `null` fallback keeps the D.15 default
        // (`classify_inbound_v1`).
        classifier: config.classifyFallback == null
            ? InboundClassifier()
            : InboundClassifier(fallback: config.classifyFallback!),
        selector: ProcedureSelector(),
        coordinator: coordinator,
        engine: engine,
      ),
    );

    return (dispatcher: dispatcher, engine: engine, coordinator: coordinator);
  }

  /// Builds the `classify → select → schedule` route the [Dispatcher] hands
  /// each admitted [Access] to.
  ///
  /// The route classifies the inbound kind (kind-hint pass-through, else the
  /// `classify_inbound_v1` stub, D.15), selects the procedure id
  /// (`user_prompt` → `answer_with_memory_v1`, else `UnsupportedProcedureKind`,
  /// D.16), and schedules the run on the foreground slot of the shared
  /// [coordinator] (D.18). The procedure reads the inbound prompt off the
  /// `text` argument.
  ///
  /// Outbound delivery (Q-D.38.1 / Q-D.42.1, resolved at E.47). The prototype's
  /// one procedure produces the *whole* answer as a single `answer` output (the
  /// substrate bridge concatenates the token stream, Q-C.13.1), so once the run
  /// completes the route hands that answer back to the originating channel as a
  /// single final [OutboundChunk] through `Access.deliver`. The returned stream
  /// is the backpressure channel (E.39): the route drains it to surface a
  /// delivery stall as a thrown error and otherwise ignores it. A run that
  /// produced no usable result (truncated by the step deadline, or crashed)
  /// delivers nothing — the answer simply never reaches the channel.
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
      final ProcedureOutcome outcome = await coordinator.submitForeground(
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

      final String? answer = outcome.result?.output<String>('answer');
      if (answer != null) {
        await access
            .deliver(OutboundChunk(textDelta: answer, isFinal: true))
            .drain<void>();
      }
    };
  }
}
