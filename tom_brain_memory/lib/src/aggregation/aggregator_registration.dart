// The `aggregator` agent registration + the GA-8 live-path guard exception
// (memory_specification.md § 2.6, GA-5 / GA-8).
//
// `aggregatorRegistration` is the single `AgentRegistration` the global
// child store is seeded with by `SqliteMemoryProfileRegistry.writeInProfile`
// just before an aggregation pass writes into `global`. It carries the
// store-wide `profile:global` grant so the engine's node writes pass the
// `AgentRegistry` guard, and its `agentName` (`aggregator`) is the value
// GA-8 checks for on the live cross-store path.
//
// `GlobalProfileWriteForbidden` is the GA-8 rejection: a node / edge write
// against the reserved `global` profile that does NOT carry the
// `aggregator` agent identity is refused before any row lands. d4rt
// procedures cannot set `Scope.agentName`, so a procedure can never spoof
// the aggregator — only the in-engine aggregation writes (issued under the
// registration installed on the global child store) reach `global`.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration, WriteBudget;

import 'profile_aggregator.dart' show aggregatorAgentName, aggregatorProducer;

/// Per-pass node ceiling for the aggregator's default budget.
///
/// The aggregation tier re-derives every allowlisted semantic node across
/// every source profile, so the count is unbounded by design. This is the
/// dispatcher *default* budget the registration carries; it is not enforced
/// on the aggregation write path itself (the `global` child store begins no
/// `WriteBudgetTracker` run, so writes pass through unbudgeted — the budget
/// is opt-in at the write site). The value is therefore a high, explicit
/// ceiling rather than a tight cap.
const int _aggregatorMaxNodesPerPass = 1000000;

/// The `aggregator` agent registration (memory § 2.6, GA-5).
///
/// Installed on the `global` child store by
/// `SqliteMemoryProfileRegistry.writeInProfile` before each pass. The
/// store-wide `profile:global` grant authorises the engine's node writes
/// (GA-3 allowlisted types); no edges and no stack entries are written by
/// aggregation, so those budgets are zero.
final AgentRegistration aggregatorRegistration = AgentRegistration(
  agentName: aggregatorAgentName,
  procedureId: aggregatorProducer,
  defaultBudget: WriteBudget(
    maxNodes: _aggregatorMaxNodesPerPass,
    maxEdges: 0,
    maxStackEntries: 0,
  ),
  readScopes: const <String>{AgentRegistration.globalWildcard},
  writeScopes: <String>{AgentRegistration.profileScope('global')},
);

/// Thrown on the live request/persist path when a node / edge write targets
/// the reserved `global` profile without the `aggregator` agent identity
/// (memory § 2.6, GA-8).
///
/// This is the structural guarantee that `global` is written *only* by the
/// aggregation tier: ordinary procedures and channels — which cannot set
/// `Scope.agentName` — are refused before any row lands, so `global` can
/// never be mutated by a normal answer/dream write that happens to be
/// running with the `global` profile bound.
final class GlobalProfileWriteForbidden implements Exception {
  /// The kind of resource the rejected write targeted (`node` or `edge`).
  final String resourceKind;

  /// A human description of the rejected resource (the node type name or
  /// the edge wire name) for the diagnostic message.
  final String resourceDetail;

  /// The `Scope.agentName` the rejected write carried, or `null` when the
  /// write was anonymous. Anything other than `aggregator` is rejected.
  final String? agentName;

  GlobalProfileWriteForbidden({
    required this.resourceKind,
    required this.resourceDetail,
    required this.agentName,
  });

  @override
  String toString() => 'GlobalProfileWriteForbidden: a $resourceKind write '
      '($resourceDetail) targeted the reserved "global" profile under '
      'agent ${agentName == null ? '<none>' : '"$agentName"'}, but only '
      'the "$aggregatorAgentName" agent may write "global" (memory § 2.6, '
      'GA-8). The global tier is derived solely by the aggregation pass.';
}
