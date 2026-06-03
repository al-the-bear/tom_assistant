// ResolvedIdentity — the minimal, opaque principal handle the dispatcher
// threads into the memory `Scope` (Plan step D.11; def § 1.5; proto spec
// § 10.1).
//
// What this file owns:
//
//   * The `ResolvedIdentity` value type — a thin handle naming the
//     resolved principal, declared so the dispatcher can pass an identity
//     into memory's scope without depending on `tom_core_kernel`.
//
// Why a *minimal* handle (not a `TomPrincipal` wrapper):
//
//   D.4 calls this "a thin wrapper over the tom_core_kernel identity
//   primitives", but `tom_brain_shared` is the pure-types layer and may
//   depend only on `tom_basics` (A.9 dependency discipline). It therefore
//   cannot import `tom_core_kernel`. The shared shape is the *minimal*
//   identity the dispatcher reads — a stable principal id plus optional
//   display name and opaque claims. Phase E's `IdentityResolver` (E.24)
//   produces this from a real `TomPrincipal`; the rich authorization
//   context stays on the kernel side. The dispatcher treats this handle
//   opaquely (it reads only [principalId] for the memory scope) — Q-D.11.3.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show mapEquals, requireNonEmpty;

/// The resolved principal behind an inbound request, in the minimal shape
/// the dispatcher needs. Carried on [Access] so the run / persist path can
/// scope memory writes to the right principal.
///
/// Immutable value object. Phase E's `IdentityResolver` builds it from a
/// `tom_core_kernel` `TomPrincipal`; the dispatcher reads only
/// [principalId] and otherwise treats it as opaque.
final class ResolvedIdentity {
  /// Stable principal identifier. Non-empty — an empty principal id would
  /// silently scope writes to nothing and is almost always an
  /// uninitialised field. The dispatcher passes this into the memory
  /// `Scope` for idempotency / attribution.
  final String principalId;

  /// Optional human-readable name for logs / persona enrichment. Never
  /// load-bearing for authorization.
  final String? displayName;

  /// Opaque, kernel-sourced claims (roles, scopes, quota refs) the
  /// dispatcher does not interpret. Stored unmodifiable so a downstream
  /// consumer cannot grow an in-memory identity's privileges. Defaults to
  /// an empty map.
  final Map<String, Object?> claims;

  /// Builds an immutable resolved identity. [principalId] must be
  /// non-empty.
  ResolvedIdentity({
    required this.principalId,
    this.displayName,
    Map<String, Object?> claims = const {},
  }) : claims = Map.unmodifiable(claims) {
    requireNonEmpty(principalId, 'principalId');
  }

  @override
  bool operator ==(Object other) =>
      other is ResolvedIdentity &&
      other.principalId == principalId &&
      other.displayName == displayName &&
      mapEquals(other.claims, claims);

  @override
  int get hashCode => Object.hash(
        principalId,
        displayName,
        Object.hashAllUnordered(claims.keys),
      );

  @override
  String toString() => 'ResolvedIdentity('
      'principalId: $principalId, '
      'displayName: $displayName, '
      'claims: $claims)';
}
