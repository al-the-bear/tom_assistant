// B.18 — `RouteEntry`: one row of a role's `routeChain` (spec § 5.1).
//
// At B.18 the router consumes an ordered `List<RouteEntry>` per role. B.19
// formalises a top-level `RouterPolicy` config object that owns the role →
// chain map plus the cooldown / retry tunables; this file lands the
// row-level value class B.19 will compose.
//
// Spec § 5.1 names a `RouteEntry` with `providerId`, `model`, `authProfile`,
// `conditions?`. For B.18 only `providerId` + `model` are first-class
// (the prototype `auth.method == api_key | none` is per-provider config,
// not per-route); `conditions` is included as an optional value object so
// the router's filter step exists in the code shape even when no entries
// declare conditions.
//
// "Free-tier rotation" vs "paid-tier opt-in" (plan step B.18) reduces to
// *ordering* of `RouteEntry` rows inside a role's chain — spec § 5.3:
//
//   > Tier escalation (free → free → paid → local-fallback) is expressed
//   > by *profile ordering* inside `routeChain`, not by separate logic.
//   > The router does not know "free" vs "paid"; it knows "ordered list,
//   > try each".
//
// The router therefore does not need a `tier` field on [RouteEntry]; the
// ordering is the policy. A free-tier credential that hits `rate_limit`
// goes into cooldown and the router moves to the next entry, which by
// configuration is either another free-tier credential, a paid-tier
// credential, or a local fallback. Per spec § 1 invariant 4 the consumer
// cannot observe which tier produced the answer.

/// Optional per-entry preconditions. Skipped when none are declared.
///
/// At B.18 only [maxInputTokens] is wired; the router compares it against
/// the caller-supplied `inputTokensHint` (defaults to `null`, which skips
/// the filter). Other condition shapes (e.g. region pinning, model-flag
/// gating) land in later steps as configuration grows.
final class RouteConditions {
  /// Skip this entry when the caller's prompt is estimated to exceed
  /// [maxInputTokens] input tokens. `null` ⇒ no upper bound.
  final int? maxInputTokens;

  const RouteConditions({this.maxInputTokens});

  static const RouteConditions empty = RouteConditions();
}

/// One row of a role's `routeChain` (spec § 5.1).
///
/// Constructed from `SubstrateConfig.roleRoutes[roleId]` (spec § 9). B.19
/// will land the loader; B.18 takes a pre-built list per role.
final class RouteEntry {
  /// Key into [LlmRouter.providers]. Must match an `LlmProvider.id`.
  final String providerId;

  /// Model id within the provider. Resolved onto [LlmOptions.model] when
  /// the caller did not override; otherwise the router enforces that the
  /// route exposes the caller's requested model (per
  /// `LlmOptions.model` doc, step 1 of the resolution order).
  final String model;

  /// Optional per-entry filter. Defaults to [RouteConditions.empty].
  final RouteConditions conditions;

  const RouteEntry({
    required this.providerId,
    required this.model,
    this.conditions = RouteConditions.empty,
  });

  @override
  String toString() => 'RouteEntry($providerId, $model)';
}
