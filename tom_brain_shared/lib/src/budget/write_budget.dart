// WriteBudget — memory-specific resource cap, distinct from `Budget`.
//
// `Budget` and `WriteBudget` look superficially similar — both bound how
// much an agent run is allowed to do — but they cap different things at
// different boundaries:
//
//   * `Budget` is enforced by the procedure runtime around the bridged-API
//     surface (`think`, `plan`, `create`, `recall`, `fetch`, …). It bounds
//     wall-clock, tokens, tool calls and memory writes *for the run*.
//   * `WriteBudget` is enforced *inside memory* on every accepted write. It
//     bounds how many nodes / edges / stack entries a single agent run is
//     allowed to introduce, separately from whatever the outer procedure
//     budget said.
//
// Memory needs its own write limit because cognitive agents (Extractor,
// Connector, Synthesizer, …) run with their own per-agent default budget
// declared in the agent registry (`memory_specification.md` § 9.5) and the
// limit must hold even when the calling procedure has plenty of
// `memoryWrites` left. A Connector that suddenly tries to write 10 000
// edges in a single restructure pass is a bug in the Connector regardless
// of how generous the procedure budget was.
//
// Keeping `WriteBudget` separate from `Budget` keeps both shapes honest. A
// `Budget.memoryWrites` cap means "the procedure as a whole is allowed at
// most N writes"; a `WriteBudget.maxNodes` cap means "this specific agent
// run is allowed at most M new nodes." Collapsing them would lose the
// distinction.

/// Memory-internal cap on what a single agent run may create.
///
/// All three components are non-negative. A zero in any field is allowed
/// and means "no writes of this kind are permitted in this run" — useful
/// for read-only agents (e.g. `Pruner` may decrement reinforcement counts
/// but not create nodes; that maps to `maxNodes: 0`).
///
/// See `memory_specification.md` § 9.3 (write-budget enforcement) and § 9.5
/// (per-agent registry).
final class WriteBudget {
  /// Maximum new nodes this run may persist.
  final int maxNodes;

  /// Maximum new edges this run may introduce.
  final int maxEdges;

  /// Maximum stack entries this run may push.
  final int maxStackEntries;

  /// A WriteBudget that forbids every kind of write. Useful as an explicit
  /// "no writes" signal — clearer than passing `WriteBudget(0, 0, 0)` at the
  /// call site every time.
  static const WriteBudget readOnly = WriteBudget._raw(0, 0, 0);

  /// Builds a WriteBudget. All three components must be non-negative.
  factory WriteBudget({
    required int maxNodes,
    required int maxEdges,
    required int maxStackEntries,
  }) {
    if (maxNodes < 0) {
      throw ArgumentError.value(maxNodes, 'maxNodes', 'must be >= 0');
    }
    if (maxEdges < 0) {
      throw ArgumentError.value(maxEdges, 'maxEdges', 'must be >= 0');
    }
    if (maxStackEntries < 0) {
      throw ArgumentError.value(
        maxStackEntries,
        'maxStackEntries',
        'must be >= 0',
      );
    }
    return WriteBudget._raw(maxNodes, maxEdges, maxStackEntries);
  }

  const WriteBudget._raw(this.maxNodes, this.maxEdges, this.maxStackEntries);

  /// True when this budget forbids every kind of write.
  bool get isReadOnly =>
      maxNodes == 0 && maxEdges == 0 && maxStackEntries == 0;

  @override
  bool operator ==(Object other) =>
      other is WriteBudget &&
      other.maxNodes == maxNodes &&
      other.maxEdges == maxEdges &&
      other.maxStackEntries == maxStackEntries;

  @override
  int get hashCode => Object.hash(maxNodes, maxEdges, maxStackEntries);

  @override
  String toString() => 'WriteBudget('
      'maxNodes: $maxNodes, '
      'maxEdges: $maxEdges, '
      'maxStackEntries: $maxStackEntries)';
}
