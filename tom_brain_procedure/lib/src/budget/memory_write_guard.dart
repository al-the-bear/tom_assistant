// MemoryWriteGuard — the per-run, NON-FATAL backstop against an unbounded
// memory-write loop (`tom_brain_procedure_specification.md` § 5.4).
//
// ── Why this exists alongside the BudgetLedger ──────────────────────
//
// The `BudgetLedger` enforces a procedure's *declared* header budget and is
// deliberately fatal: a procedure that sets `memoryWrites: 5` wants a hard
// stop, and an autonomous dream agent that runs away should be pre-empted.
// User-facing procedures, by contrast, run on a virtually-unlimited budget
// (their headers declare no count caps) — so for them the ledger enforces
// nothing, and a runaway write loop (e.g. a `derived_from` edge per recalled
// node, multiplied by a buggy retry) has no backstop at all.
//
// The guard is that backstop. Unlike the ledger it:
//
//   * applies to *every* run regardless of header budget (it is process
//     configuration, `MemoryWriteLimits`, not procedure intent);
//   * is *non-fatal* — reaching a cap is not an error condition. A write that
//     would exceed the cap, or a duplicate edge within the run, is *skipped*
//     (the side effect never happens), the skip is reported on the run trail,
//     and the run continues. The answer a user-facing procedure already
//     produced is never silenced by a write that came after it.
//
// The two mechanisms are independent and ordered: the guard's non-fatal skip
// is consulted first; only an allowed write then reaches the ledger's fatal
// check (which user procedures never trip, having no cap).
//
// ── Loop detection (the dedup set) ──────────────────────────────────
//
// The cheapest, most common runaway is a procedure re-emitting the *same*
// edge — `derived_from(conclusion, node)` for the same pair — in a loop.
// The guard keys every admitted edge by `from|type|to` and skips a repeat,
// so an identical-edge loop is caught on its second iteration regardless of
// how high the count cap is. A loop that emits *diverging* edges is bounded
// instead by [MemoryWriteLimits.maxEdgesPerRun]. Node `persist` writes are
// not deduped — re-persisting the same content is a legitimately new event —
// so they are bounded only by [MemoryWriteLimits.maxWritesPerRun].

/// Configurable per-run caps on memory writes (spec § 5.4).
///
/// All caps are `int?` — `null` means "no cap on this dimension". The
/// defaults ([standard]) are high enough that no legitimate single request
/// approaches them, yet low enough that a runaway loop is bounded long before
/// it can bloat the store.
final class MemoryWriteLimits {
  /// Builds a limit set. Any omitted `int?` cap is unlimited; [dedupEdgesWithinRun]
  /// defaults to enabled (the primary loop detector).
  const MemoryWriteLimits({
    this.maxWritesPerRun,
    this.maxEdgesPerRun,
    this.dedupEdgesWithinRun = true,
  });

  /// The total store-mutating calls (`persist`, `edge`, `stack.*`, `demote`,
  /// …) one run may make. `null` ⇒ unbounded.
  final int? maxWritesPerRun;

  /// The `edge` calls one run may make, on top of (and below) the total cap.
  /// `null` ⇒ bounded only by [maxWritesPerRun].
  final int? maxEdgesPerRun;

  /// Whether an edge whose `from|type|to` was already written in this run is
  /// skipped as a duplicate (the within-run loop detector).
  final bool dedupEdgesWithinRun;

  /// The standard process default: virtually unlimited for any real request,
  /// bounded enough to catch a runaway loop, with edge dedup on.
  static const MemoryWriteLimits standard = MemoryWriteLimits(
    maxWritesPerRun: 2048,
    maxEdgesPerRun: 1024,
    dedupEdgesWithinRun: true,
  );

  /// No caps and no dedup — every write proceeds. For tests / call sites that
  /// deliberately opt out of the backstop.
  static const MemoryWriteLimits unlimited =
      MemoryWriteLimits(dedupEdgesWithinRun: false);
}

/// The outcome of admitting one write against a [MemoryWriteGuard].
enum MemoryWriteOutcome {
  /// The write may proceed; the guard has already counted it.
  allow,

