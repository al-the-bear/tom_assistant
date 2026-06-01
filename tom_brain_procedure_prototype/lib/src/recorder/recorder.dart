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
// Wiring across later Phase C steps:
//
//   - C.31 — `RunRecorder` + trail/stack integration.
//   - C.32 — effort metrics.
//   - C.33 — stub-memory integration tests (ordered trail entries,
//     `inflight` then `recent_runs`).
//
// At C.8 this folder is intentionally empty. No exports yet.
