// StackException — sealed failure family for `StackApi`
// (memory_specification.md § 5).
//
// Every refusal path the stack subsystem can take throws a typed
// subclass so callers (procedure scripts, dispatcher harvesters)
// can branch on the cause without parsing prose.
//
// Categories, in the order they typically occur:
//
//   1. `StackNotFound`            — operation referenced a stack
//                                   name that has no row in
//                                   `stacks`. Either it was never
//                                   `create`d or a non-bootstrap
//                                   stack was removed.
//   2. `StackAlreadyExists`       — `create` called with a name
//                                   already present. Bootstrap
//                                   collisions raise
//                                   [BootstrapStackImmutable]
//                                   instead.
//   3. `BootstrapStackImmutable`  — `create` (or future delete)
//                                   targeted one of the six
//                                   reserved bootstrap names
//                                   (§ 5.4).
//   4. `StackEntryNotFound`       — `update` / `remove` named a
//                                   `(name, NodeId)` pair that has
//                                   no live entry row.
//   5. `StackPolicyConfigInvalid` — a `StackPolicy` bundle is
//                                   inconsistent (e.g. `boundedN`
//                                   without `maxCount`, or
//                                   `timeDecayedPriority` without
//                                   `halflifeMs`). Surfaced by
//                                   `create` and `updatePolicy`.

import 'package:tom_core_agentic/tom_core_agentic.dart' show formatException;

/// Sealed base for every refusal of a `StackApi` call.
sealed class StackException implements Exception {
  /// Human-readable explanation. Always names the stack involved.
  final String message;

  const StackException(this.message);

  @override
  String toString() => formatException(this, message);
}

/// `name` does not match any row in `stacks`.
final class StackNotFound extends StackException {
  /// The missing stack name.
  final String stackName;

  const StackNotFound({
    required this.stackName,
    required String message,
  }) : super(message);
}

/// `create` was called with a name already in use (and the existing
/// stack is not a bootstrap stack — bootstrap collisions raise
/// [BootstrapStackImmutable]).
final class StackAlreadyExists extends StackException {
  /// The colliding stack name.
  final String stackName;

  const StackAlreadyExists({
    required this.stackName,
    required String message,
  }) : super(message);
}

/// `create` (or future delete) targeted one of the six reserved
/// bootstrap stack names.
final class BootstrapStackImmutable extends StackException {
  /// The bootstrap stack name the caller tried to mutate.
  final String stackName;

  const BootstrapStackImmutable({
    required this.stackName,
    required String message,
  }) : super(message);
}

/// `(stackName, nodeId)` does not match a live entry row.
final class StackEntryNotFound extends StackException {
  /// Owning stack name.
  final String stackName;

  /// Node id the caller used to address the entry.
  final String nodeIdString;

  const StackEntryNotFound({
    required this.stackName,
    required this.nodeIdString,
    required String message,
  }) : super(message);
}

/// A `StackPolicy` bundle is internally inconsistent (e.g. a
/// `boundedN` retention with no `maxCount` set, or
/// `timeDecayedPriority` priority with no `halflifeMs` set).
final class StackPolicyConfigInvalid extends StackException {
  /// The stack the policy was intended for (may be a not-yet-created
  /// stack on the `create` path).
  final String stackName;

  /// Categorical reason — so callers (and the
  /// `StackPolicyChanged` observer) can branch without parsing the
  /// `message`.
  final StackPolicyConfigInvalidReason reason;

  const StackPolicyConfigInvalid({
    required this.stackName,
    required this.reason,
    required String message,
  }) : super(message);
}

/// Categorical reason for [StackPolicyConfigInvalid].
enum StackPolicyConfigInvalidReason {
  /// `retention = boundedN` but `maxCount` is null or non-positive.
  boundedNWithoutMaxCount,

  /// `retention = boundedAge` but `maxAgeMs` is null or non-positive.
  boundedAgeWithoutMaxAgeMs,

  /// `priority = timeDecayedPriority` but `halflifeMs` is null or
  /// non-positive.
  timeDecayedWithoutHalflifeMs,

  /// `retention = unbounded` but a bound (`maxCount` or `maxAgeMs`)
  /// was supplied — likely a caller mix-up the writer surfaces
  /// rather than silently honour.
  unboundedWithBoundSupplied,

  /// `priority` is not `timeDecayedPriority` but `halflifeMs` was
  /// supplied — again a caller mix-up, not silently honoured.
  staticPriorityWithHalflifeSupplied,
}
