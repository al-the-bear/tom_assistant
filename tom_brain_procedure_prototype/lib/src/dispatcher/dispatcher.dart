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
// yields against (exposed via `coordinator.preemption`). Until D.19's FIFO
// queue lands, a second concurrent submission into a busy slot is rejected
// loudly with `RunSlotBusy`. D.18 exposes the preemption state but does not
// yet drive it (D.20). Exported below.
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
//   - D.26–D.28 — `inflight` / `recent_runs` integration.
//   - D.29–D.32 — `FallbackExecutor`.
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
export 'inbound_classifier.dart'
    show ClassifyFallback, InboundClassifier, InboundKinds, classifyInboundV1;
export 'procedure_selector.dart'
    show ProcedureSelector, SystemProcedures, defaultProcedureRouting;
export 'run_coordinator.dart'
    show RunBody, RunCoordinator, RunSlot, RunSlotBusy;
export 'unsupported_procedure_kind.dart' show UnsupportedProcedureKind;
