// Barrel for the `dispatcher/` module (Plan step D.6).
//
// This is the first dispatcher-half addition to the prototype project,
// which until Phase C held only the engine half. Per
// `tom_brain_definition.md` § 12 ("Prototype companion projects") and
// `tom_brain_procedure_prototype_specification.md` § 16, the dispatcher
// half lands in this *same* `tom_brain_procedure_prototype` project; the
// final two-project `tom_brain_procedure_engine` +
// `tom_brain_procedure_dispatcher` split is deferred to definition § 15
// step 8.
//
// Owns the dispatcher decision policy and the runtime that drives the
// procedure engine on inbound work
// (`tom_brain_procedure_prototype_specification.md` § 10, § 11, § 12;
// Plan steps D.6–D.46):
//
//   - Entry surface (§ 10.1, PE-11): `Dispatcher.accept(Access)` — the
//     single entry point; consumes an `Access` object (envelope /
//     identity / session / persona / `deliver`), never a wire protocol,
//     and delivers only via `Access.deliver`.
//   - Classification + selection (§ 10.2): accepts a pre-filled
//     kind-hint from the access layer; `user_prompt` routes to
//     `answer_with_memory_v1`; anything else surfaces
//     `UnsupportedProcedureKind`.
//   - Foreground / background coordinator (§ 10.3, PE-5): `RunCoordinator`
//     (≤ 1 foreground + ≤ 1 background), FIFO foreground queue,
//     cooperative preemption at the *next* engine checkpoint, hard step
//     deadline, and the supervising `PreemptionController`.
//   - Fallback executor (§ 10.4, PE-6): walks the procedure version
//     chain on the four typed run-failure classes only; emits
//     `ProcedureFallback`; pushes an `AutomationIdea` on sustained
//     fallback.
//   - Free-time scheduler stub (§ 10.5): exercises the background slot so
//     preemption can be proven end-to-end.
//   - `inflight` / `recent_runs` stack integration (PE-4 dispatcher half).
//   - Inter-isolate transport + boot/shutdown orchestration (§ 12):
//     instantiates the Phase A isolate-hosted memory by default. The
//     provisioning seam (`MemoryProvisioner`, D.43) adopts the Phase A
//     `TomBrainMemoryIsolateHost` + `…Client` pair and exposes the
//     isolate (default) / in-process (test flag) `MemoryTransport`
//     choice; `BrainProcessBoot` (D.44+) drives it.
//
// D.14 ✅ — `Dispatcher.accept(Access)` entry surface
// (`dispatcher_entry.dart`): the single entry point, the `DispatchRoute`
// seam it hands an admitted access to (classify→select→schedule, built in
// D.15+), and the `DispatcherEntryObserver` hook the D.48 logger / D.49
// event stream will drive. Exported below.
//
// D.15 ✅ — inbound classifier (`inbound_classifier.dart`): stage two of
// the pipeline. `InboundClassifier.classify(Access)` accepts the Phase-E
// kind-hint verbatim when present and falls back to the prototype's
// `classify_inbound_v1` stub (every un-hinted inbound → `user_prompt`)
// otherwise. Kinds are open strings; `InboundKinds.userPrompt` (in
// `tom_brain_shared` since D.52) is the one the prototype routes.
//
// D.16 ✅ — procedure selection (`procedure_selector.dart` +
// `unsupported_procedure_kind.dart`): stage three of the pipeline.
// `ProcedureSelector.select(kind)` maps the classifier's inbound-kind
// string to a procedure id — `user_prompt` → `answer_with_memory_v1`
// (`SystemProcedures.answerWithMemoryV1`); anything else is rejected loudly
// with `UnsupportedProcedureKind`. The routing table is injectable
// (`defaultProcedureRouting` is the prototype's single entry). Exported
// below.
//
// D.17 ✅ — accept-and-route integration tests
// (`test/d17_accept_and_route_test.dart`): prove the three stages compose
// through the single `Dispatcher.accept` entry point. `user_prompt`
// (explicit hint, un-hinted fallback, or padded/blank hint) routes end to
// end to `answer_with_memory_v1`; any unknown kind raises
// `UnsupportedProcedureKind` unchanged through `accept`, never schedules,
// and delivers nothing back to the channel. Test-only step — no new public
// symbol.
//
// D.18 ✅ — foreground / background run coordinator core
// (`run_coordinator.dart`): the *schedule* stage. `RunCoordinator` tracks at
// most one foreground (`submitForeground`) and one background
// (`submitBackground`) run, and owns the shared `PreemptionState` the engine
// yields against (exposed via `coordinator.preemption`). D.18 exposes the
// preemption state but does not yet drive it (D.20). Exported below.
//
// D.20 ✅ — cooperative preemption driving (`run_coordinator.dart`): the
// coordinator now writes the shared `PreemptionState`. A foreground
// submission admitted while a background run is live calls
// `requestForegroundPreemption()` (the background yields at its next
// `yield_if_foreground_waiting()` checkpoint, never mid-step); once the
// foreground workload fully drains (slot free *and* FIFO queue empty) the
// coordinator calls `signalResume()`. Both writes are idempotent, so
// back-to-back foreground arrivals resume the background exactly once. An
// overflowing submission (`ForegroundQueueFull`) is not admitted and does
// not drive preemption. No new public symbol.
//
// D.21 ✅ — hard step deadline cross-check (`run_coordinator.dart`): the
// coordinator now races every admitted run body (foreground *and*
// background) against its own `StepDeadline`, an independent backstop to the
// engine's per-step deadline (C.36). The coordinator limit defaults to the
// engine's `defaultStepDeadline` plus `defaultCoordinatorDeadlineGrace`, so
// the engine's in-band truncation wins under normal operation; the
// coordinator fires only when the engine failed to bound the run, force-
// yielding the slot (pump queue / resume background) and surfacing
// `RunDeadlineExceeded` (`procedure.deadline.exceeded`). `hardStepDeadline`
// and the timer seam are constructor-injectable. Exported below.
//
// D.23 ✅ — supervising `PreemptionController` (`preemption_controller.dart`
// + `preemption_event.dart`): the observe-only supervisor over the
// coordinator's two run slots. It maintains a small model of slot occupancy
// + whether a foreground preemption is pending and emits a typed
// `PreemptionEvent` (`RunSlotEntered`, `RunSlotExited`,
// `ForegroundPreemptionRequested`, `BackgroundResumeSignalled`) on every
// transition, mirroring `PreemptionState`'s idempotency so the stream
// reflects true transitions rather than redundant coordinator calls. It never
// writes `PreemptionState`. The coordinator wiring (calling the `record*`
// surface at each transition point) lands in D.24. Exported below.
//
// D.24 ✅ — `PreemptionController` wired into the coordinator
// (`run_coordinator.dart`): the coordinator now drives the controller's
// `record*` surface at each transition point — `recordRunStarted` when a body
// starts in a slot, `recordRunFinished` with the mapped `RunSlotOutcome`
// (`completed` / `failed` / `forceYielded`) when it finishes,
// `recordForegroundPreemptionRequested` alongside each
// `requestForegroundPreemption`, and `recordBackgroundResumeSignalled`
// alongside each `signalResume`. The controller is constructor-injectable
// (`RunCoordinator(preemptionController: …)`, default: a fresh one) and its
// event stream is surfaced through `RunCoordinator.preemptionEvents()` so the
// dispatcher API exposes preemption observability without reaching into the
// coordinator. The controller stays observe-only — the coordinator remains the
// single writer of `PreemptionState`. No new public symbol (the controller and
// its events are already exported from D.23).
//
// D.19 ✅ — FIFO foreground queue (`run_coordinator.dart`): a busy
// foreground slot now *enqueues* the submission (configurable
// `foregroundQueueDepth`, default 4) and starts queued runs in submission
// order as the slot frees, instead of failing loudly. Overflow (slot busy
// *and* queue full) raises `ForegroundQueueFull`; `foregroundQueueLength`
// exposes the current waiting count. The background slot stays single — a
// concurrent background submission still raises `RunSlotBusy`. Exported
// below.
//
// D.26 ✅ — run-id assignment + dispatcher-half run tracking
// (`run_registry.dart` + `run_coordinator.dart`): the coordinator assigns a
// run id to every run the moment it occupies a slot (an injectable
// `RunIdMint`, default a monotonic per-coordinator counter) and threads it
// into the controller's `recordRunStarted` / `recordRunFinished` calls, so the
// slot enter/exit `PreemptionEvent`s carry a non-null `runId`. When a
// `RunRegistry` is wired and a submission names the `procedureId` it executes,
// the coordinator records the run as occupying its slot in the registry on run
// start — the dispatcher half of PE-4.
//
// Per Q-D.26.1 the registry is an **in-memory slot-occupancy view**, not a
// second `ProcedureRun` writer: the engine-side `RunRecorder` (C.31) is the
// canonical and sole writer of `ProcedureRun` nodes to `inflight` /
// `recent_runs`. The registry only projects which coordinator slot
// (foreground / background) currently holds which run — operator-visibility
// state the recorder does not capture. Exported below.
//
// D.27 ✅ — run-end half of the dispatcher tracking (`run_registry.dart` +
// `run_coordinator.dart`): when a run ends (success, failure, *or* a
// hard-step-deadline force-yield) the coordinator calls
// `RunRegistry.recordEnd(slot)`, which clears that slot from the occupancy
// view. The clear is synchronous in-memory work — no memory write, no held
// future. `RunOutcome` (the terminal-outcome enum carried on the
// `RunCompleted` event) lives in `dispatcher_event.dart` and is exported below.
//
// D.28 ✅ — slot-occupancy-reflects-the-runtime tests
// (`test/d28_stack_state_runtime_test.dart`): a tests-only step that locks the
// PE-4 dispatcher-half lifecycle by asserting the registry's live occupancy —
// it holds exactly the runs the coordinator currently has live, and concurrent
// foreground + background appear as two distinct occupied slots, each cleared
// as its run ends. No production change.
//
// D.29 ✅ — fallback executor, version-chain walk (`fallback_executor.dart`):
// the first FallbackExecutor (PE-6) addition. `FallbackExecutor.run` resolves
// a procedure's fallback chain `[v_latest, …, v1]` (C.25
// `ProcedureResolver.fallbackChain`) and attempts each version via a
// caller-supplied `VersionAttempt`. On the four typed run-failure classes
// (`FallbackTrigger`: contract violation, critique rejected, deadline
// exceeded, runtime crash) it steps down to the next-older version; an
// `EnvironmentalFailure` or any non-fallback failure surfaces without
// stepping. Failures classify through `FailureClassifier`
// (`defaultFallbackClassifier`); `RunDeadlineExceeded` now implements the
// `ClassifiedFailure` marker so the deadline path classifies without
// string-matching. Each version attempt is recorded in the returned
// `FallbackOutcome` so D.31 (sustained-fallback `AutomationIdea` push) builds
// on top without re-walking the chain. Exported below.
//
// D.30 ✅ — `ProcedureFallback` event emission (`procedure_fallback_event.dart`
// + `fallback_executor.dart`): the executor now takes an optional
// `FallbackEventSink` (+ injectable `FallbackClock`) and emits one
// `ProcedureFallback` on **every** fallback-class failure (def § 6: "Every
// fallback emits a `ProcedureFallback` event"). A step-down carries the
// next-older `toVersion` (`surfaced: false`); a fallback-class failure on the
// oldest version surfaces with `toVersion: null` (`surfaced: true`).
// Non-fallback failures (environmental / outside the four classes) and
// successes emit nothing. In the prototype the singleton `[v1]` chain always
// surfaces, but the event still fires — the observability surface is exercised
// exactly as it will be once multiple versions exist. `run` threads optional
// `runId` / `causedBy` onto the events. Exported below.
//
// D.31 ✅ — sustained-fallback `AutomationIdea` push
// (`sustained_fallback_monitor.dart`): the aggregate signal on top of the
// per-edge `ProcedureFallback` events. `SustainedFallbackMonitor` keeps a
// sliding 24 h window of fallback edges per procedure id (default threshold 3,
// both injectable) and, the moment a window first crosses the sustained
// threshold, pushes exactly one `AutomationIdea: revise procedure X` onto the
// `automation_ideas` bootstrap stack (def § 6). The push fires once per
// sustained episode — the 4th, 5th, … edge in the same burst do not re-push;
// the episode re-arms only once activity subsides below the threshold. Wire it
// to the executor via `monitor.asSink` (fire-and-forget) or call `record`
// directly. Exported below.
//
// D.33 ✅ — free-time scheduler stub (`free_time_scheduler.dart`): the
// `FreeTimeScheduler` kernel that, on each `tick`, picks at most one entry
// from the highest-priority *hot* stack (§ 5.3: size above
// `hotSizeThreshold` OR top priority at/above `hotPriorityThreshold`, among
// the § 5.1 work stacks `defaultSchedulableStacks`) and submits it as a
// background run via the same `RunCoordinator` the inbound path drives — but
// only when no foreground work is pending and the background slot is free. The
// § 5.3 routing ("research / triage / author / dream_*") is the injected
// `BackgroundWorkFactory` seam; per Plan D.34 the prototype stub is
// intentionally weak (no round-robin dreaming yet), so an idle cycle does
// nothing. A `tick` returns a typed `FreeTimeSchedulerTick`
// (`foregroundPending` / `backgroundBusy` / `idle` / `scheduled`). Exported
// below.
//
// Intentionally empty at D.6: this step adds the folder + barrel only,
// matching the C.8 per-folder convention used across the Tom Brain
// projects (`tom_brain_shared`, `tom_brain_memory`,
// `tom_brain_substrate`, and the engine half of this project). Public
// symbols land incrementally across the remaining Phase D steps:
//
//   - D.6  ✅ — `dispatcher/` sub-folder + barrel (this file).
//   - D.7  ✅ — `scripts/system/` + `scripts/user/` tree.
//   - D.8  — `answer_with_memory_v1.dart` stub.
//   - D.11–D.13 — the `Access` class (declared in `tom_brain_shared`)
//     and its consumption boundary here.
//   - D.14–D.17 — `Dispatcher.accept` entry surface + classification +
//     selection.
//   - D.18–D.25 — `RunCoordinator` + `PreemptionController`.
//   - D.26 ✅ — `inflight` integration (dispatcher half); D.27 ✅ —
//     `recent_runs` integration (dispatcher half); D.28 ✅ — stack-state tests.
//   - D.29 ✅ — `FallbackExecutor` version-chain walk; D.30 ✅ —
//     `ProcedureFallback` events; D.31 ✅ — sustained-fallback
//     `AutomationIdea` push; D.32 ✅ — end-to-end fallback-event +
//     idea-push-at-threshold tests (`d32_fallback_end_to_end_test.dart`).
//   - D.33 ✅ — free-time scheduler stub (`free_time_scheduler.dart`);
//     D.34 ✅ — the stub is intentionally weak (round-robin dreaming
//     deferred — no dream scripts yet) yet still exercises the background
//     slot; the two contract claims (no dream synthesis on idle; end-to-end
//     cooperative preemption against the real coordinator) are proven in
//     `d34_free_time_scheduler_weak_test.dart`. D.35 ✅ — the focused
//     invokes-background + preempts-under-load proof suite
//     (`d35_free_time_scheduler_preemption_test.dart`): a hot stack runs a
//     real background body; under foreground load the scheduler declines new
//     background work and a parked background resumes cleanly only after the
//     whole foreground chain drains.
//   - D.36 ✅ — `answer_with_memory_v1` structured header promoted from the
//     D.8 stub language to the real recall→answer→persist contract (§ 4.4),
//     proven in `d36_answer_with_memory_header_test.dart`. The
//     machine-validated header fields (inputs/outputs/`requires`/signature)
//     track the body and flip with the substep that introduces each
//     behaviour.
//   - D.37 ✅ — body step 1 (recall): `mem.recall(text, {bm25, vector}, k:8)`,
//     proven in `d37_answer_with_memory_recall_test.dart`. `text`→required,
//     `requires`→[recall].
//   - D.38 ✅ — body step 2 (answer): assembles a prompt from the recalled
//     memory + the inbound prompt and runs `sub.llm(prompt,
//     role: 'assistant_to_user')`, surfacing the answer as the `answer`
//     output (`d38_answer_with_memory_answer_test.dart`). `outputs`→`answer`,
//     `requires`→[recall, llm]. Token streaming via `Access.deliver` is a
//     Phase E concern (Q-D.38.1); `sub.llm` returns the whole answer.
//   - D.39 ✅ — body step 3 (persist the exchange): persists the inbound
//     prompt as an `Event` and the answer as a `Conclusion`, draws a
//     `derived_from` edge from the `Conclusion` to each recalled node, and
//     reports the `Conclusion` id under the reserved `producedNodeIds` key so
//     the recorder draws the `produced_by` edge to the run
//     (`d39_answer_with_memory_persist_test.dart`). `requires`→[recall, llm,
//     persist, edge].
//   - D.40 ✅ — body step 4 (cold-classification interest push): when recall
//     comes back empty (the proxy for "prompt embedding far from any
//     centroid"), persists an `InterestItem` and pushes it onto the
//     `interests` bootstrap stack
//     (`d40_answer_with_memory_interest_test.dart`). `requires`→[recall, llm,
//     persist, edge, stack.push]. Detection reads the recall already in hand;
//     `embed`/`classify` are not called (Q-D.40.1).
//   - D.41 ✅ — body step 5 (automation-candidate note): when the step-1
//     recall surfaced a prior `Event` whose `summary` equals this prompt (an
//     identical-shape repetition), emits `note('automation_candidate', …)` on
//     the run trail — the wire the dispatcher harvester (D.31) keys on
//     (`d41_answer_with_memory_automation_test.dart`). `requires`→[recall,
//     llm, persist, edge, stack.push, note]. The check reads the recall
//     already in hand; no second memory query (Q-D.41.1).
//   - D.42 ✅ — `answer_with_memory_v1` consolidated body proof: one synthetic
//     inbound prompt is driven through the engine against the shipped disk
//     procedure and a single run is asserted to satisfy the whole
//     post-condition bundle (streamed answer + `Event` + `Conclusion` +
//     `derived_from`/`produced_by` edges, plus the cold-path `interests` push
//     when applicable), proving the D.37–D.41 steps compose
//     (`d42_answer_with_memory_consolidated_test.dart`). No body change.
//   - D.43 ✅ — inter-isolate transport seam (`memory_provisioning.dart`):
//     adopts Phase A's `TomBrainMemoryIsolateHost` + `TomBrainMemoryIsolateClient`
//     pair. `MemoryProvisioner.provision()` instantiates one isolate-hosted
//     memory by default (spawn → openMemory → wrap in the isolate client) and
//     an in-process client when the `MemoryTransport` config flag selects it
//     (tests inject a fake `TomBrainMemoryClient`). Both transports return a
//     uniform `ProvisionedMemory` (opened client + idempotent `dispose`), so
//     everything downstream is transport-indifferent (the D.53 parity claim).
//     Exported below. The `BrainProcessBoot` orchestration (D.44), shutdown
//     drain (D.45), and crash→typed-startup-error (D.46) build on this seam.
//   - D.44 ✅ — startup orchestration (`brain_process_boot.dart`):
//     `BrainProcessBoot.boot(BrainProcessConfig)` brings the process up in the
//     § 12 order — open the in-process substrate, provision memory (isolate by
//     default, via the D.43 seam), build the `ProcedureEngine` over both
//     bridges + the disk procedure store sharing one `PreemptionState` with the
//     `RunCoordinator`, wrap it in the classify→select→schedule route behind a
//     single `Dispatcher`, and install the future access layer through an
//     installer seam (none in the prototype). Returns a `BootedBrain` exposing
//     the assembled parts and an idempotent `shutdown()` that tears the
//     brought-up resources down (access layer → memory → substrate). A boot
//     failure tears already-brought-up resources back down so a failed boot
//     leaks nothing. Exported below. The full shutdown *drain* (finish current
//     foreground best-effort, drain queues, close trails) is D.45; the
//     crash→typed-startup-error guarantee is D.46.
//   - D.45 ✅ — shutdown drain orchestration (`run_coordinator.dart` +
//     `brain_process_boot.dart`): `RunCoordinator.drain({timeout})` flips
//     `isDraining` on (refusing new `submitForeground` / `submitBackground`
//     with `CoordinatorDraining`) and best-effort waits for the coordinator to
//     fall fully `isIdle` — foreground slot free, FIFO queue drained,
//     background slot free — so each in-flight run's `RunRecorder` closes its
//     trail before memory is flushed. `BootedBrain.shutdown({drainTimeout})`
//     now reverse-orders (access layer → drain → memory dispose → substrate
//     close); `drainTimeout` defaults to `defaultShutdownDrainTimeout` (derived
//     from the coordinator hard step deadline plus a margin, ~90 s, so it
//     strictly outlasts the coordinator force-yield), so a genuinely-hung body
//     cannot hold shutdown hostage. Exported below.
//   - D.46 ✅ — typed startup error + crash tests (`brain_process_boot.dart` +
//     `memory_provisioning.dart`): `BrainProcessBoot.boot` now wraps every
//     bring-up failure in a `BrainStartupError` tagging the `BootPhase`
//     (`substrate` / `memory` / `engine` / `accessLayer`) it failed in and
//     preserving the original `cause` — so a memory-isolate spawn/open crash
//     surfaces as `BrainStartupError(phase: BootPhase.memory, …)` rather than a
//     bare transport exception. `MemoryProvisioner` now tears the spawned host
//     down on a failed `openMemory` so a crashing factory leaks no worker
//     isolate. `d46_boot_lifecycle_test.dart` proves the boot→submit→shutdown
//     sequence completes, a mid-flight foreground run finishes before memory
//     closes, and an isolate-factory crash surfaces as the typed error.
//     `BrainStartupError` + `BootPhase` exported below.
//   - D.47 ✅ — `DispatcherConfig` YAML loader. Lives in the `config/` module
//     (`config/dispatcher_config.dart`) alongside `EngineConfig`, exported from
//     the top-level barrel via `config/config.dart`; carries the foreground
//     queue depth, the coordinator hard step deadline, the scheduler
//     enabled/disabled flag, and the scripts paths.
//   - D.48 ✅ — `TomLogger` dispatcher categories. Lives in the `config/`
//     module (`config/dispatcher_log.dart`) alongside `EngineLog`, exported
//     from the top-level barrel via `config/config.dart`; the
//     `DispatcherLogCategory` enum + `DispatcherLog` const-instance facade for
//     `tom_brain.dispatcher.entry`, `…coordinator`, `…fallback`,
//     `…scheduler`, `…boot`.
//   - D.49 ✅ — `DispatcherEvent` sealed sum (`dispatcher_event.dart`) +
//     `DispatcherEventBus` (`dispatcher_event_bus.dart`): the seven typed
//     observability variants spec § 13 names — `AccessAccepted`,
//     `ProcedureSelected`, `ForegroundQueued`, `Preempted`, `Resumed`,
//     `RunCompleted`, `FallbackTried` — each extending `BrainEvent`, plus the
//     broadcast fan-in bus the composition root wires to the entry surface,
//     the coordinator, and the fallback executor. Mirrors `EngineEvent` /
//     `EngineEventBus` (C.44). Unlike `EngineEvent`, `runId` stays nullable
//     (access-scoped variants fire before a run id is minted); only
//     `RunCompleted` narrows it to required. `FallbackTried` is the
//     dispatcher-stream representation of the executor's `ProcedureFallback`
//     (D.30) — build one with `FallbackTried.fromProcedureFallback`. Lives in
//     this `dispatcher/` folder (beside `PreemptionEvent` / `ProcedureFallback`),
//     not `config/`, so it reuses the runtime types without a `config/ →
//     dispatcher/` edge. Exported below.
//   - D.50 ✅ — observability conformance (`test/d50_dispatcher_conformance_test.dart`,
//     tests-only): closes the config-roundtrip half at the config↔runtime
//     boundary (a round-tripped `DispatcherConfig` drives a `RunCoordinator`
//     with identical operative knobs) and the event-ordering half through the
//     live coordinator (a background→foreground preemption interleave and a
//     queued-foreground chain produce the `DispatcherEvent` stream in the exact
//     order the interleave dictates). A test-local composition-root projector
//     stands in until the boot-wiring step threads `DispatcherEventBus.emit`
//     into the entry surface / coordinator / fallback executor.
//   - D.51 ✅ — Phase-D code review pass D1 (review-only; no `lib/` change).
//     Every Phase-D file checked against its owning spec section (§ 10–14);
//     the divergence report is recorded in
//     `prototype_implementation_details.md` § D.51. Zero critical, one
//     material (the `answer_with_memory_v1` `Access.deliver` streaming gap,
//     Q-D.51.1), three cosmetic (all already tracked). The sentinel
//     `test/d51_spec_section_attestation_test.dart` pins the closed sets —
//     the seven-variant `DispatcherEvent` sum, the five `DispatcherLog`
//     categories, the four `FallbackTrigger` wire strings, the sustained
//     threshold/window, the `user_prompt` routing, the queue-depth default,
//     and the five-field `Access` shape — so any drift fails loudly.
//
//   - D.52 ✅ — reuse-extraction pass. `InboundKinds` (the inbound-kind
//     vocabulary) promoted to `tom_brain_shared` (`access/inbound_kinds.dart`)
//     beside the `InboundRequest.kindHint` field it names: Phase E produces
//     the hint, Phase D consumes it, so the spelling belongs to the shared
//     layer. The dispatcher classifier / selector now import it from shared;
//     `SystemProcedures` (the procedure-id holder) stays here — Phase E never
//     selects a procedure. `RunSlot` / `RunOutcome` stay coordinator-internal
//     (observed transitively via `DispatcherEvent`, not produced by the edge).
//     Pinned by `test/d52_reuse_extraction_test.dart`. See § D.52 in
//     `prototype_implementation_details.md`.
//
// See `_ai/quests/tom_brain/tom_brain_procedure_prototype_specification.md`
// for the authoritative contract this module implements.
library;

