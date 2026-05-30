// NodeTypeRegistrationException — typed failure family for
// `NodeTypeRegistry.registerNodeType` (Plan step A.33).
//
// Every refusal path the registry can take throws a typed subclass so
// callers can branch on the cause without parsing prose. The base
// class is sealed: adding a new failure category is a deliberate
// breaking change in this layer.
//
// Categories, in the order the registry checks them:
//
//   1. `InvalidNodeTypeDecl`         — the proposal is structurally
//                                       wrong (bad name, version < 1,
//                                       empty schema, embedding policy
//                                       references a missing field, …).
//                                       The hook is *not* consulted —
//                                       these errors are caught before
//                                       any I/O.
//   2. `NodeTypeAlreadyExists`       — a fresh proposal (no
//                                       `supersedes`) collides with a
//                                       registered name.
//   3. `NodeTypeNotFound`            — the proposal sets `supersedes`
//                                       but the referenced predecessor
//                                       is not registered, or the
//                                       registered decl for that name
//                                       has a different decl-node id.
//   4. `NodeTypeVersionNotMonotonic` — the proposal sets `supersedes`
//                                       and the predecessor exists, but
//                                       the new version is not strictly
//                                       greater than the predecessor's.
//   5. `NodeTypeRejected`            — structural and consistency
//                                       checks passed; the
//                                       caller-supplied `CritiqueHook`
//                                       returned `CritiqueRejected` (or
//                                       crashed — see the hook
//                                       contract).
//
// Per the quest's hard principles, none of these errors are
// recoverable inside memory — the caller (`propose_node_type_v1` in
// the dispatcher) decides whether to retry, surface to the user, or
// re-author the proposal.

/// Sealed base for every failure category of `registerNodeType`.
sealed class NodeTypeRegistrationException implements Exception {
  /// Type name the proposal carried (preserved so logs always identify
  /// the offending decl even when the exception is caught far from
  /// the call site).
  final String typeName;

  /// Human-readable explanation. Always names the type and, when
  /// relevant, the specific field / version / conflicting name.
  final String message;

  const NodeTypeRegistrationException({
    required this.typeName,
    required this.message,
  });

  @override
  String toString() => '$runtimeType($typeName): $message';
}

/// The proposal is structurally wrong. Raised by the registry *before*
/// any I/O — the critique hook is not consulted.
final class InvalidNodeTypeDecl extends NodeTypeRegistrationException {
  /// Name of the field or sub-policy that failed validation. `null`
  /// when the failure is at the top level (e.g. bad `typeName`).
  final String? fieldPath;

  const InvalidNodeTypeDecl({
    required super.typeName,
    required super.message,
    this.fieldPath,
  });

  @override
  String toString() => fieldPath == null
      ? 'InvalidNodeTypeDecl($typeName): $message'
      : 'InvalidNodeTypeDecl($typeName).$fieldPath: $message';
}

/// A fresh proposal (no `supersedes`) collided with an already-registered
/// type name.
final class NodeTypeAlreadyExists extends NodeTypeRegistrationException {
  const NodeTypeAlreadyExists({required super.typeName, required super.message});
}

/// The proposal sets `supersedes` but no predecessor is registered
/// under [typeName], or the registered decl-node id does not match
/// the value in `supersedes`.
final class NodeTypeNotFound extends NodeTypeRegistrationException {
  /// The decl-node id the proposal said it was superseding.
  final String supersedesDeclNodeId;

  /// The decl-node id the registry actually has for [typeName], when
  /// the type exists but the predecessor reference is stale. `null`
  /// when no row exists for [typeName] at all.
  final String? registeredDeclNodeId;

  const NodeTypeNotFound({
    required super.typeName,
    required super.message,
    required this.supersedesDeclNodeId,
    this.registeredDeclNodeId,
  });
}

/// The proposal sets `supersedes` and the predecessor exists, but the
/// new version is not strictly greater than the predecessor's.
final class NodeTypeVersionNotMonotonic extends NodeTypeRegistrationException {
  /// Version the existing decl is at.
  final int existingVersion;

  /// Version the proposal carried.
  final int proposedVersion;

  const NodeTypeVersionNotMonotonic({
    required super.typeName,
    required super.message,
    required this.existingVersion,
    required this.proposedVersion,
  });
}

/// The caller-supplied `CritiqueHook` returned `CritiqueRejected` (or
/// crashed; a crash is normalised into this exception with the
/// crash message preserved in [reason]).
final class NodeTypeRejected extends NodeTypeRegistrationException {
  /// Verbatim reason from the hook.
  final String reason;

  /// Names of existing types the hook flagged as overlapping; empty
  /// when the rejection was not about overlap.
  final List<String> conflictingTypeNames;

  const NodeTypeRejected({
    required super.typeName,
    required super.message,
    required this.reason,
    this.conflictingTypeNames = const <String>[],
  });
}
