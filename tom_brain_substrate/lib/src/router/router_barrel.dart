// Barrel for the `router/` module (B.18 onwards).
//
// `substrate_specification.md` § 5 (provider routing). At B.19 the
// module surface is:
//
//   * [LlmRouter] — role-keyed dispatch with failover classification
//     and per-credential cooldown. Consumes a [RouterPolicy] + provider
//     registry on construction.
//   * [RouterPolicy] — immutable router config (role → chain map,
//     per-class cooldown durations, in-route retry budget,
//     overloaded-backoff window). B.36's YAML loader produces it.
//   * [LlmFailureClassifier] + [LlmFailureClass] + [LlmRouterAction] —
//     the closed taxonomy from spec § 5.4 plus its routing actions.
//   * [StrictFormatAdapter] — the `format`-class re-emit transform
//     (spec § 5.4 / Q-B.43.2); the router applies it on the single
//     `reformatThenRotate` re-emit.
//   * [RouteEntry] + [RouteConditions] — the per-row value class that
//     a role's `routeChain` is built from; [RouterPolicy.roleRoutes]
//     composes them per role.
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
export 'router_policy.dart';
export 'strict_format_adapter.dart';
