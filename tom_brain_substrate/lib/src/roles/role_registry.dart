// B.22 — `RoleRegistry`.
//
// Plan-step text (verbatim):
//   "B.22 Implement template registry with at least these roles for the
//    prototype: `assistant_to_user`, `analyser`, `sub_thinker`,
//    `recaller`, `evaluator`."
//
// `substrate_specification.md` § 6.1 / § 6.2 frame the registry as the
// single authority that holds `RoleTemplate` instances and hands them
// out to every downstream consumer (the router's per-role dispatch path,
// the dispatcher's `allowedActions` gate, the trail attribution layer).
// "Adding a sixth role is a config change (template + registry entry);
// no code change." — i.e. the registry's roster is data, not a switch.
//
// B.22 scope (this file + `bootstrap_roles.dart`):
//
//   * `RoleRegistry` — the holder. Constructor takes a list of
//     `RoleTemplate`; rejects duplicate ids; freezes the internal map;
//     exposes lookup APIs (`get`, `lookup`, `contains`, `ids`,
//     `templates`, `length`).
//   * `RoleTemplateNotFound` — the typed exception thrown by `get(id)`
//     when the id is not registered. Carries the requested id and the
//     known ids for diagnostics.
//   * `bootstrap_roles.dart` — the five prototype roles assembled in
//     code (see file header for the rationale on in-memory bootstrap
//     vs. file-backed loading at this step).
//
// What this file deliberately does NOT own:
//
//   * File-backed template loading. The spec's § 6.1 line —
//     "Templates live under `<workspace>/_ai/prompts/<role>.system.md`.
//     The registry loads them at `open()`" — describes the *eventual*
//     load path. The prototype five roles are inline in
//     `bootstrap_roles.dart` (see Q-B.22.1 / Q-B.22.2 for the deferred-
//     loader decision). Adding a file-backed `RoleRegistry.openFromDisk
//     (Directory)` factory later does not change this file's API.
//
//   * The `templateRef` / git sha field on `RoleTemplate`. The B.21
//     header documents the deferral to B.22; at B.22 we still defer,
//     because templateRef is meaningful only when templates are loaded
//     from versioned files. Bootstrap-only roles have no sha to
//     attribute. See Q-B.22.3.
//
//   * The `assemble(...)` method that produces a `WirePrompt`. Lives
//     at B.23 with the anchor-injection enforcement test.
//
//   * The dispatcher-side gate. Lives in Phase D
//     (`tom_brain_procedure_dispatcher`); the registry only exposes the
//     `RoleTemplate` data; gate enforcement is a separate concern.
//
//   * The router's per-role chain resolution. Lives at
//     `lib/src/router/llm_router.dart` (B.18+); the router holds its
//     own `roleRoutes` map keyed by the same role id strings the
//     registry uses. The registry and the router are two independent
//     data stores; consistency between them (every routed role id has a
//     registered template) is a future cross-validation step (Q-B.22.4).
//
// Why a dedicated `RoleTemplateNotFound` rather than reusing
// `RoleNotFound` from `router_errors.dart`:
//
//   * `RoleNotFound` is router-level: "the role-route map does not
//     contain this id" — a routing concern. The registry's miss is
//     a templates concern: "no template was registered under this id."
//     The two errors arise at different layers, surface to different
//     callers, and carry different diagnostic shapes (the router's
//     also reports the route-chain context; the registry's reports the
//     known-id roster).
//   * The two errors can co-occur (a role registered with no router
//     chain) or independently (a routed role with no registered
//     template, the cross-validation case mentioned above). Conflating
//     them under one type would hide that distinction at catch sites.

import 'role_template.dart';

/// The substrate's authoritative holder of `RoleTemplate` instances.
///
/// Construction: pass a list of `RoleTemplate` values; the registry
/// stores them in an internal map keyed by `RoleTemplate.id` and
/// rejects any duplicate id at construction with [ArgumentError].
///
/// Lookup: [get] throws [RoleTemplateNotFound] on a miss (the
/// caller wanted a template and the registry promises one); [lookup]
/// returns `null` on a miss (the caller is probing).
///
/// Immutability: the internal map is frozen at construction
/// (`Map.unmodifiable`); every external view ([templates], [ids])
/// derives from that frozen map. The registry does not expose a
/// `register(...)` method — adding a role is a re-construction step,
/// not an in-place mutation. Rationale: the spec line "Adding a sixth
/// role is a config change (template + registry entry); no code
/// change" implies a config-load cycle, not a runtime mutation
/// surface. Keeping the registry immutable matches that posture and
/// removes a class of race conditions when the registry is read by
/// multiple isolates (the procedure dispatcher and the router run in
/// different isolates per the substrate isolation model).
///
/// Value-class equality is intentionally not defined on `RoleRegistry`
/// — two registries with the same roster are operationally identical,
/// but the registry is a service-shaped object (constructed once,
/// passed around, looked up many times), not a value to compare. If
/// equality is later needed (e.g. for a config-reload test that asserts
/// "reloaded registry equals previous"), it can be added without
/// breaking consumers.
final class RoleRegistry {
  final Map<String, RoleTemplate> _byId;

