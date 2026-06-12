// BudgetView — the d4rt-bridged read-only window onto a run's per-prompt
// budget (`tom_brain_procedure_specification.md` § 5.4.2).
//
// ── Why a read-only view at all ─────────────────────────────────────
//
// The [BudgetLedger] (§ 5.4) and the `StepDeadline` (§ 9) *enforce* the
// budget; a procedure that wants to *adapt* to it — drop a sub-think,
// narrow a retrieval fan-out, stop a tool loop early when little budget is
// left — needs to *read* it. This bridge is that window. It is bound per
// run as the `budget` global (`D4rtDcliHost.budgetGlobal`), exactly the
// `mem` / `sub` / `tool` named-global convention, and exposes, for each of
// the three dimensions a script reasons about, both the header **limit** and
// the live **remaining**:
//
//   budget.tokenBudget / budget.remainingTokenBudget
//   budget.timeBudget  / budget.remainingTimeBudget   (milliseconds)
//   budget.toolCallBudget / budget.remainingToolCallBudget
//
// ── It is a view, never a second tally ──────────────────────────────
//
// Token and tool-call remaining are computed from the *same*
// [BudgetLedger.consumed] the fatal gate reads, so the number a script sees
// and the number that trips `procedure.budget.exceeded` can never diverge
// (the same reason the ledger reuses the recorder's `EffortAccountant`,
// § 5.4). Token remaining therefore reflects the **paid-only** spend the
// ledger debits — a free-provider call does not shrink it. Time remaining is
// wall-clock from run start: [_elapsed] is the engine's elapsed clock, armed
// at run start, so `remainingTimeBudget` shrinks in real time. This is the
// *procedure-header* `wallClockMs`, distinct from the per-step deadline.
//
// ── `null` means uncapped, not zero ─────────────────────────────────
//
// A dimension the header leaves unset reports `null` for both limit and
// remaining, so a script distinguishes "no budget set" (`== null`) from
// "budget exhausted" (`== 0`). Remaining is clamped at `0`: the token gate
// lets the overshooting call complete (§ 5.4), so consumed can exceed the
// cap, but "how much is left" is never negative.
//
// ── Why the data sources are private ────────────────────────────────
//
// The generator emits a script-facing getter for every PUBLIC field/getter;
// the ledger and elapsed clock are host internals a procedure must never
// reach, so they are private (`_ledger` / `_elapsed`) and the generated
// bridge exposes only the six budget getters. The bridge is constructed
// natively by the engine; a script never calls the constructor. `memoryWrites`
// is deliberately not exposed — it is a process backstop (§ 5.4.1), not a
// number a procedure is meant to steer by.

import 'budget_ledger.dart';

/// The read-only, d4rt-bridged window onto a run's per-prompt budget.
///
/// Built per run by the engine over that run's [BudgetLedger] and an
/// [elapsed] clock; injected as the `budget` global. Stateless beyond its
/// two sources — every getter reads them live, so the same instance reports
/// shrinking `remaining*` values as the run consumes budget.
final class BudgetView {
  /// Wraps the run's [ledger] (the limits + consumed source) and an
  /// [elapsed] closure that reports wall-clock time since run start (for the
  /// time dimension the ledger does not track). The engine constructs this
  /// natively and the host injects the instance as the `budget` global; a
  /// procedure script never calls this constructor.
  BudgetView({
    required BudgetLedger ledger,
    required Duration Function() elapsed,
  })  : _ledger = ledger,
        _elapsed = elapsed;

  final BudgetLedger _ledger;
  final Duration Function() _elapsed;

  /// The header `tokenSpend` cap (paid-token ceiling), or `null` when the
  /// header leaves the token dimension uncapped.
  int? get tokenBudget => _ledger.budget.tokenSpend;

  /// `tokenBudget − consumedTokens`, clamped at `0`; `null` when
  /// [tokenBudget] is `null`.
  int? get remainingTokenBudget =>
      _remaining(tokenBudget, _ledger.consumed.estimatedTokens);

  /// The header `wallClockMs` cap in **milliseconds**, or `null` when the
  /// header leaves the wall-clock dimension uncapped.
  int? get timeBudget => _ledger.budget.wallClockMs;

  /// `timeBudget − elapsedMs`, clamped at `0`; `null` when [timeBudget] is
  /// `null`. Shrinks in real time as the run's wall clock advances.
  int? get remainingTimeBudget =>
      _remaining(timeBudget, _elapsed().inMilliseconds);

  /// The header `toolCalls` cap, or `null` when the header leaves the
  /// tool-call dimension uncapped.
  int? get toolCallBudget => _ledger.budget.toolCalls;

  /// `toolCallBudget − consumedToolCalls`, clamped at `0`; `null` when
  /// [toolCallBudget] is `null`.
  int? get remainingToolCallBudget =>
      _remaining(toolCallBudget, _ledger.consumed.toolCalls);

  /// `limit − consumed`, never below `0`; `null` when [limit] is `null`
  /// (uncapped ⇒ no "remaining" number to report).
  int? _remaining(int? limit, int consumed) {
    if (limit == null) return null;
    final left = limit - consumed;
    return left < 0 ? 0 : left;
  }
}