export 'brain_process_boot.dart'
    show
        AccessLayerInstaller,
        AccessLayerShutdown,
        BootPhase,
        BootedBrain,
        BrainProcessBoot,
        BrainProcessConfig,
        BrainStartupError,
        defaultShutdownDrainTimeout,
        inboundTextArgumentKey;
export 'dispatcher_entry.dart'
    show Dispatcher, DispatchRoute, DispatcherEntryObserver;
export 'dispatcher_event.dart'
    show
        AccessAccepted,
        DispatcherEvent,
        FallbackTried,
        ForegroundQueued,
        Preempted,
        ProcedureSelected,
        Resumed,
        RunCompleted,
        RunOutcome;
export 'dispatcher_event_bus.dart' show DispatcherEventBus;
export 'fallback_executor.dart'
    show
        ClassifiedFailure,
        EnvironmentalFailure,
        FailureClassifier,
        FallbackAttempt,
        FallbackClock,
        FallbackEventSink,
        FallbackExecutor,
        FallbackOutcome,
        FallbackTrigger,
        VersionAttempt,
        defaultFallbackClassifier;
export 'free_time_scheduler.dart'
    show
        BackgroundWorkFactory,
        FreeTimeDecision,
        FreeTimeScheduler,
        FreeTimeSchedulerTick,
        ScheduledBackgroundWork,
        ScheduledPick,
        defaultHotPriorityThreshold,
        defaultHotSizeThreshold,
        defaultSchedulableStacks;
