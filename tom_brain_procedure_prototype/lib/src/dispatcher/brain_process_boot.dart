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
    show Access, ConversationHistory, HistoryTurn, OutboundChunk, PreemptionState;

import '../api/procedure_engine.dart';
import '../api/procedure_invocation.dart';
import '../api/procedure_outcome.dart';
import '../bridges/memory_bridge.dart';
import '../bridges/substrate_bridge.dart';
import '../budget/budget.dart' show MemoryWriteLimits;
import '../extensions/extensions.dart'
    show BrainEngineExtensions, BrainExtensionConfig;
import '../mcp/mcp_client.dart' show McpConnector;
import '../procedure_store/disk_procedure_store.dart';
import '../recorder/llm_trail_record.dart' show LlmTrailSink;
import '../recorder/memory_access_record.dart' show MemoryAccessSink;
import '../recorder/procedure_tree_record.dart' show ProcedureTreeSink;
import '../recorder/turn_summary.dart' show TurnSummary, TurnSummarySink;
import '../procedure_store/procedure_resolver.dart';
import 'dispatcher_entry.dart';
import 'inbound_classifier.dart';
import 'memory_provisioning.dart';
import 'procedure_routing.dart';
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

/// The conversation-history argument key the routed procedure
/// (`answer_with_memory_v1`, § 11) reads as `priorTurns` (access spec § 7.2 /
/// § 21.5).
///
/// Boot's route binds the answering session's earlier turns under this key —
/// each a `{user, assistant}` map drawn from `access.history` — so the
/// procedure can render the conversation so far into the answer prompt. Absent
/// on a cold first turn (no history, or only the just-admitted turn), so the
/// procedure treats a missing key as "no history" (PE-9).
const String priorTurnsArgumentKey = 'priorTurns';