  /// Constructs a registry from a list of [templates].
  ///
  /// Validation:
  ///   * Duplicate ids are rejected with [ArgumentError]. The first
  ///     occurrence wins on no axis — the error is raised at
  ///     construction so the loader cannot pick a "silent winner".
  ///   * An empty [templates] list is permitted but produces a
  ///     registry whose `get` always misses; callers that want the
  ///     prototype five roles use [RoleRegistry.bootstrap] (in
  ///     `bootstrap_roles.dart`).
  ///
  /// The internal map is wrapped in [Map.unmodifiable] so a consumer
  /// that holds a reference to [ids] / [templates] cannot mutate the
  /// registry's view by accident.
  factory RoleRegistry({required List<RoleTemplate> templates}) {
    final byId = <String, RoleTemplate>{};
    for (final t in templates) {
      if (byId.containsKey(t.id)) {
        throw ArgumentError.value(
          t.id,
          'templates',
          'duplicate role id "${t.id}" — registry rejects duplicates so the '
              'loader cannot pick a silent winner',
        );
      }
      byId[t.id] = t;
    }
    return RoleRegistry._(Map<String, RoleTemplate>.unmodifiable(byId));
  }

  const RoleRegistry._(this._byId);

  /// Returns the template registered under [id], or throws
  /// [RoleTemplateNotFound] if no such template exists.
  ///
  /// Use this when the caller has a hard requirement that the template
  /// be present (the router's dispatch path, the dispatcher's gate).
  /// For probing use [lookup] instead.
  RoleTemplate get(String id) {
    final t = _byId[id];
    if (t == null) {
      throw RoleTemplateNotFound(id: id, knownIds: _byId.keys.toList());
    }
    return t;
  }

  /// Returns the template registered under [id], or `null` if no such
  /// template exists.
  ///
  /// Use this when the caller is *probing* (e.g. a config validator
  /// that checks whether every routed role has a registered template).
  /// For hard requirements use [get] instead — the typed exception
  /// surfaces diagnostic context the `null` return would not.
  RoleTemplate? lookup(String id) => _byId[id];

  /// True when a template is registered under [id].
  ///
  /// Convenience for predicate use sites; equivalent to
  /// `lookup(id) != null` without binding the returned template.
  bool contains(String id) => _byId.containsKey(id);

  /// The registered role ids, in insertion order (i.e. the order they
  /// were supplied to the constructor).
  ///
  /// Iteration is stable across calls because the underlying map is a
  /// `LinkedHashMap` (the Dart default), and the unmodifiable wrapper
  /// preserves the iteration order of the source map.
  Iterable<String> get ids => _byId.keys;

  /// The registered templates, in insertion order.
  Iterable<RoleTemplate> get templates => _byId.values;

  /// The number of registered templates.
  int get length => _byId.length;
}

/// Thrown by [RoleRegistry.get] when the requested role id is not
/// registered.
///
/// Carries the requested [id] and the registry's current [knownIds]
/// roster so a catch site can produce a diagnostic like:
///
/// ```
/// RoleTemplateNotFound(id="planner", known=[assistant_to_user, analyser,
/// sub_thinker, recaller, evaluator])
/// ```
///
/// Why a registry-specific error type (not a reuse of
/// `RoleNotFound` from `router_errors.dart`): see this file's header.
/// The two errors arise at different layers and carry different
/// diagnostic context.
class RoleTemplateNotFound implements Exception {
  /// The role id the caller requested.
  final String id;

  /// The ids currently registered, in insertion order. A snapshot —
  /// the registry's iteration is stable, so this list is safe to keep.
  final List<String> knownIds;

  const RoleTemplateNotFound({required this.id, required this.knownIds});

  @override
  String toString() => 'RoleTemplateNotFound(id="$id", known=$knownIds)';
}
