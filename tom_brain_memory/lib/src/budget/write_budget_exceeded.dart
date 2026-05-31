// WriteBudgetExceeded — memory-internal exception raised when a write
// would push a run's WriteBudget below zero (Plan step A.68).
//
// This is the memory side of the procedure-runtime's
// `BudgetExceededError` (`tom_brain_shared.budget.BudgetExceededError`):
//
//   * `BudgetExceededError` fires inside the procedure runtime when a
//     bridged-API call would overflow the four-dimensional procedure
//     `Budget` (wallClockMs / tokenSpend / toolCalls / memoryWrites).
//   * `WriteBudgetExceeded` fires inside memory when an accepted
//     `persist` / `edge` / stack `push` would overflow the
//     per-agent-run `WriteBudget` (maxNodes / maxEdges /
//     maxStackEntries) the dispatcher attached to the run.
//
// They live in different packages because the call sites that throw
// them live in different layers. Collapsing them into one type would
// force memory to import the procedure-runtime exception or vice
// versa; keeping them separate keeps the dependency edge pointing the
// right way (procedure → memory, never the reverse).
//
// Why a separate type rather than reusing `BudgetExceededError` from
// `tom_brain_shared`: the shared type's `dimension` getter enumerates
// the procedure-runtime dimensions and would lie when applied to a
// memory-write rejection. A WriteBudget rejection has its own
// dimension set (`maxNodes` / `maxEdges` / `maxStackEntries`), so the
// type that carries it should reflect that set.

import 'package:tom_brain_shared/tom_brain_shared.dart' show WriteBudget;

/// Which `WriteBudget` component a write would have overflowed.
///
/// Kept as an enum (not a string) so the dispatcher can branch on the
/// dimension without parsing — e.g. demoting a Connector that keeps
/// hitting `maxEdges` is a different action from defer-and-resume on
/// `maxStackEntries`.
enum WriteBudgetDimension {
  /// `WriteBudget.maxNodes` would have gone negative.
  maxNodes,

  /// `WriteBudget.maxEdges` would have gone negative.
  maxEdges,

  /// `WriteBudget.maxStackEntries` would have gone negative.
  maxStackEntries,
}

/// Thrown by `NodePersister.persist`, `EdgeWriter.edge`, and
/// `StackApi.push` when the in-flight write would push the active
/// `WriteBudget` for the calling run below zero.
///
/// The exception is raised *before* the SQLite INSERT runs — no row
/// is left behind, no event is emitted, the tracker's remaining
/// counters are not decremented. The dispatcher catches this at the
/// bridged-API boundary (`procedure_specification.md` § 13) and
/// converts it to a `ProcedureBudgetExceeded` outcome so the
/// procedure can decide whether to truncate, defer, or re-schedule
/// (`memory_specification.md` § 9.3).
///
/// Why this is an `Exception` and not an `Error`:
///
///   * `Error` (which `BudgetExceededError` extends in
///     `tom_brain_shared`) is appropriate when the failure is a
///     programmer mistake — the procedure runtime treats overflow as
///     a programming-time invariant violation because the run was
///     itself granted the dimensions it is now exceeding.
///   * `WriteBudgetExceeded` fires on accepted writes inside
///     memory, where the *only* sensible response is to recover and
///     re-plan. Exceptions are the recoverable failure mode in Dart
///     — see `EdgeWriteException` / `NodePersistException` for the
///     same pattern.
final class WriteBudgetExceeded implements Exception {
  /// The dimension that would have gone negative.
  final WriteBudgetDimension dimension;

  /// The run id that owns the budget.
  final String runId;

  /// The budget *as registered* by `beginRun` — the original cap, not
  /// the remaining counters. Useful for the dispatcher's diagnostic
  /// ("you asked for maxNodes: 5, you persisted 5, the 6th was
  /// rejected"). The remaining counters are not surfaced because
  /// they are always zero in the rejected dimension by the time
  /// the exception fires.
  final WriteBudget budget;

  /// Producer that issued the rejected write
  /// (`Scope.producer`). Carried so the rejection can be attributed
  /// even when several producers share a single run id (rare, but
  /// permitted by the registry contract).
  final String producer;

  /// Free-form human-readable message. The dispatcher logs this; the
  /// `dimension` / `runId` / `producer` fields are the structured
  /// counterparts for programmatic handling.
  final String message;

  WriteBudgetExceeded({
    required this.dimension,
    required this.runId,
    required this.budget,
    required this.producer,
    required this.message,
  });

  @override
  String toString() => 'WriteBudgetExceeded('
      'dimension: ${dimension.name}, '
      'runId: $runId, '
      'producer: $producer, '
      'budget: $budget): $message';
}