/// The default best-effort bound [BootedBrain.shutdown] gives the coordinator
/// drain (D.45).
///
/// A graceful shutdown finishes the in-flight foreground run (and drains the
/// FIFO queue) so trails close before memory is flushed — but a genuinely-hung
/// body must not hold the process open forever. This is the wall-clock bound
/// past which the drain gives up waiting and shutdown proceeds to close memory
/// and the substrate; the abandoned body, if any, runs on untracked.
///
/// Tied to the coordinator's own hard step deadline
/// ([defaultCoordinatorHardStepDeadline] = `defaultStepDeadline` 60 s +
/// `defaultCoordinatorDeadlineGrace` 5 s = 65 s) plus a 25 s margin = 90 s, so
/// the two cannot silently drift apart (F.5.2): the drain must sit *above* the
/// coordinator's force-yield so the normal bound on a run is that force-yield —
/// which itself frees the slot and idles the coordinator — and this drain
/// timeout fires only for a run that bypassed *both* the engine and coordinator
/// deadlines (e.g. an already-abandoned force-yielded body). The exact value is
/// a config knob D.47 (`DispatcherConfig`) can later surface.
///
/// A literal, not `defaultCoordinatorHardStepDeadline + Duration(seconds: 25)`,
/// because Dart `const` evaluation forbids `Duration` arithmetic (only `num` /
/// `String` operands are allowed) and this must stay `const` to feed the `const`
/// default of [BootedBrain.shutdown]'s `drainTimeout`. The anti-drift
/// relationship `defaultShutdownDrainTimeout > defaultCoordinatorHardStepDeadline`
/// is asserted by `test/f_dispatcher_cleanup_test.dart`.
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

  /// The process-wide NON-FATAL per-run memory-write caps (spec § 5.4) boot
  /// threads onto the [ProcedureEngine]. Every run gets a fresh
  /// `MemoryWriteGuard` over these, so a runaway write loop is skipped (the
  /// side effect never runs), reported on the run trail, and the run continues.
  /// Defaults to [MemoryWriteLimits.standard] — virtually unlimited for any
  /// real request, bounded enough to catch a loop.
  final MemoryWriteLimits memoryWriteLimits;

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

  /// The declarative Extension-F config (Plan step 15; § 13, § 21.5, § 21.6),
  /// or `null` for the prototype default (no tool/MCP/LLM-config bundle).
  ///
  /// When non-null, boot assembles it into a [BrainEngineExtensions] during the
  /// engine phase (loading the provider registry, eagerly validating the
  /// required prompt types, building the MCP client) and threads the bundle onto
  /// the [ProcedureEngine] so a future `call_llm_v1` can read it. A
  /// missing-template / unresolvable-model failure surfaces as a
  /// `BrainStartupError(phase: BootPhase.engine, …)` — before any run, hence
  /// before any substrate call. Assembling requires an [mcpConnector].
  final BrainExtensionConfig? extensions;

  /// The MCP connector [extensions] is assembled over (the transport the MCP
  /// client opens connections through). Required when [extensions] is non-null;
  /// ignored otherwise. Production passes a `DartMcpConnector`; tests pass a
  /// connector double.
  final McpConnector? mcpConnector;

  /// The raw-LLM-trail sink (`tom_brain_logging.md` §5.2 / §10 step #4), or
  /// `null` for the prototype default (no raw LLM trail). When non-null, boot
  /// threads it onto the [ProcedureEngine] so every run's substrate bridge fires
  /// one record per completed `llm` call into it. Production binds an
  /// `LlmTrailWriter.write` built from the `trail:` config; tests pass a capture
  /// closure.
  final LlmTrailSink? llmTrailSink;

  /// The per-profile memory-access sink (`tom_brain_logging.md` §5.6 / §10 step
  /// #8), or `null` for the prototype default (no per-profile memory log). When
  /// non-null, boot threads it onto the [ProcedureEngine] so every run's memory
  /// bridge reports one record per completed memory access (recall / persist /
  /// edge / stackPush) into it, stamped with the request's memory profile.
  /// Production binds a `MemoryProfileLogWriter.write` built from the `trail:`
  /// config; tests pass a capture closure.
  final MemoryAccessSink? memoryAccessSink;

  /// The per-procedure combined run-tree sink (`tom_brain_logging.md` §5.7 / §10
  /// step #9), or `null` for the prototype default (no per-procedure tree). When
  /// non-null, boot threads it onto the [ProcedureEngine] so every top-level (or
  /// turn-less dream) run assembles one combined tree — its own trail entries
  /// plus each nested run's sub-record spliced in — and fires it here.
  /// Production binds a `ProcedureTreeWriter.write` built from the `trail:`
  /// config; tests pass a capture closure.
  final ProcedureTreeSink? procedureTreeSink;

  /// The per-turn summary sink (`tom_brain_logging.md` §5.4 / §5.5 / §10 step
  /// #5), or `null` for the prototype default (no per-turn narrative). When
  /// non-null, the dispatch route fires one [TurnSummary] per completed user
  /// turn — carrying the inbound prompt and the final answer — so the host's
  /// summary fan-out can flush the turn's session + global narrative block.
  /// Production binds the `SummaryFanout.onTurnComplete`; tests pass a capture
  /// closure. Best-effort and non-blocking (§9).
  final TurnSummarySink? turnSummarySink;

  /// Builds a boot config.
  ///
  /// [extensions] + [mcpConnector] must be supplied together: an [extensions]
  /// without a connector is a configuration error caught at boot.
  BrainProcessConfig({
    required this.substrate,
    required this.memoryProvisioning,
    this.substrateConfig,
    Directory? systemScriptsDir,
    this.userScriptsDir,
    this.foregroundQueueDepth = 4,
    this.memoryWriteLimits = MemoryWriteLimits.standard,
    this.installAccessLayer,
    this.classifyFallback,
    this.extensions,
    this.mcpConnector,
    this.llmTrailSink,
    this.memoryAccessSink,
    this.procedureTreeSink,
    this.turnSummarySink,
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
  ///   3. **Close the coordinator** ([RunCoordinator.close]) — once it has
  ///      quiesced, close its owned `PreemptionController` so its event
  ///      subscribers see the done-stream and no controller resource outlives
  ///      the boot (F.3.2). Done after the drain so no transition emits onto a
  ///      closed stream.
  ///   4. **Close the Extension-F bundle** ([BrainEngineExtensions.close]) —
  ///      tears the MCP client's connection pool down once no run can issue a
  ///      tool/MCP call. No-op when no extension bundle was assembled.
  ///   5. **Dispose memory** — the isolate transport flushes writes +
  ///      checkpoints the WAL before closing the worker, persisting the trails
  ///      the drain let close.
  ///   6. **Close the substrate.**
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
    await coordinator.close();
    await engine.extensions?.close();
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
    final resolver = await _resolveProcedures(config);

    // The Extension-F runtime bundle (Plan step 15), assembled inside the
    // engine phase so a missing template / unresolvable model surfaces as a
    // `BrainStartupError(phase: BootPhase.engine, …)` before any run — hence
    // before any substrate call. `null` when no extension config was supplied.
    final extensions = await _assembleExtensions(config);

    // One shared preemption state for the engine (yields against it) and the
    // coordinator (drives it) — see the file header.
    final preemption = PreemptionState();

    final engine = _wireEngine(
      memory: memory,
      substrate: substrate,
      resolver: resolver,
      preemption: preemption,
      extensions: extensions,
      llmTrailSink: config.llmTrailSink,
      memoryAccessSink: config.memoryAccessSink,
      procedureTreeSink: config.procedureTreeSink,
      memoryWriteLimits: config.memoryWriteLimits,
    );
    final coordinator = _wireCoordinator(config: config, preemption: preemption);
    final dispatcher = _wireDispatcher(
      config: config,
      coordinator: coordinator,
      engine: engine,
    );

    return (dispatcher: dispatcher, engine: engine, coordinator: coordinator);
  }

  /// Resolves the disk procedure store (system + optional user scripts) into a
  /// [ProcedureResolver] (bring-up phase 3, step 1).
  static Future<ProcedureResolver> _resolveProcedures(
    BrainProcessConfig config,
  ) =>
      ProcedureResolver.fromStore(
        DiskProcedureStore(
          systemDir: config.systemScriptsDir,
          userDir: config.userScriptsDir,
        ),
      );

  /// Assembles the optional Extension-F runtime bundle (Plan step 15) from
  /// [BrainProcessConfig.extensions], or returns `null` when none is configured.
  ///
  /// Requires [BrainProcessConfig.mcpConnector] when an extension config is
  /// present — an `extensions` without a connector is a configuration error
  /// (`StateError`) that the engine-phase wrapper turns into a
  /// `BrainStartupError(phase: BootPhase.engine, …)`.
  static Future<BrainEngineExtensions?> _assembleExtensions(
    BrainProcessConfig config,
  ) async {
    final extensionConfig = config.extensions;
    if (extensionConfig == null) return null;
    final connector = config.mcpConnector;
    if (connector == null) {
      throw StateError(
        'BrainProcessConfig.extensions requires a non-null mcpConnector to '
        'assemble the Extension-F bundle.',
      );
    }
    return BrainEngineExtensions.assemble(extensionConfig, connector: connector);
  }

  /// Wires the [ProcedureEngine] over both bridges, the shared [preemption]
  /// state (the engine yields against it via `yield_if_foreground_waiting`), the
  /// optional Extension-F [extensions] bundle, the optional [llmTrailSink]
  /// the engine forwards each run's raw-LLM-call observations to (§10 step #4),
  /// the optional [memoryAccessSink] it forwards each run's bridged-memory
  /// calls to for the per-profile memory log (§10 step #8), and the optional
  /// [procedureTreeSink] it fires one combined run-tree to per top-level run
  /// (§10 step #9).
  static ProcedureEngine _wireEngine({
    required ProvisionedMemory memory,
    required TomBrainSubstrateClient substrate,
    required ProcedureResolver resolver,
    required PreemptionState preemption,
    required BrainEngineExtensions? extensions,
    required LlmTrailSink? llmTrailSink,
    required MemoryAccessSink? memoryAccessSink,
    required ProcedureTreeSink? procedureTreeSink,
    required MemoryWriteLimits memoryWriteLimits,
  }) =>
      ProcedureEngine(
        resolver: resolver,
        memory: memory.client,
        memoryBridge: MemoryBridge(memory.client),
        substrateBridge: SubstrateBridge(substrate),
        preemptionState: preemption,
        extensions: extensions,
        llmTrailSink: llmTrailSink,
        memoryAccessSink: memoryAccessSink,
        procedureTreeSink: procedureTreeSink,
        memoryWriteLimits: memoryWriteLimits,
      );

  /// Wires the [RunCoordinator] over the shared [preemption] state (it drives
  /// the write side) with the configured foreground queue depth.
  static RunCoordinator _wireCoordinator({
    required BrainProcessConfig config,
    required PreemptionState preemption,
  }) =>
      RunCoordinator(
        preemption: preemption,
        foregroundQueueDepth: config.foregroundQueueDepth,
      );

  /// Wires the [Dispatcher] over the classify→select→schedule route built
  /// against the shared [coordinator] and [engine].
  static Dispatcher _wireDispatcher({
    required BrainProcessConfig config,
    required RunCoordinator coordinator,
    required ProcedureEngine engine,
  }) =>
      Dispatcher(
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
          turnSummarySink: config.turnSummarySink,
        ),
      );

  /// Builds the `classify → select → schedule` route the [Dispatcher] hands
  /// each admitted [Access] to.
  ///
  /// The route resolves the procedure id (`resolveProcedureId`, Q-E.50.1): a
  /// confident centroid hint on `access.envelope.kindHint` routes directly to
  /// the procedure (`UnknownProcedureHint` if it names none), else the
  /// `classify_inbound_v1` stub (D.15) produces a kind that selection maps
  /// (`user_prompt` → `answer_with_memory_v1`, else `UnsupportedProcedureKind`,
  /// D.16). It then schedules the run on the foreground slot of the shared
  /// [coordinator] (D.18). The procedure reads the inbound prompt off the
  /// `text` argument.
  ///
  /// Outbound delivery (Q-D.38.1 / Q-D.42.1, resolved at E.47; P1.3 #8). The
  /// external/user request path streams its answer increment-by-increment: the
  /// route binds a per-run token sink to `engine.invoke(tokenSink: …)`, so each
  /// `sub.llm(...)` chunk (and any `emit(...)` the body authors) reaches the
  /// originating channel as a non-final [OutboundChunk] through `Access.deliver`
  /// *while the run is still in flight*. Each delivery's returned stream is the
  /// backpressure channel (E.39): the sink drains it so a delivery stall
  /// surfaces as a thrown error that pushes back into the body's own pacing.
  /// Once the run completes successfully the route sends a single empty
  /// terminator chunk (`textDelta: '', isFinal: true`) — the deltas already
  /// carried the text, so the terminator only marks the end of the stream. A
  /// run that produced no usable result (truncated by the step deadline, or
  /// crashed) sends no terminator — the stream simply stops where it stalled.
  static DispatchRoute _buildRoute({
    required InboundClassifier classifier,
    required ProcedureSelector selector,
    required RunCoordinator coordinator,
    required ProcedureEngine engine,
    required TurnSummarySink? turnSummarySink,
  }) {
    return (Access access) async {
      // A confident centroid hint routes directly to its procedure; a no-hint
      // inbound falls back through classify → select (Q-E.50.1). Either
      // failure (`UnknownProcedureHint` / `UnsupportedProcedureKind`)
      // propagates unchanged through accept (D.16).
      final procedureId = resolveProcedureId(
        access,
        classifier: classifier,
        selector: selector,
      );

      // The per-run outbound channel (P1.3 #8): each delta the run streams is
      // delivered as a non-final chunk and drained for backpressure so a
      // stalled channel pushes back into the body's pacing.
      Future<void> streamDelta(String textDelta) => access
          .deliver(OutboundChunk(textDelta: textDelta, isFinal: false))
          .drain<void>();

      // When the turn began serving — the §5.4 turn-header timestamp. Captured
      // before the run so it brackets the whole turn.
      final startedAt = DateTime.now().toUtc();

      // The answering session's earlier turns, threaded in so the procedure can
      // render the conversation so far into the answer prompt (access § 7.2 /
      // § 21.5). Drawn off `access.history` here, before the run; back-filled
      // with this turn's answer afterwards (below) so the next turn sees it.
      final priorTurns = _priorTurnsFrom(access.history);

      ProcedureOutcome? outcome;
      try {
        final ProcedureOutcome result = await coordinator.submitForeground(
          () => engine
              .invoke(
                ProcedureInvocation(
                  procedureId: procedureId,
                  arguments: <String, Object?>{
                    inboundTextArgumentKey: access.envelope.text,
                    if (priorTurns.isNotEmpty)
                      priorTurnsArgumentKey: priorTurns,
                  },
                  // Carry the access-edge-minted turn id (logging-spec §3) onto
                  // the invocation so the engine threads it — plus a per-turn
                  // `callSeq` — onto every substrate call this turn issues.
                  turnId: access.turnId,
                  // Carry the request's memory profile (logging-spec §5.6) so
                  // the engine stamps it onto every memory access this turn
                  // issues, bucketing the per-profile memory log correctly.
                  memoryProfile: access.session.memoryProfile,
                ),
                tokenSink: streamDelta,
              )
              .outcome,
          procedureId: procedureId,
        );
        outcome = result;

        // The run completed: terminate the stream. The deltas already carried
        // the answer text, so the terminator is an empty final marker. A run
        // that produced no usable result (truncated / crashed) sends nothing.
        final answer = result.result?.output<String>('answer');
        if (answer != null) {
          // Back-fill the answer into the turn this prompt created (access
          // § 7.2 #4). The SessionManager appended an answer-less turn when it
          // admitted the prompt; recording the answer now means the *next*
          // turn's `priorTurns` includes this exchange — closing the loop that
          // made the brain forget what it had just said.
          access.history?.amendLastTurnAnswer(answer);
          await access
              .deliver(OutboundChunk(textDelta: '', isFinal: true))
              .drain<void>();
        }
      } finally {
        // Emit the per-turn summary (§5.4 / §5.5 / §10 step #5) whether the run
        // succeeded or threw, so the fan-out always flushes (and never leaks)
        // the turn's buffered LLM calls. A crashed turn carries a `null`
        // answer. Best-effort and non-blocking (§9).
        _emitTurnSummary(turnSummarySink, access, startedAt, outcome);
      }
    };
  }

  /// The answering session's earlier turns as ordered `{user, assistant}`
  /// maps, for threading into the routed procedure (access § 7.2 / § 21.5).
  ///
  /// Draws on the bounded raw window (the newest verbatim turns) and **drops
  /// the last entry** — the turn the `SessionManager` just appended for *this*
  /// prompt, which has no answer yet and is the live prompt the procedure
  /// receives separately as `text`. A `null` history (a conformance `Access`)
  /// or a window holding only the current turn yields an empty list, so a cold
  /// first turn carries no history.
  static List<Map<String, Object?>> _priorTurnsFrom(ConversationHistory? history) {
    if (history == null) return const <Map<String, Object?>>[];
    final window = history.rawWindow;
    if (window.length <= 1) return const <Map<String, Object?>>[];
    final earlier = window.sublist(0, window.length - 1);
    return <Map<String, Object?>>[
      for (final HistoryTurn turn in earlier)
        <String, Object?>{
          'user': turn.userPrompt,
          'assistant': turn.brainAnswer,
        },
    ];
  }

  /// Fires the per-turn [TurnSummary] for a completed turn (§5.4 / §5.5 / §10
  /// step #5). A no-op when no sink is bound or the [access] carries no turn id
  /// (a synthetic conformance `Access`, D.53). Guarded so a throwing sink never
  /// surfaces into the turn (§9).
  static void _emitTurnSummary(
    TurnSummarySink? sink,
    Access access,
    DateTime startedAt,
    ProcedureOutcome? outcome,
  ) {
    if (sink == null) return;
    final turnId = access.turnId;
    if (turnId == null) return;
    try {
      sink(TurnSummary(
        turnId: turnId.value,
        sessionId: access.session.sessionId,
        principalId: access.identity.principalId,
        profile: access.session.memoryProfile,
        persona: access.persona.personaId,
        channel: null,
        startedAt: startedAt,
        userPrompt: access.envelope.text,
        finalAnswer: outcome?.result?.output<String>('answer'),
      ));
    } catch (_) {
      // Per-turn narrative is non-essential; never let it break the turn.
    }
  }
}
