// BudgetDelta — incremental cost of a single bridged-API call (or any
// sub-step) against the four `Budget` dimensions.
//
// The delta exists so the procedure runtime can:
//
//   * Charge a call without rebuilding the remaining-budget envelope inline.
//     `Budget.minus(delta)` is the canonical bookkeeping operation.
//   * Emit observability events that carry the cost of one call without
//     leaking the running total (`ProcedureCallMade.consumed: BudgetDelta`
//     in `procedure_specification.md` § 13).
//   * Accumulate per-substep costs in a typed way before deciding whether
//     to commit.
//
// BudgetDelta mirrors `Budget`'s shape exactly. The two types are kept
// separate because their *meanings* are different: a Budget is "what you
// were granted"; a BudgetDelta is "what this call cost." Calling them by
// the same name would lose the distinction at every signature site.

import 'token_spend.dart';

/// One unit of consumption against a [Budget].
///
/// Every field is non-negative. The zero delta is the identity element for
/// addition and is exposed as the static [zero] constant.
final class BudgetDelta {
  /// Wall-clock milliseconds consumed.
  final int wallClockMs;

  /// Tokens consumed (input + output combined — Budgets cap the total).
  final int tokenSpend;

  /// Tool calls issued (web search, web fetch, …).
  final int toolCalls;

  /// Memory writes performed. Capped separately by `WriteBudget` for
  /// memory-internal accounting; tracked here so a procedure budget can
  /// bound it from the outside too.
  final int memoryWrites;

  /// Identity element for accumulation.
  static const BudgetDelta zero = BudgetDelta._raw(0, 0, 0, 0);

  /// Builds a delta. Each component defaults to zero; any explicit negative
  /// value raises [ArgumentError]. A negative delta would mean "this call
  /// gave us budget back," which is not a thing in this system.
  factory BudgetDelta({
    int wallClockMs = 0,
    int tokenSpend = 0,
    int toolCalls = 0,
    int memoryWrites = 0,
  }) {
    if (wallClockMs < 0) {
      throw ArgumentError.value(wallClockMs, 'wallClockMs', 'must be >= 0');
    }
    if (tokenSpend < 0) {
      throw ArgumentError.value(tokenSpend, 'tokenSpend', 'must be >= 0');
    }
    if (toolCalls < 0) {
      throw ArgumentError.value(toolCalls, 'toolCalls', 'must be >= 0');
    }
    if (memoryWrites < 0) {
      throw ArgumentError.value(memoryWrites, 'memoryWrites', 'must be >= 0');
    }
    return BudgetDelta._raw(wallClockMs, tokenSpend, toolCalls, memoryWrites);
  }

  const BudgetDelta._raw(
    this.wallClockMs,
    this.tokenSpend,
    this.toolCalls,
    this.memoryWrites,
  );

  /// Bridge from a `TokenSpend` substrate-cost record into the delta shape.
  ///
  /// The substrate reports tokens as `(input, output)`; the budget envelope
  /// caps total tokens. This factory hides that conversion at the boundary
  /// instead of forcing every caller to remember it. The other three
  /// dimensions are caller-supplied because they are unrelated to the
  /// substrate call itself.
  factory BudgetDelta.fromTokenSpend(
    TokenSpend spend, {
    int wallClockMs = 0,
    int toolCalls = 0,
    int memoryWrites = 0,
  }) =>
      BudgetDelta(
        wallClockMs: wallClockMs,
        tokenSpend: spend.total,
        toolCalls: toolCalls,
        memoryWrites: memoryWrites,
      );

  /// Component-wise addition. Useful for accumulating sub-step costs.
  BudgetDelta operator +(BudgetDelta other) => BudgetDelta._raw(
        wallClockMs + other.wallClockMs,
        tokenSpend + other.tokenSpend,
        toolCalls + other.toolCalls,
        memoryWrites + other.memoryWrites,
      );

  /// True when *every* component is zero. A run that emitted a non-zero
  /// delta and one with no observable cost are useful to distinguish at the
  /// trail layer.
  bool get isZero =>
      wallClockMs == 0 &&
      tokenSpend == 0 &&
      toolCalls == 0 &&
      memoryWrites == 0;

  @override
  bool operator ==(Object other) =>
      other is BudgetDelta &&
      other.wallClockMs == wallClockMs &&
      other.tokenSpend == tokenSpend &&
      other.toolCalls == toolCalls &&
      other.memoryWrites == memoryWrites;

  @override
  int get hashCode =>
      Object.hash(wallClockMs, tokenSpend, toolCalls, memoryWrites);

  @override
  String toString() => 'BudgetDelta('
      'wallClockMs: $wallClockMs, '
      'tokenSpend: $tokenSpend, '
      'toolCalls: $toolCalls, '
      'memoryWrites: $memoryWrites)';
}
