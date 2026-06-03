// WriteBudgetTracker — in-process bookkeeping for per-run
// `WriteBudget` enforcement (Plan step A.68; spec § 9.3, § 9.5).
//
// What this file owns:
//
//   - The map `runId -> remaining (maxNodes, maxEdges,
//     maxStackEntries)`. `beginRun` seeds an entry; `endRun` removes
//     it. The map lives in process — there is no persistence. A
//     restart loses the in-flight counters, which matches the spec's
//     framing: budgets are attached to *runs*, and the runs do not
//     survive process boundaries either.
//   - The `chargeNode` / `chargeEdge` / `chargeStackEntry` decrement
//     paths. Each one is an atomic check-and-decrement: if the
//     remaining counter is zero, throw `WriteBudgetExceeded` and do
//     not decrement; otherwise decrement by one and return.
//   - Pass-through semantics for unregistered runs. A write that
//     names a `runId` for which `beginRun` was never called is
//     **allowed** without budget enforcement. This is deliberate —
//     bootstrap writes (initial node-type registration, bootstrap
//     stacks installation) happen before any procedure run exists,
//     and forcing them through a tracker registration would muddy
//     the layering. The tracker enforces only what was opted into
//     via `beginRun`.
//   - Pass-through semantics for null `runId`. Same reasoning — a
//     write without a run identity has nothing to charge against.
//
// What this file does NOT own:
//
//   - Wall-clock enforcement of the procedure-level `Budget`. That
//     stays in the procedure runtime; memory's WriteBudget is a
//     finer-grained, memory-internal cap (see the header comment on
//     `WriteBudget` itself for the why).
//   - Refunds. A rejected write does not consume budget (the
//     decrement happens after the rejection check passes); a
//     successful idempotent no-op also does not consume budget (the
//     idempotency lookup short-circuits before the charge call).
//     There is no path that needs to refund a charge.
//   - Persistence. A run's remaining counters are in-memory only.
//
// Concurrency model:
//
//   - The tracker is intended for single-isolate use (the dispatcher
//     and memory share an isolate for v1). Each charge is an
//     in-process int decrement guarded by a synchronous
//     check-and-update — Dart's single-threaded event loop makes
//     this atomic by construction without locks. The isolate-bridged
//     deployment (A.78+) introduces a cross-isolate boundary; at
//     that point the tracker is part of memory's isolate and is
//     reached by message-passing, which preserves the
//     single-decrement-per-call property.

import 'package:tom_brain_shared/tom_brain_shared.dart' show WriteBudget;

import 'write_budget_exceeded.dart';

/// In-process bookkeeping for per-run `WriteBudget` enforcement.
///
/// One `WriteBudgetTracker` per open memory store; held by the
/// higher-level `SqliteTomBrainMemory` (A.86+) and consulted by
/// `NodePersister`, `EdgeWriter`, and `SqliteStackApi` on every
/// write.
///
/// The tracker is **opt-in**: a run that wants budget enforcement
/// calls [beginRun] at the start and [endRun] at the end. Writes
/// that name a `runId` the tracker does not know about pass through
/// unchecked. The spec § 9.5 frames this as agent registry
/// responsibility — only registered agents have budgets, and the
/// dispatcher is the single entry point that registers a run on
/// behalf of the agent.
final class WriteBudgetTracker {
  /// `runId -> [maxNodes, maxEdges, maxStackEntries]`, in remaining
  /// (not original) units. A negative counter cannot exist — every
  /// decrement is guarded.
  final Map<String, _Remaining> _runs = <String, _Remaining>{};

  /// Registers [budget] as the cap for [runId].
  ///
  /// A second call with the same [runId] replaces the prior
  /// registration (most likely a programmer error — runs are unique
  /// — but treated as an honest reset rather than silently ignored).
  /// The dispatcher is expected to call [endRun] before re-using a
  /// run id; if it does not, the second [beginRun] resets the
  /// remaining counters to the new budget, which is the obvious and
  /// least-surprising semantics.
  void beginRun({required String runId, required WriteBudget budget}) {
    _runs[runId] = _Remaining(
      budget: budget,
      maxNodes: budget.maxNodes,
      maxEdges: budget.maxEdges,
      maxStackEntries: budget.maxStackEntries,
    );
  }