// `InboundKinds` moved to `tom_brain_shared` at the D.52 reuse-extraction
// pass (Phase E produces the hint, Phase D consumes it); consumers import
// it from `package:tom_brain_shared/tom_brain_shared.dart`.
export 'inbound_classifier.dart'
    show ClassifyFallback, InboundClassifier, classifyInboundV1;
export 'memory_provisioning.dart'
    show
        MemoryProvisioner,
        MemoryProvisioningConfig,
        MemoryTransport,
        ProvisionedMemory;
export 'preemption_controller.dart'
    show PreemptionClock, PreemptionController;
export 'preemption_event.dart'
    show
        BackgroundResumeSignalled,
        ForegroundPreemptionRequested,
        PreemptionEvent,
        RunSlotEntered,
        RunSlotExited,
        RunSlotOutcome;
export 'procedure_fallback_event.dart' show ProcedureFallback;
export 'procedure_selector.dart'
    show ProcedureSelector, SystemProcedures, defaultProcedureRouting;
export 'run_coordinator.dart'
    show
        BackgroundReservation,
        CoordinatorDraining,
        ForegroundQueueFull,
        RunBody,
        RunCoordinator,
        RunDeadlineExceeded,
        RunIdMint,
        RunSlot,
        RunSlotBusy,
        defaultCoordinatorDeadlineGrace,
        defaultCoordinatorHardStepDeadline;
export 'run_registry.dart' show RunRegistration, RunRegistry;
export 'sustained_fallback_monitor.dart'
    show
        SustainedFallbackMonitor,
        automationIdeaNodeType,
        automationIdeasStackName,
        defaultSustainedFallbackThreshold,
        defaultSustainedFallbackWindow;
export 'unsupported_procedure_kind.dart' show UnsupportedProcedureKind;
