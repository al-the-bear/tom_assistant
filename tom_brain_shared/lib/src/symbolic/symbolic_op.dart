// SymbolicOp — comparator alphabet for `AttrClause`.
//
// The set is closed: a fixed alphabet of eight operators. Adding a new
// operator is a coordinated change across every consumer (the compiler in
// `tom_brain_memory/retrieval/symbolic_recall.dart`, every test suite,
// the procedure-engine bridge in Phase C). Per the `tom_brain` quest
// overview Hard Principle 1 ("no backwards compatibility"), additions
// land in lockstep across all consumers.

/// Comparator operators usable in a `SymbolicFilter` attribute clause.
///
/// The list is intentionally short: it matches the set of operators the
/// SQLite compiler in memory currently turns into parameterised SQL.
enum SymbolicOp {
  /// `field = value`
  eq,

  /// `field <> value`
  ne,

  /// `field < value`
  lt,

  /// `field <= value`
  lte,

  /// `field > value`
  gt,

  /// `field >= value`
  gte,

  /// `field IN (value₁, value₂, …)` — `value` must be a `List`.
  inList,

  /// `field NOT IN (value₁, value₂, …)` — `value` must be a `List`.
  notInList,
}
