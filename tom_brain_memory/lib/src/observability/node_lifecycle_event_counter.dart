// NodeLifecycleEventCounter — running tally of node-lifecycle
// `MemoryEvent`s, feeding `MemoryStats.lifecycleEventCounts`
// (memory_optimization_plan.md § 17).
//
// Why a counter and not a DB query: a promotion is a *transition*
// (`demoted → active`), not a column. The store has no "how many
// promotions happened" row to COUNT — the only record of the transition
// is the `NodePromoted` event the lifecycle manager emits. So the count
// is accumulated from the event stream, exactly the four
// node-lifecycle leaves:
//
//   * `memory.node-persisted` (NodePersister)
//   * `memory.node-promoted`  (NodeLifecycleManager.promote)
//   * `memory.node-demoted`   (NodeLifecycleManager.demote)
//   * `memory.node-forgotten` (NodeLifecycleManager.forget)
//
// Why synchronous, not a bus subscription: `MemoryEventBus` is a
// broadcast(`sync: false`) stream — a subscriber sees an emission on a
// *later* microtask. A counter that subscribed would lag the producer,
// so a `promote()` immediately followed by `stats()` could read a stale
// count. The composition root therefore taps `observe()` into the
// event sink it hands the lifecycle producers, *before* forwarding to
// the bus, so the tally is exact at the moment `stats()` is read with
// no race against the (separate, async) `events()` feed.

import 'package:tom_brain_shared/tom_brain_shared.dart' show MemoryEvent;

/// Accumulates per-kind counts of the four node-lifecycle
/// `MemoryEvent`s for the `MemoryStats.lifecycleEventCounts` slice.
///
/// One per open `SqliteTomBrainMemory`. Not thread-safe by design — the
/// memory subsystem emits on a single isolate; the counter rides the
/// same thread as the producers it taps.
final class NodeLifecycleEventCounter {
  /// The closed set of event `kind` discriminators this counter tallies.
  /// Every other event (`stack-*`, `edge-*`, `recall-*`, `shaking-*`, …)
  /// is ignored, so tapping the counter onto a sink that also carries
  /// non-lifecycle events is harmless.
  static const Set<String> lifecycleKinds = <String>{
    'memory.node-persisted',
    'memory.node-promoted',
    'memory.node-demoted',
    'memory.node-forgotten',
  };

  final Map<String, int> _counts = <String, int>{};

  /// Tallies [event] when its `kind` names a node-lifecycle transition;
  /// ignores every other event.
  void observe(MemoryEvent event) {
    final kind = event.kind;
    if (lifecycleKinds.contains(kind)) {
      _counts[kind] = (_counts[kind] ?? 0) + 1;
    }
  }

  /// A copy of the current per-kind tally. Kinds with no observed
  /// transition are absent (not present-with-zero), matching the
  /// `MemoryStats.lifecycleEventCounts` contract.
  Map<String, int> snapshot() => Map<String, int>.of(_counts);
}
