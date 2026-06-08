// Barrel for the `recorder/` module (Plan step C.8).
//
// Owns run recording and effort accounting
// (`tom_brain_procedure_prototype_specification.md` § 8, Plan steps
// C.31–C.33; `memory_specification.md` and definition § 7.4):
//
//   - `RunRecorder` — opens a memory trail at procedure start, appends
//     every primitive call, persists a `ProcedureRun` node at end, and
//     pushes it to the `recent_runs` + `inflight` stacks via the
//     memory client.
//   - Effort accounting: `wallClockMs`, `llmCalls`, `inputTokens`,
//     `outputTokens`, `toolCalls`, `memoryReads`, `memoryWrites`.
//
// `EffortMetrics` — the closed effort-metric shape the recorder produces
// and the Phase D dispatcher's harvester reads off `recent_runs` — was
// extracted to `tom_brain_shared` at the Phase C review (C.48). Consumers
// import it from `package:tom_brain_shared/tom_brain_shared.dart`; this
// module no longer re-exports it. The `EffortAccountant` that classifies
// a primitive call into an `EffortMetrics` delta stays here.
//
// Wiring across later Phase C steps:
//
//   - C.31 ✅ — `RunRecorder` + trail/stack integration: opens a memory
//     trail at start, appends every primitive call + note, persists the
//     final `ProcedureRun` node, draws its `derived_from` / `produced_by`
//     edges, and moves it across the `inflight` → `recent_runs` stacks.
//     `EffortMetrics` carries the closed metric shape (§ 8); per-call
//     accumulation lands in C.32.
//   - C.32 ✅ — effort-metric accumulation: `EffortAccountant` maps each
//     bridged primitive call to its metric delta, and `RunRecorder`
//     folds the deltas (via `EffortMetrics.plus`) into the run's
//     `accumulatedEffort`, persisted on the final `ProcedureRun`.
//   - C.33 — stub-memory integration tests (ordered trail entries,
//     `inflight` then `recent_runs`).

export 'effort_accountant.dart' show EffortAccountant;
// §10 step #4 — the engine-layer raw-LLM-trail record (bridge observation +
// run-correlation) and its sink type.
export 'llm_trail_record.dart' show LlmTrailRecord, LlmTrailSink;
export 'run_records.dart'
    show
        ProcedureRunRecord,
        RunCompletion,
        RunStart,
        inflightStackName,
        procedureRunNodeType,
        producedNodeIdsOutputKey,
        recentRunsStackName,
        runStatusRunning;
export 'run_recorder.dart' show RunRecorder;
