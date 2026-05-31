// AgentScopeViolation — exception raised by `AgentRegistry` when a
// write fails the read/write scope check from spec § 9.5 (Plan step
// A.70).
//
// Sibling of `WriteBudgetExceeded`: both are recoverable memory-write
// rejections that the dispatcher catches at the bridged-API boundary
// (`procedure_specification.md` § 13) and converts to a typed
// procedure outcome so the procedure can decide whether to ask the
// procedure_author role for an updated scope grant, defer the write,
// or fail the run.
//
// Why this is an `Exception` and not an `Error`:
//
//   * The dispatcher recovers from scope violations by re-planning
//     (Section 9.5 of the spec frames the registry as the
//     enforcement seam, not as a programmer-time invariant). The
//     same reasoning that puts `WriteBudgetExceeded` in
//     `Exception` puts `AgentScopeViolation` there too.
//
// Why three distinct kinds:
//
//   * `agentNotRegistered` — the write named an `agentName` the
//     registry does not know about. Likely a stale procedure
//     declaration or a dispatcher bug.
//   * `writeScopeDenied`   — the agent is registered but its
//     `writeScopes` did not match the requested resource.
//   * `readScopeDenied`    — the agent is registered but its
//     `readScopes` did not match (read-side enforcement is reserved
//     for a future read path; the kind exists today so the
//     enforcement helper has a stable taxonomy when the read paths
//     wire in).

/// Reason an `AgentScopeViolation` fired. See file header for the
/// per-kind contract.
enum AgentScopeViolationKind {
  /// The named agent is not registered with the registry.
  agentNotRegistered,

  /// The registered agent's `writeScopes` denied the requested
  /// resource.
  writeScopeDenied,

  /// The registered agent's `readScopes` denied the requested
  /// resource. Reserved for future read enforcement.
  readScopeDenied,
}

/// Thrown by `AgentRegistry.guardWrite` / `guardRead` when the
/// scope check fails. Memory's `NodePersister`, `EdgeWriter`, and
/// `SqliteStackApi` invoke the guard *before* any side effects so a
/// violation leaves no row behind and emits no event.
final class AgentScopeViolation implements Exception {
  /// Which reason fired the violation.
  final AgentScopeViolationKind kind;

  /// The agent identity carried by `Scope.agentName`. Always
  /// non-null — the registry pass-through fires when `agentName`
  /// is null, so a violation can only reach this point with an
  /// agent name attached.
  final String agentName;

  /// Canonical scope tag the agent attempted to touch — same
  /// grammar `AgentRegistration.writeScopes` consumes (e.g.
  /// `"node:Procedure"`, `"edge:contradicts"`, `"stack:inflight"`).
  ///
  /// `null` only for `agentNotRegistered` — the registry has no
  /// scope to check against in that branch.
  final String? requestedScope;

  /// Snapshot of the registration's scope set the check ran
  /// against, for diagnostics. `null` for `agentNotRegistered`
  /// (there is no registration). For write/read denials the field
  /// reflects whichever side was being checked.
  final Set<String>? grantedScopes;

  /// Free-form human-readable message. The dispatcher logs this;
  /// the structured fields above carry the programmatic payload.
  final String message;

  AgentScopeViolation({
    required this.kind,
    required this.agentName,
    required this.message,
    this.requestedScope,
    this.grantedScopes,
  });

  @override
  String toString() {
    final scopeBit =
        requestedScope == null ? '' : ', requestedScope: $requestedScope';
    return 'AgentScopeViolation('
        'kind: ${kind.name}, '
        'agentName: $agentName'
        '$scopeBit): $message';
  }
}
