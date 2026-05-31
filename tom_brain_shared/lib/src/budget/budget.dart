// Barrel for the `budget/` module (Plan step A.12). This file also defines
// the `Budget` envelope itself — keeping the primary type in the barrel
// matches the consumer-facing import path (`src/budget/budget.dart`) and
// avoids a redundant `budget_cap.dart` shim.
//
// Module surface:
//
//   * `Budget`            — defined below; the four-dimensional cap envelope
//                           a procedure run executes against.
//   * `BudgetDelta`       — one call's cost (`budget_delta.dart`).
//   * `TokenSpend`        — substrate token accounting (`token_spend.dart`).
//   * `WriteBudget`       — memory-internal write cap (`write_budget.dart`).
//
// Why `Budget` is a separate type from `WriteBudget`: see the file header in
// `write_budget.dart`. Short version — they cap different things at
// different enforcement sites, and collapsing them would erase the
// distinction at every call site.

import 'budget_delta.dart';

export 'budget_delta.dart' show BudgetDelta;
export 'token_spend.dart' show TokenSpend;
export 'write_budget.dart' show WriteBudget;

/// The four-dimensional resource cap a procedure run is granted at
/// dispatch.
///
/// Sourced from the procedure header (`procedure_specification.md` § 4):
///
/// ```yaml
/// budget:
///   wallClockMs: 120000
///   tokenSpend: 40000
///   toolCalls: 30
///   memoryWrites: 6
/// ```
///
/// A run starts with a `Budget` constructed from those values. Each
/// bridged-API call emits a [BudgetDelta] that is charged via [minus]; when
/// any component would go negative, the procedure runtime raises
/// `ProcedureBudgetExceeded` (`procedure_specification.md` § 13) and aborts.
///
/// `Budget` is an immutable value. Mutation is modeled by [minus] returning
/// a new envelope.
final class Budget {
  /// Remaining wall-clock allowance, in milliseconds.
  final int wallClockMs;

  /// Remaining total-token allowance.
  ///
  /// Note: this caps *total* tokens (input + output combined). The substrate
  /// reports `TokenSpend(input, output)`; conversion happens in
  /// `BudgetDelta.fromTokenSpend`.
  final int tokenSpend;

  /// Remaining tool-call allowance (web search, web fetch, …).
  final int toolCalls;

  /// Remaining memory-write allowance — the *procedure-level* cap, distinct
  /// from `WriteBudget` which is memory-internal.
  final int memoryWrites;

  /// Builds a Budget envelope. Every component must be non-negative; a
  /// negative cap is meaningless.
  factory Budget({
    required int wallClockMs,
    required int tokenSpend,
    required int toolCalls,
    required int memoryWrites,
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
    return Budget._raw(wallClockMs, tokenSpend, toolCalls, memoryWrites);
  }

  const Budget._raw(
    this.wallClockMs,
    this.tokenSpend,
    this.toolCalls,
    this.memoryWrites,
  );

  /// True when this envelope can absorb [delta] without any component going
  /// negative.
  ///
  /// The check is component-wise — a delta is rejected as soon as *any one*
  /// dimension would overflow, even if every other dimension has room. This
  /// matches the procedure-runtime contract: the most-constrained dimension
  /// is what fails.
  bool covers(BudgetDelta delta) =>
      delta.wallClockMs <= wallClockMs &&
      delta.tokenSpend <= tokenSpend &&
      delta.toolCalls <= toolCalls &&
      delta.memoryWrites <= memoryWrites;

  /// Returns the envelope after charging [delta].
  ///
  /// Throws [BudgetExceededError] when any component would go negative —
  /// callers that want a non-throwing check use [covers] first. Throwing
  /// (rather than returning a sentinel) is right here: the runtime treats
  /// budget exhaustion as a control-flow event, not a value to plumb
  /// through every call site.
  Budget minus(BudgetDelta delta) {
    if (!covers(delta)) {
      throw BudgetExceededError._(this, delta);
    }
    return Budget._raw(
      wallClockMs - delta.wallClockMs,
      tokenSpend - delta.tokenSpend,
      toolCalls - delta.toolCalls,
      memoryWrites - delta.memoryWrites,
    );
  }

  /// True when every component is zero. A common stop condition for runs
  /// that drained their envelope exactly.
  bool get isExhausted =>
      wallClockMs == 0 &&
      tokenSpend == 0 &&
      toolCalls == 0 &&
      memoryWrites == 0;

  @override
  bool operator ==(Object other) =>
      other is Budget &&
      other.wallClockMs == wallClockMs &&
      other.tokenSpend == tokenSpend &&
      other.toolCalls == toolCalls &&
      other.memoryWrites == memoryWrites;

  @override
  int get hashCode =>
      Object.hash(wallClockMs, tokenSpend, toolCalls, memoryWrites);

  @override
  String toString() => 'Budget('
      'wallClockMs: $wallClockMs, '
      'tokenSpend: $tokenSpend, '
      'toolCalls: $toolCalls, '
      'memoryWrites: $memoryWrites)';
}

/// Thrown by [Budget.minus] when a delta would push any component below
/// zero. The runtime catches this at the bridged-API boundary and emits a
/// `ProcedureBudgetExceeded` event.
///
/// Defined here (rather than in a separate `errors` file) because it is
/// *the* failure mode of the [Budget] type and reading the type alone
/// should tell you about it.
final class BudgetExceededError extends Error {
  /// The envelope at the moment the charge was attempted.
  final Budget remaining;

  /// The delta whose application would have overflowed [remaining].
  final BudgetDelta attempted;

  BudgetExceededError._(this.remaining, this.attempted);

  /// Name of the first dimension that would have gone negative. Useful for
  /// observability so the emitted event can name *which* cap was hit.
  String get dimension {
    if (attempted.wallClockMs > remaining.wallClockMs) return 'wallClockMs';
    if (attempted.tokenSpend > remaining.tokenSpend) return 'tokenSpend';
    if (attempted.toolCalls > remaining.toolCalls) return 'toolCalls';
    return 'memoryWrites';
  }

  @override
  String toString() => 'BudgetExceededError(dimension: $dimension, '
      'remaining: $remaining, attempted: $attempted)';
}
