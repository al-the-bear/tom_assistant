// AgentRegistry — in-process bookkeeping for the per-agent
// `AgentRegistration` set memory enforces against (Plan step A.70;
// spec § 9.5).
//
// What this file owns:
//
//   - The map `agentName -> AgentRegistration`. `register` seeds an
//     entry; `unregister` removes it. The map lives in process —
//     there is no persistence. Same lifetime model as
//     `WriteBudgetTracker`.
//   - The three `guard*` enforcement helpers consumed by
//     `NodePersister`, `EdgeWriter`, and `SqliteStackApi`. Each one
//     resolves the named agent and matches the requested resource
//     against the registration's `writeScopes`; on rejection it
//     throws `AgentScopeViolation` *before* any side effect runs.
//   - The opt-in pass-through pattern (mirrors `WriteBudgetTracker`):
//     a write whose `Scope.agentName` is null passes through
//     unchecked. This is deliberate — bootstrap writes (initial
//     node-type registration, bootstrap-stack installation) and
//     migration writes have no agent identity, and forcing them to
//     register a fake agent would muddy the layering.
//   - The closed taxonomy of violation reasons via
//     `AgentScopeViolationKind`. A write that names an unregistered
//     agent is `agentNotRegistered` — distinct from a registered
//     agent whose scopes do not match (`writeScopeDenied`). The
//     distinction matters because the dispatcher's recovery is
//     different: an unregistered agent is almost always a stale
//     procedure declaration; a denied scope is a genuine privilege
//     mismatch that may justify re-asking the procedure_author role.
//
// What this file does NOT own:
//
//   - The `AgentRegistration` value type. It lives in
//     `tom_brain_shared` because the dispatcher (Phase D) and the
//     procedure-author role (Phase E) populate / serialise it
//     without depending on memory.
//   - Producer attribution. The `producedBy` column is already
//     populated from `Scope.producer` by the write paths (A.67);
//     the registry adds scope enforcement on top, not attribution.
//   - WriteBudget enforcement. That's `WriteBudgetTracker`'s job;
//     the registry only carries the per-agent *default* budget the
//     dispatcher will hand to `beginRun`.
//   - Read enforcement on the existing read paths. v0 wires write
//     enforcement only (persist / edge / push). The `guardRead`
//     helper exists so the future read paths have a stable
//     enforcement seam, but no production caller invokes it today.
//
// Concurrency model:
//
//   - Single-isolate, same as `WriteBudgetTracker`. Each guard call
//     is a synchronous map lookup + a set lookup; Dart's
//     single-threaded event loop makes the read atomic by
//     construction. The isolate-bridged deployment (A.78+) keeps
//     the registry inside memory's isolate; cross-isolate writes
//     reach the guard via message passing, preserving the
//     single-check-per-call property.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AgentRegistration;

import 'agent_scope_violation.dart';

/// In-process bookkeeping for the agent-name → registration map.
///
/// One `AgentRegistry` per open memory store; held by the
/// higher-level `SqliteTomBrainMemory` (later phase-A step) and
/// consulted by `NodePersister`, `EdgeWriter`, and `SqliteStackApi`
/// on every write whose `Scope.agentName` is non-null.
///
/// The registry is **opt-in at the write site**: a write whose
/// `Scope.agentName` is null passes through unchecked. Spec § 9.5
/// frames bootstrap and migration writes as outside the agent
/// registry — they have no agent identity to enforce against, and
/// inventing one would lie about the call chain.
final class AgentRegistry {
  /// `agentName -> AgentRegistration`. Read on every guarded write;
  /// written on `register` / `unregister`.
  final Map<String, AgentRegistration> _byName =
      <String, AgentRegistration>{};

  /// Registers [registration] under its [AgentRegistration.agentName].
  ///
  /// A second call with the same agent name **replaces** the prior
  /// registration. This is treated as an honest reset (e.g. a
  /// procedure revision that broadens the scope set) rather than an
  /// error — the dispatcher is the single caller, and conflating it
  /// with a programmer mistake would force a register/unregister
  /// dance on every promotion. The previous registration is dropped
  /// silently.
  void register(AgentRegistration registration) {
    _byName[registration.agentName] = registration;
  }

  /// Removes the registration for [agentName]. Subsequent writes
  /// that carry the same name fail with
  /// `AgentScopeViolationKind.agentNotRegistered`.
  ///
  /// Unregistering an unknown agent is a no-op — same shape as
  /// `close()` on an already-closed resource.
  void unregister(String agentName) {
    _byName.remove(agentName);
  }

  /// Returns the registration for [agentName], or `null` when no
  /// registration exists.
  ///
  /// Exposed for operator-UI / test introspection. Production guard
  /// paths use the `guard*` helpers instead — they enforce, this
  /// only reports.
  AgentRegistration? resolve(String agentName) => _byName[agentName];

  /// Returns `true` when [agentName] currently has a registration.
  bool isRegistered(String agentName) => _byName.containsKey(agentName);

