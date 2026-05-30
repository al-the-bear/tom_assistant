// Barrel for the memory-internal `budget/` module (Plan step A.68).
//
// `WriteBudget` itself lives in `tom_brain_shared` (the value type is
// cross-component vocabulary). This module owns the *enforcement*
// surface that memory adds around it:
//
//   - `WriteBudgetTracker` — per-run remaining-counter bookkeeping.
//     Held by the higher-level `SqliteTomBrainMemory`; consulted by
//     `NodePersister`, `EdgeWriter`, and `SqliteStackApi`.
//   - `WriteBudgetExceeded` / `WriteBudgetDimension` — the typed
//     refusal that the three write paths raise when a run is
//     out of capacity.
//
// The shared `WriteBudget` is re-exported here so consumers can
// import a single barrel for "everything to do with memory write
// budgets" without remembering which package the value type lives
// in.

export 'package:tom_brain_shared/tom_brain_shared.dart' show WriteBudget;

export 'write_budget_exceeded.dart'
    show WriteBudgetDimension, WriteBudgetExceeded;
export 'write_budget_tracker.dart' show WriteBudgetTracker;
