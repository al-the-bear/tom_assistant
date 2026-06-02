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
//     instantiates the Phase A isolate-hosted memory by default.
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
// otherwise. Kinds are open strings; `InboundKinds.userPrompt` is the one
// the prototype routes. Exported below.
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
// D.26 ✅ — `inflight` integration, dispatcher half (`run_registry.dart` +
// `run_coordinator.dart`): the coordinator now assigns a run id to every run
// the moment it occupies a slot (an injectable `RunIdMint`, default a
// monotonic per-coordinator counter) and threads it into the controller's
// `recordRunStarted` / `recordRunFinished` calls, so the slot enter/exit
// `PreemptionEvent`s carry a non-null `runId`. When a `RunRegistry` (over the
// memory client) is wired and a submission names the `procedureId` it
// executes, the coordinator pushes a `status: running` `ProcedureRun` marker
// onto the `inflight` bootstrap stack on run start — the dispatcher half of
// PE-4, distinct from the engine-side `RunRecorder` (C.31). Exported below.
//
// D.27 ✅ — `recent_runs` integration, dispatcher half (`run_registry.dart` +
// `run_coordinator.dart`): the run-end half of the PE-4 dispatcher tracking.
// The coordinator now holds the per-slot `inflight` handle D.26 created and,
// when a run ends (success, failure, *or* a hard-step-deadline force-yield),
// calls `RunRegistry.recordEnd` — which removes the running marker from
// `inflight` and pushes a terminal `ProcedureRun` marker
// (`status: completed` / `failed` / `force_yielded`) onto `recent_runs`. The
// run-end write is fired without blocking the completion path, and the held
// handle is cleared the moment the run ends. `RunOutcome` (the terminal-status
// enum) is exported below.
//
// D.28 ✅ — stack-state-reflects-the-runtime tests
// (`test/d28_stack_state_runtime_test.dart`): a tests-only step that locks the
// PE-4 dispatcher-half lifecycle by asserting the live *membership* of the two
// bootstrap stacks (read through `StackApi.peek`), not just the registry's call
// history — `inflight` holds exactly the runs the coordinator currently has
// live, `recent_runs` accumulates exactly the finished ones, and concurrent
// foreground + background appears as two distinct `inflight` entries that each
// migrate to a *distinct* `recent_runs` node (the store is append-only). No
// production change.
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
//     `AutomationIdea` push; D.32 — fallback-event + threshold tests.
//   - D.33–D.35 — free-time scheduler stub.
//   - D.36–D.42 — `answer_with_memory_v1` procedure script.
//   - D.43–D.46 — inter-isolate transport + `BrainProcessBoot`.
//   - D.47–D.50 — `DispatcherConfig` + observability.
//
// See `_ai/quests/tom_brain/tom_brain_procedure_prototype_specification.md`
// for the authoritative contract this module implements.
library;

export 'dispatcher_entry.dart'
    show Dispatcher, DispatchRoute, DispatcherEntryObserver;
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
export 'inbound_classifier.dart'
    show ClassifyFallback, InboundClassifier, InboundKinds, classifyInboundV1;
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
        ForegroundQueueFull,
        RunBody,
        RunCoordinator,
        RunDeadlineExceeded,
        RunIdMint,
        RunSlot,
        RunSlotBusy,
        defaultCoordinatorDeadlineGrace;
export 'run_registry.dart' show RunOutcome, RunRegistration, RunRegistry;
export 'sustained_fallback_monitor.dart'
    show
        SustainedFallbackMonitor,
        automationIdeaNodeType,
        automationIdeasStackName,
        defaultSustainedFallbackThreshold,
        defaultSustainedFallbackWindow;
export 'unsupported_procedure_kind.dart' show UnsupportedProcedureKind;
