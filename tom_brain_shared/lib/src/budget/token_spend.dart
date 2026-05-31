// TokenSpend — accounting record for tokens consumed by a substrate LLM call.
//
// Why a dedicated type rather than a bare `int`?
//
//   * Substrate billing is two-dimensional. Input and output tokens carry
//     different prices on every paid provider and different rate-limit
//     buckets on most free ones. Collapsing the two into a single integer at
//     this layer would force every downstream consumer that cares about
//     either dimension to rebuild the structure from scratch.
//   * Accumulation is the dominant operation. A `think` call may issue
//     several substrate calls; the trail records the sum. Making that an
//     `operator +` on a value type keeps the accumulation site readable
//     (`spend += callSpend`).
//   * Conversion to `BudgetDelta` is well-defined. A Budget caps *total*
//     tokens (`Budget.tokenSpend`); a TokenSpend exposes `total` to make
//     that bridge obvious. The bridge lives on `BudgetDelta.fromTokenSpend`
//     so neither side has to know about the other's shape inline.
//
// TokenSpend is **not** the place to track wall-clock time, tool calls, or
// memory writes — those are `Budget` / `BudgetDelta` concerns. TokenSpend is
// strictly substrate-call accounting.

/// Tokens consumed by a substrate LLM call (or an accumulated run of calls).
///
/// Both [input] and [output] are non-negative; constructing a negative spend
/// is rejected at construction. Addition is component-wise.
final class TokenSpend {
  /// Tokens sent to the substrate (prompt + system + role anchor + context).
  final int input;

  /// Tokens received from the substrate (the generated answer).
  final int output;

  /// Zero-cost record. The right starting value for an accumulator.
  static const TokenSpend zero = TokenSpend._raw(0, 0);

  /// Builds a TokenSpend. Negative inputs raise [ArgumentError]; a
  /// negative spend is meaningless and almost always indicates a bug in the
  /// caller's accounting.
  factory TokenSpend({int input = 0, int output = 0}) {
    if (input < 0) {
      throw ArgumentError.value(input, 'input', 'must be >= 0');
    }
    if (output < 0) {
      throw ArgumentError.value(output, 'output', 'must be >= 0');
    }
    return TokenSpend._raw(input, output);
  }

  // Private const constructor for the `zero` sentinel only. The factory above
  // is the entry point that enforces the non-negative invariant; bypassing it
  // is reserved for compile-time constants where the values are obviously
  // valid.
  const TokenSpend._raw(this.input, this.output);

  /// Sum of input and output tokens — the dimension a `Budget.tokenSpend`
  /// cap is measured against.
  int get total => input + output;

  /// Component-wise sum. Right operand's `input` adds to left's `input`, and
  /// the same for `output`.
  TokenSpend operator +(TokenSpend other) =>
      TokenSpend._raw(input + other.input, output + other.output);

  @override
  bool operator ==(Object other) =>
      other is TokenSpend && other.input == input && other.output == output;

  @override
  int get hashCode => Object.hash(input, output);

  @override
  String toString() => 'TokenSpend(input: $input, output: $output)';
}
