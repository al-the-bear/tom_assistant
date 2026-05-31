// B.19 — `RouterPolicy`: the named-value config object the router consumes.
//
// `substrate_specification.md` § 5 names the fields the router has to consult
// to make a routing decision:
//
//   * § 5.1 — the role → ordered `routeChain` map.
//   * § 5.3 — tier escalation expressed *by chain ordering*, not by a `tier`
//     field; no policy field beyond the chain itself is needed.
//   * § 5.4 — per-class cooldown durations and in-route retry counts.
//
// B.18 took these fields on the `LlmRouter` constructor directly so the
// chain-walk / classifier / cooldown machinery could land without also
// inventing the config shape. B.19 promotes the bag-of-parameters into a
// named, immutable value class — for three reasons:
//
//   1. **One config object, one schema.** B.36 lands the YAML loader for
//      the broader `SubstrateConfig`; that loader produces a `RouterPolicy`
//      as its router-shaped subsection. With B.18's bag-of-parameters the
//      loader would have to thread four positional kwargs through the
//      `LlmRouter` constructor; with `RouterPolicy` it produces one value
//      and the router consumes one value.
//
//   2. **Reload-safe shape.** Spec § 9 says reload-on-SIGHUP is out of
//      scope for the prototype, but a `RouterPolicy` value can still be
//      *replaced* on a substrate restart by passing a freshly-loaded
//      policy. Keeping policy immutable + carried as one object means the
//      "restart with new config" path is one swap, not four field updates
//      (and avoids the question "what if half the fields swap and half
//      don't?").
//
//   3. **Test ergonomics.** Tests that exercise a non-default cooldown
//      schedule or retry budget can construct one `RouterPolicy` once and
//      reuse it; B.18's tests build the same shape inline at every
//      `LlmRouter(...)` construction. The `RouterPolicy.copyWith(...)`
//      method makes "default policy with one knob nudged" a one-liner.
//
// What this file does NOT do:
//
//   * No YAML / JSON parsing. Deferred to B.36 (`SubstrateConfig` loader).
//     `RouterPolicy` is a pure value class; the loader produces it.
//   * No tier classification. Spec § 5.3 — ordering IS the tier policy. A
//     `tier` field on `RouterPolicy` or on `RouteEntry` would invite
//     "the router classifies free vs paid", which the spec explicitly
//     forbids.
//   * No provider registry. Providers are runtime objects (they hold
//     `HttpClient` state, credentials, host connections); they live on
//     the `LlmRouter` constructor alongside the policy. Mixing them into
//     `RouterPolicy` would make the policy non-pure-data and break the
//     YAML-loadable invariant.
//   * No clock / random / test seams. Those stay on the router
//     constructor where they belong — they are not config.

import 'llm_failure_classifier.dart' show LlmFailureClass;
import 'route_entry.dart' show RouteEntry;

/// Immutable router configuration consumed by [LlmRouter.fromPolicy].
///
/// One instance per substrate process; rebuilt only on substrate restart
/// (the prototype does not support SIGHUP-reload — see spec § 9).
///
/// Fields:
///
///   * [roleRoutes] — role → ordered chain of [RouteEntry]. The router
///     walks the chain in order on every dispatch; the first entry that
///     survives the filter step is the one that runs.
///   * [cooldownByClass] — per-[LlmFailureClass] cooldown window. A class
///     that is missing from this map is treated as zero-cooldown (the
///     router will retry-or-rotate without parking the route).
///   * [retriesPerClass] — number of in-route retries the router takes
///     before rotating to the next entry, for failure classes whose
///     [LlmFailureClass.routerAction] is `retryThenRotate`. Default `1`.
///   * [overloadedBackoff] — base for the jittered backoff inserted
///     between an `overloaded` failure and its retry. Drawn uniformly
///     from `[0, overloadedBackoff]`. Default 50 ms; tests pin it to
///     [Duration.zero].
///
/// Construction validates:
///
///   * [retriesPerClass] is non-negative.
///   * [overloadedBackoff] is non-negative.
///   * Every duration in [cooldownByClass] is non-negative.
///   * Every chain in [roleRoutes] is non-null (an empty chain is
///     allowed — it produces a `NoRouteAvailable` on the first dispatch,
///     which is the operationally correct surface for "the role is
///     declared but has no providers configured yet").
///
/// The constructor wraps both maps + every chain list in unmodifiable
/// views so consumers cannot mutate the policy through a returned
/// reference.
final class RouterPolicy {
  /// Role → ordered chain. The router walks `roleRoutes[roleId]` on
  /// every dispatch; an unknown role surfaces as `RoleNotFound`.
  final Map<String, List<RouteEntry>> roleRoutes;

  /// Per-class cooldown window. Missing classes ⇒ zero cooldown.
  final Map<LlmFailureClass, Duration> cooldownByClass;

  /// Number of in-route retries for `retryThenRotate` classes.
  final int retriesPerClass;

  /// Base for jittered overloaded-class backoff.
  final Duration overloadedBackoff;