  /// Removes the registration for [runId]. Subsequent writes that
  /// name the same id pass through unchecked.
  ///
  /// Called by the dispatcher when the run terminates (success,
  /// failure, or cancellation). Calling [endRun] for an unregistered
  /// run id is a no-op — same shape as `close()` on an
  /// already-closed resource.
  void endRun(String runId) {
    _runs.remove(runId);
  }

  /// Returns `true` when [runId] currently has a registered budget.
  ///
  /// Used by tests and by the future operator UI to distinguish "no
  /// budget — pass through" from "budget exhausted".
  bool isRegistered(String runId) => _runs.containsKey(runId);

  /// Returns the remaining counters for [runId], or `null` when the
  /// run is not registered. Exposed for the operator UI / observers;
  /// production write paths consult the tracker via the typed charge
  /// methods, not via this getter.
  WriteBudget? remaining(String runId) {
    final r = _runs[runId];
    if (r == null) return null;
    return WriteBudget(
      maxNodes: r.maxNodes,
      maxEdges: r.maxEdges,
      maxStackEntries: r.maxStackEntries,
    );
  }

  /// Charges one node-write against [runId].
  ///
  /// Pass-through (no-op) when [runId] is null or unregistered.
  /// Throws [WriteBudgetExceeded] when the registered run has zero
  /// `maxNodes` remaining — the rejected write does not consume
  /// budget.
  void chargeNode({required String? runId, required String producer}) {
    _charge(
      runId: runId,
      producer: producer,
      dimension: WriteBudgetDimension.maxNodes,
      cap: (b) => b.maxNodes,
      remaining: (r) => r.maxNodes,
      decrement: (r) => r.maxNodes -= 1,
      noun: 'persist',
    );
  }

  /// Charges one edge-write against [runId]. Same semantics as
  /// [chargeNode] but on the `maxEdges` dimension.
  void chargeEdge({required String? runId, required String producer}) {
    _charge(
      runId: runId,
      producer: producer,
      dimension: WriteBudgetDimension.maxEdges,
      cap: (b) => b.maxEdges,
      remaining: (r) => r.maxEdges,
      decrement: (r) => r.maxEdges -= 1,
      noun: 'edge',
    );
  }

  /// Charges one stack-push against [runId]. Same semantics as
  /// [chargeNode] but on the `maxStackEntries` dimension.
  void chargeStackEntry({required String? runId, required String producer}) {
    _charge(
      runId: runId,
      producer: producer,
      dimension: WriteBudgetDimension.maxStackEntries,
      cap: (b) => b.maxStackEntries,
      remaining: (r) => r.maxStackEntries,
      decrement: (r) => r.maxStackEntries -= 1,
      noun: 'push',
    );
  }

  /// Atomic check-and-decrement shared by the three typed charge
  /// methods. The dimension differs only in which counter it reads,
  /// which cap it reports, and the noun in the rejection message — the
  /// guard-and-decrement logic is identical, so it lives here once.
  ///
  /// Pass-through (no-op) when [runId] is null or unregistered. Throws
  /// [WriteBudgetExceeded] when [remaining] reads zero — the rejected
  /// write does not consume budget (no decrement runs).
  void _charge({
    required String? runId,
    required String producer,
    required WriteBudgetDimension dimension,
    required int Function(WriteBudget budget) cap,
    required int Function(_Remaining r) remaining,
    required void Function(_Remaining r) decrement,
    required String noun,
  }) {
    if (runId == null) return;
    final r = _runs[runId];
    if (r == null) return;
    if (remaining(r) == 0) {
      throw WriteBudgetExceeded(
        dimension: dimension,
        runId: runId,
        budget: r.budget,
        producer: producer,
        message:
            'run "$runId" has exhausted its WriteBudget.${dimension.name} '
            '(cap: ${cap(r.budget)}). The Nth+1 $noun was '
            'rejected without inserting a row or emitting an event.',
      );
    }
    decrement(r);
  }
}

/// Per-run mutable remaining counters. Internal — callers see only
/// the immutable [WriteBudget] snapshot via [WriteBudgetTracker.remaining].
final class _Remaining {
  final WriteBudget budget;
  int maxNodes;
  int maxEdges;
  int maxStackEntries;

  _Remaining({
    required this.budget,
    required this.maxNodes,
    required this.maxEdges,
    required this.maxStackEntries,
  });
}
