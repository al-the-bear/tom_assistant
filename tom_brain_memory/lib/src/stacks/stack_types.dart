// Stack types — supporting value types for the StackApi (see
// `memory_specification.md` § 5).
//
// All shapes here are *immutable value records*. The behaviour
// (atomic push/pop, retention demotion, harvester hook scheduling)
// lives behind `StackApi` and is implemented at A.40+. At A.24 only
// the shapes exist so the abstract `TomBrainMemory.stacks` getter
// has a typed surface.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

/// Priority ordering used by a stack at `peek` / `pop` time.
///
/// `peek` and `pop` evaluate the order at call time so a mid-life
/// policy change takes effect immediately for subsequent reads
/// (§ 5.2).
enum PriorityPolicyKind {
  /// Insertion time ascending — first in, first out.
  fifo,

  /// Insertion time descending — last in, first out.
  lifo,

  /// `entry.priority` descending; ties broken by insertion time.
  priority,

  /// `entry.priority * exp(-Δt / halflife)` descending.
  /// `halflife` is part of the policy config (carried separately
  /// because it's only meaningful for this variant).
  timeDecayedPriority,
}

/// Retention rule applied when a stack overflows its bound.
///
/// Demotion never deletes the referenced node — only the
/// `StackEntry` membership row is set to `archived` (§ 5.3).
enum RetentionPolicyKind {
  /// No limit.
  unbounded,

  /// Lowest-priority entries are archived when count exceeds N.
  boundedN,

  /// Entries older than `maxAge` are archived.
  boundedAge,
}

/// Lifecycle status of a single `StackEntry`.
enum StackEntryStatus {
  active,
  archived,
}

/// Combined policy bundle for a stack — what the dispatcher gets
/// back from `StackApi.info`.
final class StackPolicy {
  /// Ordering policy applied at `peek` / `pop`.
  final PriorityPolicyKind priority;

  /// Retention policy applied on overflow.
  final RetentionPolicyKind retention;

  /// Cap for `boundedN`. `null` for the other two variants.
  final int? maxCount;

  /// Max age in milliseconds for `boundedAge`. `null` for the
  /// other two variants.
  final int? maxAgeMs;

  /// Halflife in milliseconds for `timeDecayedPriority`. `null`
  /// for the other priority kinds.
  final int? halflifeMs;

  const StackPolicy({
    required this.priority,
    required this.retention,
    this.maxCount,
    this.maxAgeMs,
    this.halflifeMs,
  });
}

/// Declaration used to create a non-bootstrap stack.
final class StackDecl {
  /// Stack name. Bootstrap stacks have reserved names that
  /// `create` rejects (`memory_specification.md` § 5.4).
  final String name;

  /// One-line summary kept on the underlying `Stack` node.
  final String summary;

  /// Policy bundle.
  final StackPolicy policy;

  /// Node type expected on `push` — enforces the
  /// `entryNodeType` table from § 5.4.
  final String entryNodeType;

  /// Optional dispatcher harvester hook id (procedure to run on
  /// `pushed` events). `null` = no hook.
  final String? harvesterHook;

  const StackDecl({
    required this.name,
    required this.summary,
    required this.policy,
    required this.entryNodeType,
    this.harvesterHook,
  });
}

/// One row of the stack catalogue (`StackApi.list`).
final class StackSummary {
  final String name;
  final int size;
  final double topPriority;
  final bool bootstrap;

  const StackSummary({
    required this.name,
    required this.size,
    required this.topPriority,
    required this.bootstrap,
  });
}

/// Detailed info for a single stack (`StackApi.info`).
final class StackInfo {
  final String name;
  final String summary;
  final StackPolicy policy;
  final String entryNodeType;
  final String? harvesterHook;
  final int size;
  final bool bootstrap;

  const StackInfo({
    required this.name,
    required this.summary,
    required this.policy,
    required this.entryNodeType,
    required this.size,
    required this.bootstrap,
    this.harvesterHook,
  });
}

/// One materialised entry in a stack.
final class StackEntry {
  /// Stable id minted at push time.
  final StackEntryId id;

  /// Owning stack name.
  final String stackName;

  /// The node this entry refers to.
  final NodeId nodeId;

  /// Effective priority. For `timeDecayedPriority` this is the
  /// *raw* priority; decay is applied at read time.
  final double priority;

  /// When the entry was pushed.
  final DateTime pushedAt;

  /// Lifecycle status.
  final StackEntryStatus status;

  /// Optional per-entry attributes.
  final Map<String, Object?> attrs;

  const StackEntry({
    required this.id,
    required this.stackName,
    required this.nodeId,
    required this.priority,
    required this.pushedAt,
    this.status = StackEntryStatus.active,
    this.attrs = const <String, Object?>{},
  });
}

/// Kinds of `StackEvent` emitted on `StackApi.events`.
enum StackEventKind {
  pushed,
  popped,
  updated,
  overflowDemoted,
}

/// One event on a stack's lifecycle stream.
final class StackEvent {
  /// Stack the event is about.
  final String stackName;

  /// What happened.
  final StackEventKind kind;

  /// Entry id involved. Null for `overflowDemoted` events that
  /// span multiple entries (the demoted ids are passed in
  /// [demotedIds] instead).
  final StackEntryId? entryId;

  /// When the event was emitted (UTC).
  final DateTime at;

  /// For `overflowDemoted`: the entry ids that were archived.
  final List<StackEntryId> demotedIds;

  const StackEvent({
    required this.stackName,
    required this.kind,
    required this.at,
    this.entryId,
    this.demotedIds = const <StackEntryId>[],
  });
}
