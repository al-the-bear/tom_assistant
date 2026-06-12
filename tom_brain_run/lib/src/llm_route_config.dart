// LlmRouteConfig — increment 4 of `prompt_configuration.md` (§8 *LLM
// configuration*, §8.1 *Realisation*).
//
// One named LLM route config, loaded from `cognition/llm/<name>.yaml`: an
// ordered failover/rotation chain of provider+model entries (first reachable
// wins, cooldown on failure). Prompts reference a route **by name** via their
// inherited `llm:` setting (§5.4); the engine (increment 5's `sub.send`) routes
// a completion over the named chain. The substrate's provider abstraction,
// `LlmRouter`, failover taxonomy and cooldowns are unchanged — only the config
// *surface* moved here from `substrate.roleRoutes` (keyed by role) to named
// files (keyed by name).
//
// The entry shape is the substrate's `RoleRouteEntryConfig` /
// `RouteConditionsConfig`, reused verbatim — there is exactly one route-entry
// value type in the workspace, and `tom_brain_run` already depends on
// `tom_brain_substrate`.

import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show RoleRouteEntryConfig;

/// One named LLM route config (`cognition/llm/<name>.yaml`).
///
/// The [route] list order is the rotation order, preserved verbatim from the
/// YAML `route:` sequence — the first reachable entry wins, with cooldown on
/// failure (the substrate `LlmRouter` policy is unchanged).
final class LlmRouteConfig {
  /// The route name (= the `llm/<name>.yaml` file stem, the value a prompt's
  /// `llm:` setting references).
  final String name;

  /// The ordered provider+model chain (rotation order; first reachable wins).
  final List<RoleRouteEntryConfig> route;

  /// Binds the named [route] chain.
  const LlmRouteConfig({required this.name, required this.route});
}

/// Thrown by `CognitionConfig.route` when a route name is not among the loaded
/// `cognition/llm/` route configs (§8.1 — fail fast).
class UnknownLlmRouteException implements Exception {
  /// The unresolved route name.
  final String routeName;

  /// Builds the exception for [routeName].
  const UnknownLlmRouteException(this.routeName);

  @override
  String toString() =>
      'UnknownLlmRouteException: no registered LLM route "$routeName".';
}