  /// An edge with this `from|type|to` was already written in this run — the
  /// within-run loop detector skipped it.
  skipDuplicateEdge,

  /// The per-run edge cap ([MemoryWriteLimits.maxEdgesPerRun]) is reached.
  skipEdgeCap,

  /// The per-run total-write cap ([MemoryWriteLimits.maxWritesPerRun]) is
  /// reached.
  skipWriteCap;

  /// Whether the write may proceed.
  bool get isAllowed => this == MemoryWriteOutcome.allow;

  /// Whether the write was refused (skipped) — never fatal.
  bool get isSkip => !isAllowed;
}

/// A single skipped write, reported so a run can surface "the memory budget
/// was reached" without failing.
final class MemoryWriteSkip {
  /// Builds a skip record for [primitive] with the deciding [outcome] and the
  /// call's [detail] (its argument map — e.g. the edge's `from`/`type`/`to`).
  const MemoryWriteSkip({
    required this.primitive,
    required this.outcome,
    this.detail = const <String, Object?>{},
  });

  /// The bridged primitive whose write was skipped (`edge`, `persist`, …).
  final String primitive;

  /// Why it was skipped.
  final MemoryWriteOutcome outcome;

  /// The call's argument map, for the trail note.
  final Map<String, Object?> detail;
}

/// Receives every skipped write so the run can record it on its trail.
typedef MemoryWriteSkipSink = void Function(MemoryWriteSkip skip);

/// The per-run write backstop. Stateful and run-scoped: one is built per run
/// over the process's [MemoryWriteLimits] and threaded into that run's memory
/// bridge. Never shared across runs.
final class MemoryWriteGuard {
  /// Builds a guard over [limits].
  MemoryWriteGuard(this.limits);

  /// The caps this guard enforces.
  final MemoryWriteLimits limits;

  int _writes = 0;
  int _edges = 0;
  final Set<String> _seenEdges = <String>{};

  /// Total store-mutating calls admitted so far this run.
  int get writeCount => _writes;

  /// `edge` calls admitted so far this run.
  int get edgeCount => _edges;

  /// Admits an `edge` write from [from] via [type] to [to].
  ///
  /// Returns [MemoryWriteOutcome.allow] (and counts the edge) when it passes
  /// dedup and both caps; otherwise returns the skip reason and counts
  /// nothing. The dedup check runs first so an identical-edge loop is caught
  /// before either cap.
  MemoryWriteOutcome admitEdge(String from, String type, String to) {
    if (limits.dedupEdgesWithinRun) {
      final key = '$from|$type|$to';
      if (_seenEdges.contains(key)) return MemoryWriteOutcome.skipDuplicateEdge;
      final edgeCap = limits.maxEdgesPerRun;
      if (edgeCap != null && _edges >= edgeCap) {
        return MemoryWriteOutcome.skipEdgeCap;
      }
      final writeCap = limits.maxWritesPerRun;
      if (writeCap != null && _writes >= writeCap) {
        return MemoryWriteOutcome.skipWriteCap;
      }
      _seenEdges.add(key);
      _edges++;
      _writes++;
      return MemoryWriteOutcome.allow;
    }
    final edgeCap = limits.maxEdgesPerRun;
    if (edgeCap != null && _edges >= edgeCap) return MemoryWriteOutcome.skipEdgeCap;
    final writeCap = limits.maxWritesPerRun;
    if (writeCap != null && _writes >= writeCap) {
      return MemoryWriteOutcome.skipWriteCap;
    }
    _edges++;
    _writes++;
    return MemoryWriteOutcome.allow;
  }

  /// Admits a non-edge store-mutating write (`persist`, `stack.*`, `demote`,
  /// `updateCentroid`, `proposeNodeType`).
  ///
  /// Returns [MemoryWriteOutcome.allow] (and counts it) when it fits the total
  /// cap; otherwise [MemoryWriteOutcome.skipWriteCap], counting nothing.
  MemoryWriteOutcome admitWrite() {
    final writeCap = limits.maxWritesPerRun;
    if (writeCap != null && _writes >= writeCap) {
      return MemoryWriteOutcome.skipWriteCap;
    }
    _writes++;
    return MemoryWriteOutcome.allow;
  }
}
