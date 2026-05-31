// Barrel for the `router/` module (B.18 onwards).
//
// `substrate_specification.md` § 5 (provider routing). At B.18 the
// module surface is:
//
//   * [LlmRouter] — role-keyed dispatch with failover classification
//     and per-credential cooldown.
//   * [LlmFailureClassifier] + [LlmFailureClass] + [LlmRouterAction] —
//     the closed taxonomy from spec § 5.4 plus its routing actions.
//   * [RouteEntry] + [RouteConditions] — the per-row value class that
//     a role's `routeChain` is built from. B.19's `RouterPolicy`
//     formalises the role → chain mapping; B.18 takes the map directly.
//   * [NoRouteAvailable], [RoleNotFound], [ContextOverflowError],
//     [RouteAttempt] — typed router errors.
//
// Re-exported from the top-level package barrel (`lib/tom_brain_substrate.dart`)
// so consumers and downstream tests can bind against the router without a
// `package:tom_brain_substrate/src/...` deep-import.

export 'llm_failure_classifier.dart';
export 'llm_router.dart';
export 'route_entry.dart';
export 'router_errors.dart';
