// Barrel for the `effort/` module (Plan step C.48 reuse extraction).
//
// Module surface:
//
//   * `EffortMetrics` — the closed seven-field effort record
//     (`wallClockMs`, `llmCalls`, `inputTokens`, `outputTokens`,
//     `toolCalls`, `memoryReads`, `memoryWrites`) stamped onto every
//     `ProcedureRun`, plus the derived `estimatedTokens`. Immutable; the
//     `plus` / `withWallClockMs` combinators fold per-call deltas into a
//     run total. Pure value type — no I/O.
//
// Origin: extracted from `tom_brain_procedure_prototype` (Plan step C.31)
// at the Phase C review (C.48). The run recorder produces this shape and
// the Phase D dispatcher's harvester reads the same shape off the
// `recent_runs` stack — a real two-component vocabulary, the criterion
// for promotion to `tom_brain_shared`.

export 'effort_metrics.dart' show EffortMetrics;
