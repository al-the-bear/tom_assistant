// BudgetLedger — the per-run bookkeeper that enforces the token / tool-call
// / memory-write dimensions of a procedure-header budget (PE-8;
// `tom_brain_procedure_specification.md` § 4.4, § 5.4).
//
// ── What it owns ────────────────────────────────────────────────────
//
// The header `budget` block declares up to four caps: `wallClockMs`,
// `tokenSpend`, `toolCalls`, `memoryWrites`. Wall-clock is enforced by the
// `StepDeadline` (it closes a run `preempted`), so the ledger owns exactly
// the other three. Each bridged call passes through the ledger twice:
//
//   - `check(primitive)` runs *before* the side effect. For a count
//     dimension (`toolCalls`, `memoryWrites`) the call's unit is known from
//     its name, so a call that would push the running tally past its cap is
//     refused before it runs — the side effect never happens. For
//     `tokenSpend` the cost of an `llm` call is unknowable before it runs,
//     so the honest gate is "refuse the next `llm` once spend is already at
//     or over the cap": the call that overshoots completes, and the *next*
//     one is refused.
//   - `charge(primitive, result:)` runs *after* the call settled, folding
//     the measured `EffortMetrics` delta into the running tally.
//
// ── Why reuse EffortAccountant ──────────────────────────────────────
//
// The same classifier the run recorder folds into the effort tally decides
// which counter a call contributes to here. Sharing it means the budget the
// ledger enforces and the effort the run reports can never drift apart —
// there is one rule, not two. The ledger is the *gate*; the recorder is the
// *record*; both read the same accountant.

import '../procedure_store/procedure_header.dart' show ProcedureBudget;
import '../recorder/effort_accountant.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;

import 'procedure_budget_exceeded.dart';

/// Enforces the non-wall-clock caps of one procedure's [ProcedureBudget]
/// across the bridged calls of a single run.
///
/// Stateful and run-scoped: the engine builds one per run over that run's
/// resolved header budget and threads it into the run's bridges. Not shared
/// across runs (two concurrent runs each carry their own ledger), the same
/// per-run-binding discipline as the recorder hook.
final class BudgetLedger {
  /// The header budget whose caps this ledger enforces.
  final ProcedureBudget budget;

  final EffortAccountant _accountant;

  EffortMetrics _consumed = EffortMetrics.zero;

  /// Builds a ledger over [budget]. [accountant] is injectable for testing;
  /// it defaults to the same stateless classifier the recorder uses.
  BudgetLedger(
    this.budget, {
    EffortAccountant accountant = const EffortAccountant(),
  }) : _accountant = accountant;

  /// The effort consumed so far — the running tally [charge] accumulates.
  EffortMetrics get consumed => _consumed;

  /// Whether this budget declares any cap the ledger enforces.
  ///
  /// A budget that sets only `wallClockMs` (enforced by the deadline, not the
  /// ledger) enforces nothing here, so [check] is a guaranteed no-op and the
  /// engine can skip threading the ledger into the bridges.
  bool get enforces =>
      budget.tokenSpend != null ||
      budget.toolCalls != null ||
      budget.memoryWrites != null;

  /// Refuses [primitive] if running it would exceed an applicable cap.
  ///
  /// Called before the bridged side effect. Throws [ProcedureBudgetExceeded]
  /// naming the dimension hit; returns normally when the call fits (or when
  /// no cap applies to it). The smallest applicable budget wins — but the
  /// prototype enforces only the procedure-level budget, so there is exactly
  /// one cap per dimension to check (per-call and subsystem budgets are out
  /// of prototype scope, § 5.4).
  void check(String primitive) {
    final unit = _accountant.classify(primitive);

    final writeCap = budget.memoryWrites;
    if (writeCap != null &&
        unit.memoryWrites > 0 &&
        _consumed.memoryWrites + unit.memoryWrites > writeCap) {
      throw ProcedureBudgetExceeded(
        dimension: BudgetDimension.memoryWrites,
        limit: writeCap,
        consumed: _consumed.memoryWrites,
        primitive: primitive,
      );
    }

    final toolCap = budget.toolCalls;
    if (toolCap != null &&
        unit.toolCalls > 0 &&
        _consumed.toolCalls + unit.toolCalls > toolCap) {
      throw ProcedureBudgetExceeded(
        dimension: BudgetDimension.toolCalls,
        limit: toolCap,
        consumed: _consumed.toolCalls,
        primitive: primitive,
      );
    }

    // Token spend is the one dimension that cannot be pre-empted on the
    // overshooting call: an `llm` call's token cost is unknown until it runs.
    // The gate refuses the *next* `llm` once spend is already at or over the
    // cap — honest about the fact that the call which crosses the line still
    // completes.
    final tokenCap = budget.tokenSpend;
    if (tokenCap != null &&
        unit.llmCalls > 0 &&
        _consumed.estimatedTokens >= tokenCap) {
      throw ProcedureBudgetExceeded(
        dimension: BudgetDimension.tokenSpend,
        limit: tokenCap,
        consumed: _consumed.estimatedTokens,
        primitive: primitive,
      );
    }
  }

  /// Folds the [primitive] call's effort delta into the running tally.
  ///
  /// Called after the call settled. [result] is the call's return map — only
  /// `llm` reads it (for token counts off the embedded `report`); every other
  /// primitive's delta is a fixed unit determined by name alone.
  void charge(
    String primitive, {
    Map<String, Object?> result = const <String, Object?>{},
  }) {
    _consumed = _consumed.plus(_accountant.classify(primitive, result: result));
  }
}
