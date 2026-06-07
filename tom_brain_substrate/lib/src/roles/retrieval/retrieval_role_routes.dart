// Plan Extension-H step #29 — default `roleRoutes` for the retrieval roles.
//
// § 6.2a: "The roles default to a small/cheap route in `roleRoutes`
// (retrieval is high-fan-out, so per-seed LLM cost matters); the route is
// config, overridable per deployment."
//
// Retrieval is high-fan-out: a single prompt can spawn a recall_planner
// call, several hypothesis_writer calls (one per planned question), a
// query_term_writer call, a category_selector call, and a
// retrieval_reranker call — before the answer loop even starts. Per-seed
// LLM cost therefore dominates, so every retrieval role defaults to the
// *same* cheap route the caller names. A deployment that wants a stronger
// model for, say, `category_selector` overrides that one role's chain in
// its `SubstrateConfig.roleRoutes`; this map is only the default.
//
// This file produces *config* (a `Map<String, List<RouteEntry>>` ready to
// drop into `RouterPolicy.roleRoutes`), not router behaviour. Adding the
// retrieval roles is config-only — no `LlmRouter` / `RouterPolicy` change
// (the Verify clause's "no engine change").

import '../../router/route_entry.dart';
import 'retrieval_roles.dart' show retrievalRoleIds;

/// Builds the default `roleRoutes` entries for the six retrieval roles,
/// each a single-entry chain pointing at the caller-named cheap route.
///
/// The result is keyed by [retrievalRoleIds] and is ready to merge into a
/// [RouterPolicy]'s `roleRoutes` map (e.g.
/// `RouterPolicy(roleRoutes: {...thinkingRoutes, ...defaultRetrievalRoleRoutes(...)})`).
///
/// [providerId] / [model] name the small/cheap route every retrieval role
/// defaults to (e.g. `ollama` + `gemma3:4b`). A deployment overrides any
/// single role by supplying its own chain for that role id downstream of
/// this default.
Map<String, List<RouteEntry>> defaultRetrievalRoleRoutes({
  required String providerId,
  required String model,
}) {
  final cheap = RouteEntry(providerId: providerId, model: model);
  return <String, List<RouteEntry>>{
    for (final id in retrievalRoleIds) id: <RouteEntry>[cheap],
  };
}
