// Barrel for the `budget/` module (Q-C.51.1).
//
// Owns procedure-header budget enforcement (PE-8;
// `tom_brain_procedure_specification.md` § 5.4, § 14):
//
//   - `BudgetLedger` — the per-run bookkeeper that enforces the
//     `tokenSpend` / `toolCalls` / `memoryWrites` caps of a procedure's
//     header budget across its bridged calls (wall-clock is the
//     `StepDeadline`'s job, not the ledger's).
//   - `ProcedureBudgetExceeded` + `BudgetDimension` — the typed refusal a
//     bridged call raises, and the dimension it names. The refusal is a plain
//     `Exception` so a procedure can catch and adapt (§ 14); uncaught, the
//     engine records it under `procedure.budget.exceeded` and closes the run
//     `budgetExceeded`, and the fallback executor surfaces it without
//     stepping the version chain.

export 'budget_ledger.dart' show BudgetLedger;
export 'memory_write_guard.dart'
    show
        MemoryWriteGuard,
        MemoryWriteLimits,
        MemoryWriteOutcome,
        MemoryWriteSkip,
        MemoryWriteSkipSink;
export 'procedure_budget_exceeded.dart'
    show BudgetDimension, ProcedureBudgetExceeded;