  /// Default cooldown schedule (spec § 5.3 defaults).
  ///
  /// `rate_limit` cools 60 s; `billing` cools 24 h; `auth`,
  /// `auth_permanent`, and `model_not_found` are effectively permanent
  /// (365 d) — reconfiguring a credential or replacing a model id is a
  /// substrate restart. Every other class is absent ⇒ zero cooldown,
  /// handled by retry instead of cooldown.
  static const Map<LlmFailureClass, Duration> defaultCooldowns =
      <LlmFailureClass, Duration>{
    LlmFailureClass.rateLimit: Duration(seconds: 60),
    LlmFailureClass.billing: Duration(hours: 24),
    LlmFailureClass.auth: Duration(days: 365),
    LlmFailureClass.authPermanent: Duration(days: 365),
    LlmFailureClass.modelNotFound: Duration(days: 365),
  };

  /// Default in-route retry count for `retryThenRotate` classes.
  static const int defaultRetriesPerClass = 1;

  /// Default jittered backoff window for `overloaded` retries.
  static const Duration defaultOverloadedBackoff = Duration(milliseconds: 50);

  /// Constructs a policy from raw fields.
  ///
  /// Throws [ArgumentError] when [retriesPerClass] is negative, when
  /// [overloadedBackoff] is negative, or when any duration in
  /// [cooldownByClass] is negative.
  RouterPolicy({
    required Map<String, List<RouteEntry>> roleRoutes,
    Map<LlmFailureClass, Duration>? cooldownByClass,
    this.retriesPerClass = defaultRetriesPerClass,
    this.overloadedBackoff = defaultOverloadedBackoff,
  })  : roleRoutes = _freezeRoleRoutes(roleRoutes),
        cooldownByClass = _freezeCooldowns(
          cooldownByClass ?? defaultCooldowns,
        ) {
    if (retriesPerClass < 0) {
      throw ArgumentError.value(
        retriesPerClass,
        'retriesPerClass',
        'must be non-negative',
      );
    }
    if (overloadedBackoff.isNegative) {
      throw ArgumentError.value(
        overloadedBackoff,
        'overloadedBackoff',
        'must be non-negative',
      );
    }
  }

  /// Empty-policy convenience. Every dispatch will produce `RoleNotFound`.
  /// Useful as a starting point that `copyWith` then customises.
  static final RouterPolicy empty = RouterPolicy(
    roleRoutes: const <String, List<RouteEntry>>{},
  );

  /// Returns the chain for [roleId] or `null` when the role is absent.
  ///
  /// Mirrors `Map.[]` shape so callers can treat the policy as a
  /// read-only lookup without exposing the underlying map.
  List<RouteEntry>? routesFor(String roleId) => roleRoutes[roleId];

  /// Returns the cooldown window for [cls]. Falls back to
  /// [Duration.zero] when no entry is configured (the router treats
  /// zero as "no cooldown, handled by retry").
  Duration cooldownFor(LlmFailureClass cls) =>
      cooldownByClass[cls] ?? Duration.zero;

  /// Returns a copy of this policy with the named fields replaced.
  ///
  /// Pass an empty map to clear all cooldowns; pass `null` to leave the
  /// existing map untouched. Same convention for [roleRoutes].
  RouterPolicy copyWith({
    Map<String, List<RouteEntry>>? roleRoutes,
    Map<LlmFailureClass, Duration>? cooldownByClass,
    int? retriesPerClass,
    Duration? overloadedBackoff,
  }) {
    return RouterPolicy(
      roleRoutes: roleRoutes ?? this.roleRoutes,
      cooldownByClass: cooldownByClass ?? this.cooldownByClass,
      retriesPerClass: retriesPerClass ?? this.retriesPerClass,
      overloadedBackoff: overloadedBackoff ?? this.overloadedBackoff,
    );
  }

  /// Returns a copy with [routes] added or replaced for [roleId].
  ///
  /// `withRole('analyser', [...])` is the common construction pattern
  /// when assembling a policy from scratch; equivalent to
  /// `copyWith(roleRoutes: {...current, roleId: routes})` but cheaper
  /// to read at the call site.
  RouterPolicy withRole(String roleId, List<RouteEntry> routes) {
    final next = <String, List<RouteEntry>>{
      ...roleRoutes,
      roleId: routes,
    };
    return copyWith(roleRoutes: next);
  }

  @override
  String toString() => 'RouterPolicy('
      'roles=${roleRoutes.keys.toList()}, '
      'cooldowns=${cooldownByClass.length}, '
      'retries=$retriesPerClass, '
      'overloadedBackoff=${overloadedBackoff.inMilliseconds}ms)';

  static Map<String, List<RouteEntry>> _freezeRoleRoutes(
    Map<String, List<RouteEntry>> source,
  ) {
    final frozen = <String, List<RouteEntry>>{};
    for (final entry in source.entries) {
      frozen[entry.key] = List<RouteEntry>.unmodifiable(entry.value);
    }
    return Map<String, List<RouteEntry>>.unmodifiable(frozen);
  }

  static Map<LlmFailureClass, Duration> _freezeCooldowns(
    Map<LlmFailureClass, Duration> source,
  ) {
    for (final entry in source.entries) {
      if (entry.value.isNegative) {
        throw ArgumentError.value(
          entry.value,
          'cooldownByClass[${entry.key.code}]',
          'must be non-negative',
        );
      }
    }
    return Map<LlmFailureClass, Duration>.unmodifiable(source);
  }
}
