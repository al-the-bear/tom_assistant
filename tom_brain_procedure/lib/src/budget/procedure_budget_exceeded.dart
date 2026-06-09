// ProcedureBudgetExceeded — the typed refusal a bridged call raises when it
// would exceed an applicable procedure-header budget (PE-8;
// `tom_brain_procedure_specification.md` § 5.4, § 14).
//
// It is a plain `Exception`, deliberately: a procedure script can catch it
// (`catch (e)` / `on Exception catch (e)`) and adapt — drop to a cheaper
// path, summarise early, persist what it has — exactly as the § 14 failure
// table promises ("Bridged call refused; procedure may catch + adapt"). When
// it is *not* caught, the engine records it under [errorKind] and closes the
// run `budgetExceeded`, and the fallback executor surfaces it without
// stepping the version chain (a refusal is a deliberate stop, not a crash —
// an older version would hit the same cap).

/// The budget dimension a [ProcedureBudgetExceeded] was raised against.
///
/// Wall-clock is *not* a member: the procedure-level wall-clock ceiling is
/// enforced by the `StepDeadline` (which closes a run `preempted`), never by
/// the budget ledger. The ledger owns exactly the three count/spend
/// dimensions of `ProcedureBudget` that the deadline does not.
enum BudgetDimension {
  /// Combined input+output token spend across all `llm` calls.
  tokenSpend,

  /// Bridged tool calls other than `llm` (`embed`, `search`, `fetch`).
  toolCalls,

  /// Memory writes (`persist`, `edge`, the mutating `stack.*` ops).
  memoryWrites,
}

/// Raised by a bridged primitive call that an applicable procedure budget
/// refuses (PE-8). Carries which [dimension] was hit, the [limit] that
/// dimension declared, the amount already [consumed] when the call was
/// refused, and the [primitive] that was refused.
final class ProcedureBudgetExceeded implements Exception {
  /// The stable failure class the engine records this refusal under
  /// (§ 10.4 / § 14). Mirrors `procedure.runtime.crash` /
  /// `procedure.parse.failed` as a wire-stable discriminator.
  static const String errorKind = 'procedure.budget.exceeded';

  /// The budget dimension whose cap the refused call would have exceeded.
  final BudgetDimension dimension;

  /// The cap [dimension] declared in the procedure header.
  final int limit;

  /// The amount of [dimension] already consumed when the call was refused.
  /// For a count dimension this is the running tally; for [tokenSpend] it is
  /// the tokens already spent (the gate refuses the *next* call once spend is
  /// at or over the cap, since a call's token cost is unknowable before it
  /// runs).
  final int consumed;

  /// The bridge primitive name that was refused (`embed`, `persist`, `llm`,
  /// …) — the same key the `EffortAccountant` classifies on.
  final String primitive;

  /// Builds the refusal.
  ProcedureBudgetExceeded({
    required this.dimension,
    required this.limit,
    required this.consumed,
    required this.primitive,
  });

  @override
  String toString() => 'ProcedureBudgetExceeded($primitive refused: '
      '${dimension.name} budget of $limit reached (consumed $consumed))';
}
