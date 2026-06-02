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
// Intentionally empty at D.6: this step adds the folder + barrel only,
// matching the C.8 per-folder convention used across the Tom Brain
// projects (`tom_brain_shared`, `tom_brain_memory`,
// `tom_brain_substrate`, and the engine half of this project). Public
// symbols land incrementally across the remaining Phase D steps:
//
//   - D.6  ✅ — `dispatcher/` sub-folder + barrel (this file).
//   - D.7  — `scripts/system/` + `scripts/user/` tree.
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
