// B.18 — Typed errors raised by [LlmRouter].
//
// Three errors are first-class for the router:
//
//   * [NoRouteAvailable] — no route entry in the role's chain survived
//     the filter step (cooldown, conditions, credential availability)
//     OR the chain was exhausted by failover with no route succeeding.
//     Carries an audit trail (per spec § 5.1) so the consumer can see
//     which entries were tried, why each was skipped, and which class
//     each provider's failure mapped to.
//
//   * [RoleNotFound] — the caller submitted a `roleId` that is not in
//     the role-route map. Distinct from `NoRouteAvailable`: a missing
//     role is a config / caller error, not a runtime exhaustion.
//
//   * [ContextOverflowError] — surfaced to the caller when a provider
//     reports `context_overflow` (spec § 5.4 row). Per the spec the
//     substrate does not silently compact; the caller (a procedure /
//     dispatcher) decides whether to retry against a smaller prompt.
//
// All three are `Exception` (not `Error`) — they are runtime conditions
// the consumer is allowed to handle, not contract violations the
// program should crash on.

import 'llm_failure_classifier.dart' show LlmFailureClass;

/// Trail entry for one [LlmRouter] route-chain attempt.
///
/// Carried on [NoRouteAvailable] so the caller / observer can see why
/// each entry in the chain was not the one that answered. Also surfaces
/// in `SubstrateEvent.RouterDecision` (B.32+) for the trail.
final class RouteAttempt {
  /// `providerId:model` of the route this attempt targeted.
  final String routeKey;

  /// Outcome of the attempt.
  ///
  ///   * `skipped:cooldown:<classCode>` — the route was parked under a
  ///     cooldown window for the named class at the time of the attempt.
  ///   * `skipped:no_provider` — `providerId` was not registered with
  ///     the router (config drift). Rare; surfaces as a single audit
  ///     line so the chain still finishes its survey.
  ///   * `skipped:conditions` — the route's [RouteConditions] excluded
  ///     the call (e.g. `maxInputTokens` exceeded).
  ///   * `failed:<classCode>:<message>` — the route was attempted, the
  ///     provider raised, and the classifier mapped the exception onto
  ///     `<classCode>`. `<message>` is a one-line summary of the
  ///     underlying exception.
  ///   * `succeeded` — the route returned a report. Only the last
  ///     attempt in the trail will carry this when [NoRouteAvailable]
  ///     is thrown.
  final String outcome;

  /// Number of in-route retries the router burned on this entry before
  /// rotating or succeeding. 0 ⇒ a single attempt was made.
  final int retries;

  /// The class the router decided this attempt belonged to. `null` when
  /// the attempt was skipped before contact (cooldown, conditions, no
  /// provider).
  final LlmFailureClass? classification;

  const RouteAttempt({
    required this.routeKey,
    required this.outcome,
    required this.retries,
    this.classification,
  });

  @override
  String toString() => 'RouteAttempt($routeKey, $outcome, retries=$retries)';
}

/// No route in the role's chain produced a report.
///
/// Two distinct causes converge on this exception (the [attempts] trail
/// distinguishes them):
///
///   * Every entry was filtered out (cooldown / conditions / no
///     provider). [attempts] contains only `skipped:*` outcomes.
///   * Every entry was attempted and every attempt failed. [attempts]
///     contains the per-class failure record.
class NoRouteAvailable implements Exception {
  /// Role whose chain was exhausted.
  final String roleId;

  /// Trail of attempts in chain order. Per [RouteAttempt] documentation,
  /// the last entry can be a successful one only when this exception is
  /// re-thrown by a consumer that itself raised — the router never
  /// throws [NoRouteAvailable] on a successful attempt.
  final List<RouteAttempt> attempts;

  /// Optional last-classification handle. Set when at least one entry
  /// was attempted; `null` when every entry was filter-skipped.
  final LlmFailureClass? lastClass;

  const NoRouteAvailable({
    required this.roleId,
    required this.attempts,
    this.lastClass,
  });

  @override
  String toString() {
    final tail = attempts.isEmpty
        ? 'no entries in chain'
        : attempts.map((a) => a.toString()).join(' | ');
    return 'NoRouteAvailable(role=$roleId, lastClass=${lastClass?.code}, '
        'attempts=[$tail])';
  }
}

/// The role-route map does not contain [roleId].
///
/// A missing role is a config / caller error, not a runtime exhaustion;
/// distinct from [NoRouteAvailable] so the consumer can branch on the
/// difference.
class RoleNotFound implements Exception {
  final String roleId;

  const RoleNotFound(this.roleId);

  @override
  String toString() => 'RoleNotFound($roleId)';
}

/// A caller dispatched over an *explicit* route chain (the
/// `dispatchOverChain` / `dispatchStreamOverChain` path, used by the
/// cognition-config `llm:` routing) but the chain was empty.
///
/// Distinct from [NoRouteAvailable] (a non-empty chain that exhausted) and
/// from [RoleNotFound] (role-keyed routing with no entry): an empty explicit
/// chain is a config / caller error — a route name resolved to zero entries.
class EmptyRouteChain implements Exception {
  /// Role whose persona/anchor assembled the prompt (provenance only; it did
  /// not select the chain).
  final String roleId;

  const EmptyRouteChain(this.roleId);

  @override
  String toString() => 'EmptyRouteChain(role=$roleId)';
}

/// Provider reported `context_overflow` (spec § 5.4). Surfaced verbatim;
/// substrate does not silently compact role prompts.
class ContextOverflowError implements Exception {
  final String roleId;
  final String providerId;
  final String modelId;
  final String message;
  final Object? cause;

  const ContextOverflowError({
    required this.roleId,
    required this.providerId,
    required this.modelId,
    required this.message,
    this.cause,
  });

  @override
  String toString() => 'ContextOverflowError(role=$roleId, '
      'provider=$providerId, model=$modelId): $message';
}
