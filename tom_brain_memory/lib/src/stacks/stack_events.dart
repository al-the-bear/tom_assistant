// Stack `MemoryEvent` leaves — `StackCreated`, `StackPushed`,
// `StackPopped`, `StackEntryUpdated`, `StackEntryRemoved`,
// `StackPolicyChanged`. All emitted by the concrete `StackApi`
// implementation per `memory_specification.md` § 5 + § 16.
//
// Plan step A.40 owns these. The `StackOverflowDemoted` leaf is
// referenced here in shape but the emission path lives behind
// retention enforcement (A.42); A.40 declares the type so the
// stream-typing is stable across steps and the test suite has the
// leaf available the moment A.42 starts wiring it.
//
// Discriminators follow the per-component convention documented on
// `MemoryEvent` (`memory.<kebab-name>`).
//
// All payload maps are constructed `late` inside `payloadJson` so
// the event objects stay cheap when no observer is decoding them.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

import '../api/memory_event.dart';
import 'stack_types.dart';

/// Emitted when `StackApi.create` successfully commits a new
/// non-bootstrap stack (or when bootstrap insertion at A.43 mints a
/// reserved stack on first open).
final class StackCreated extends MemoryEvent {
  /// Stack name.
  final String stackName;

  /// Canonical `Stack` node id minted alongside the row.
  final NodeId stackNodeId;

  /// Node type that `push` will accept on this stack.
  final String entryNodeType;

  /// Policy bundle as committed.
  final StackPolicy policy;

  /// `true` for the six reserved bootstrap names; `false` for
  /// caller-created stacks.
  final bool bootstrap;

  const StackCreated({
    required this.stackName,
    required this.stackNodeId,
    required this.entryNodeType,
    required this.policy,
    required this.bootstrap,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.stack-created';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'stackName': stackName,
        'stackNodeId': stackNodeId.toString(),
        'entryNodeType': entryNodeType,
        'priorityPolicy': policy.priority.name,
        'retentionPolicy': policy.retention.name,
        if (policy.maxCount != null) 'maxCount': policy.maxCount,
        if (policy.maxAgeMs != null) 'maxAgeMs': policy.maxAgeMs,
        if (policy.halflifeMs != null) 'halflifeMs': policy.halflifeMs,
        'bootstrap': bootstrap,
      };
}

/// Emitted when `StackApi.updatePolicy` commits a new policy bundle.
final class StackPolicyChanged extends MemoryEvent {
  /// Stack name.
  final String stackName;

  /// New policy bundle now in force.
  final StackPolicy policy;

  const StackPolicyChanged({
    required this.stackName,
    required this.policy,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.stack-policy-changed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'stackName': stackName,
        'priorityPolicy': policy.priority.name,
        'retentionPolicy': policy.retention.name,
        if (policy.maxCount != null) 'maxCount': policy.maxCount,
        if (policy.maxAgeMs != null) 'maxAgeMs': policy.maxAgeMs,
        if (policy.halflifeMs != null) 'halflifeMs': policy.halflifeMs,
      };
}

/// Emitted when `StackApi.push` commits a fresh entry.
final class StackPushed extends MemoryEvent {
  /// Stack the entry was pushed onto.
  final String stackName;

  /// Stable id minted for the new entry.
  final StackEntryId entryId;

  /// The node referenced by the entry.
  final NodeId nodeId;

  /// Raw priority as supplied to `push`. For
  /// `timeDecayedPriority` stacks, the read-time value applies
  /// decay on top of this.
  final double priority;

  /// Per-entry attribute bag (empty when none supplied). Held by
  /// reference; consumers MUST treat it as read-only.
  final Map<String, Object?> attrs;

  const StackPushed({
    required this.stackName,
    required this.entryId,
    required this.nodeId,
    required this.priority,
    required this.attrs,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.stack-pushed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'stackName': stackName,
        'entryId': entryId.toString(),
        'nodeId': nodeId.toString(),
        'priority': priority,
        if (attrs.isNotEmpty) 'attrs': attrs,
      };
}

/// Emitted when `StackApi.pop` removes and returns the top entry.
///
/// Emitted exactly once per successful pop; never emitted when the
/// stack was empty (pop returned null).
final class StackPopped extends MemoryEvent {
  /// Stack the entry was popped from.
  final String stackName;

  /// Stable id of the popped entry.
  final StackEntryId entryId;

  /// Node the popped entry referenced.
  final NodeId nodeId;

  const StackPopped({
    required this.stackName,
    required this.entryId,
    required this.nodeId,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.stack-popped';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'stackName': stackName,
        'entryId': entryId.toString(),
        'nodeId': nodeId.toString(),
      };
}

/// Emitted when `StackApi.update` mutates an existing entry's
/// priority / status / attrs.
final class StackEntryUpdated extends MemoryEvent {
  /// Stack the entry belongs to.
  final String stackName;

  /// Stable id of the entry that was updated.
  final StackEntryId entryId;

  /// New priority, when `update` carried a `priority:` argument.
  final double? priority;

  /// New status, when `update` carried a `status:` argument.
  final StackEntryStatus? status;

  /// Whether the call replaced the attribute bag. The actual
  /// payload is intentionally not echoed on the event — `attrs` is
  /// caller-defined opaque data and may be large. Consumers
  /// wanting the new value re-read the entry.
  final bool attrsReplaced;

  const StackEntryUpdated({
    required this.stackName,
    required this.entryId,
    required this.attrsReplaced,
    required super.occurredAt,
    this.priority,
    this.status,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.stack-entry-updated';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'stackName': stackName,
        'entryId': entryId.toString(),
        if (priority != null) 'priority': priority,
        if (status != null) 'status': status!.name,
        if (attrsReplaced) 'attrsReplaced': true,
      };
}

/// Emitted when `StackApi.remove` removes a membership row.
///
/// The underlying node is unaffected — only the
/// `stack_entries` row is gone (spec § 5.1 "Removes the entry's
/// membership — the underlying node stays").
final class StackEntryRemoved extends MemoryEvent {
  /// Stack the membership lived in.
  final String stackName;

  /// Stable id of the removed entry.
  final StackEntryId entryId;

  /// Node the removed entry had referenced.
  final NodeId nodeId;

  const StackEntryRemoved({
    required this.stackName,
    required this.entryId,
    required this.nodeId,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.stack-entry-removed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'stackName': stackName,
        'entryId': entryId.toString(),
        'nodeId': nodeId.toString(),
      };
}

/// Emitted when a stack's retention policy archives one or more
/// entries (spec § 5.3 — non-deleting demotion).
///
/// The emission path is wired in A.42 when retention enforcement
/// lands; the type is declared here so the typed `Stream<MemoryEvent>`
/// surface is stable from A.40 onward and the test suite can match
/// on it once A.42 ships.
final class StackOverflowDemoted extends MemoryEvent {
  /// Stack whose retention bound was crossed.
  final String stackName;

  /// The ids of the entries archived (priority field unchanged;
  /// only `status` flipped to `archived`).
  final List<StackEntryId> demotedIds;

  const StackOverflowDemoted({
    required this.stackName,
    required this.demotedIds,
    required super.occurredAt,
    super.runId,
    super.causedBy,
  });

  @override
  String get kind => 'memory.stack-overflow-demoted';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'stackName': stackName,
        'demotedIds': demotedIds.map((id) => id.toString()).toList(),
      };
}