  /// All currently registered agent names. The returned set is a
  /// snapshot; mutating the registry after the call does not change
  /// the snapshot.
  Set<String> registeredAgents() => _byName.keys.toSet();

  // ─── Enforcement helpers ────────────────────────────────────────

  /// Guards a node-write under the canonical scope tag
  /// `"node:<typeName>"`. Pass-through when [agentName] is null.
  ///
  /// Throws [AgentScopeViolation] with kind
  /// [AgentScopeViolationKind.agentNotRegistered] when [agentName]
  /// is non-null but the registry has no entry, and with kind
  /// [AgentScopeViolationKind.writeScopeDenied] when the entry
  /// exists but its `writeScopes` do not match.
  void guardNodeWrite({
    required String? agentName,
    required String typeName,
  }) {
    _guardWrite(
      agentName: agentName,
      scope: AgentRegistration.nodeScope(typeName),
    );
  }

  /// Guards an edge-write under the canonical scope tag
  /// `"edge:<wireName>"`. Pass-through when [agentName] is null.
  ///
  /// [wireName] is the `EdgeType.wireName` value (e.g.
  /// `"contradicts"`, `"mentions"`); the registry does not depend
  /// on the enum.
  void guardEdgeWrite({
    required String? agentName,
    required String wireName,
  }) {
    _guardWrite(
      agentName: agentName,
      scope: AgentRegistration.edgeScope(wireName),
    );
  }

  /// Guards a stack-push under the canonical scope tag
  /// `"stack:<name>"`. Pass-through when [agentName] is null.
  void guardStackPush({
    required String? agentName,
    required String stackName,
  }) {
    _guardWrite(
      agentName: agentName,
      scope: AgentRegistration.stackScope(stackName),
    );
  }

  /// Guards a read against the canonical scope tag (e.g.
  /// `"node:Event"`, `"stack:questions_open"`). Pass-through when
  /// [agentName] is null.
  ///
  /// Reserved for future read enforcement — v0 has no production
  /// read site that consults this helper. The taxonomy is stable
  /// so the wiring is mechanical when the read paths land.
  void guardRead({
    required String? agentName,
    required String scope,
  }) {
    _guard(
      agentName: agentName,
      scope: scope,
      accessNoun: 'read',
      allows: (reg) => reg.allowsRead(scope),
      deniedKind: AgentScopeViolationKind.readScopeDenied,
      grantedScopes: (reg) => reg.readScopes,
      deniedDetail:
          'Spec § 9.5 — readScopes restrict which resources the '
          'agent may consult; broaden the registration or revise '
          'the procedure to read a permitted resource.',
    );
  }

  // ─── Internals ──────────────────────────────────────────────────

  void _guardWrite({required String? agentName, required String scope}) {
    _guard(
      agentName: agentName,
      scope: scope,
      accessNoun: 'write',
      allows: (reg) => reg.allowsWrite(scope),
      deniedKind: AgentScopeViolationKind.writeScopeDenied,
      grantedScopes: (reg) => reg.writeScopes,
      deniedDetail:
          'Spec § 9.5 — a Connector cannot write Procedure nodes, '
          'a Pruner cannot create new nodes; broaden the '
          'registration or revise the procedure to write a '
          'permitted resource.',
    );
  }

  /// Shared guard body for the read and write scope checks. The two
  /// access kinds differ only in the predicate they consult, the
  /// denied-violation kind, which scope set they report, and the
  /// spec-explanation tail — the agent-resolution and rejection
  /// structure is identical, so it lives here once (review D.2.9).
  ///
  /// Pass-through (no-op) when [agentName] is null. Throws
  /// [AgentScopeViolation] with kind
  /// [AgentScopeViolationKind.agentNotRegistered] when the agent is
  /// unknown, and with [deniedKind] when [allows] returns false.
  void _guard({
    required String? agentName,
    required String scope,
    required String accessNoun,
    required bool Function(AgentRegistration reg) allows,
    required AgentScopeViolationKind deniedKind,
    required Set<String> Function(AgentRegistration reg) grantedScopes,
    required String deniedDetail,
  }) {
    if (agentName == null) return;
    final reg = _byName[agentName];
    if (reg == null) {
      throw AgentScopeViolation(
        kind: AgentScopeViolationKind.agentNotRegistered,
        agentName: agentName,
        message:
            'agent "$agentName" attempted a $accessNoun of scope '
            '"$scope" but is not registered with the AgentRegistry. '
            'The registry is populated by the dispatcher at run start; '
            'an unregistered agent name usually means a stale procedure '
            'declaration or a dispatcher bug.',
      );
    }
    if (!allows(reg)) {
      final granted = grantedScopes(reg);
      throw AgentScopeViolation(
        kind: deniedKind,
        agentName: agentName,
        requestedScope: scope,
        grantedScopes: granted,
        message:
            'agent "$agentName" attempted to $accessNoun scope "$scope" '
            'but its ${accessNoun}Scopes $granted do not match. '
            '$deniedDetail',
      );
    }
  }
}
