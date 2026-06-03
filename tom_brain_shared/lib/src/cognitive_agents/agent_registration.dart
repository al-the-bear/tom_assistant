// AgentRegistration — per-agent registry entry consulted by memory on
// every write (Plan step A.70; spec § 9.5).
//
// What this file owns:
//
//   * The `AgentRegistration` value type. Carries the agent's stable
//     name, the dispatcher procedure that hosts it, its default
//     `WriteBudget`, and the two scope sets it is allowed to read and
//     write against.
//   * The `AgentScope` lightweight string-tag grammar used by both
//     `readScopes` and `writeScopes`. Tags are plain strings of the
//     form `"<kind>:<name>"` (e.g. `"node:Event"`, `"edge:contradicts"`,
//     `"stack:questions_open"`) plus the two wildcard shapes
//     `"<kind>:*"` (every name within a kind) and `"*"` (every kind,
//     every name). Match semantics are implemented in
//     `AgentRegistration.allowsRead` / `.allowsWrite`.
//
// Why this lives in `tom_brain_shared`:
//
//   * Memory needs the type to enforce scopes (the registry interceptor
//     wraps `persist` / `edge` / `push`).
//   * The dispatcher (Phase D) needs the type to *populate* the
//     registry from procedure-author declarations.
//   * The procedure-author role (Phase E) needs to *serialise* the
//     type alongside the procedure spec it sits on.
//
//   Two consumers in different layers + one storage format → shared.
//   Living in `tom_brain_memory` would force the dispatcher to depend
//   on memory in the wrong direction; living in the dispatcher would
//   force memory to depend on the dispatcher. Shared is the only
//   coherent home.
//
// Grammar choices (Q-A.70.1):
//
//   * `node:<TypeName>` — exactly the node-type registry name. Memory
//     uses the registered type name (e.g. `"Event"`, `"Concept"`,
//     `"Procedure"`).
//   * `edge:<wireName>` — exactly the `EdgeType.wireName` string
//     (e.g. `"contradicts"`, `"mentions"`). The closed 12-edge
//     alphabet from spec § 4.2 lives in memory; this layer carries
//     the strings only.
//   * `stack:<name>` — exact stack name. Bootstrap stacks live at
//     `"questions_open"`, `"automation_ideas"`, etc; agent-created
//     stacks use whatever name `StackApi.create` took.
//   * `<kind>:*` — wildcard within a kind. `"node:*"` permits every
//     node type; `"edge:*"` permits every edge label; `"stack:*"`
//     permits every stack.
//   * `*` — global wildcard. Permits every kind, every name. Reserved
//     for the bootstrap `propose_node_type_v1` style of fully-
//     privileged author procedures.
//
// What this file does NOT do:
//
//   * No enforcement. The matching helpers (`allowsRead`,
//     `allowsWrite`) return a `bool`; the enforcement caller throws
//     its own `AgentScopeViolation`. Keeps `tom_brain_shared`
//     dependency-free (no exception types, no memory imports).
//   * No registry. `AgentRegistration` is the value; the runtime
//     map of agent-name → registration lives in `tom_brain_memory`
//     (`AgentRegistry`).
//   * No serialisation. The dispatcher and the procedure-author role
//     do JSON in / out themselves; the value type carries the data
//     verbatim. A future `toJson` / `fromJson` lands when the second
//     consumer needs it (per the workspace "don't pre-extract" rule).

import '../budget/write_budget.dart';
import '../internal/argument_checks.dart';
import '../internal/collection_equality.dart';

/// Per-agent registry entry. Memory consults the matching entry on
/// every write to attribute the write (`producedBy`) and to enforce
/// what the agent is allowed to read and write.
///
/// See `memory_specification.md` § 9.5 for the contract and the file
/// header above for the scope-tag grammar.
final class AgentRegistration {
  /// Stable agent identifier — e.g. `"extractor"`, `"connector"`,
  /// `"pruner"`. Memory uses this as the key into its in-process
  /// registry. The dispatcher attaches it to `Scope.agentName` on
  /// every write the agent issues.
  final String agentName;

  /// The id of the d4rt procedure that hosts this agent (e.g.
  /// `"dream_extract_v1"`). Carried so memory can record `producedBy`
  /// with both the agent identity and the originating procedure — the
  /// trace stitcher needs the pair.
  ///
  /// Deliberately an opaque `String`, **not** the [ProcedureId] value
  /// type: memory stores it verbatim as one half of the `producedBy`
  /// pair and never parses it, and the cognitive-agent procedures are
  /// keyed by their slug (`dream_extract_v1`), which is not the
  /// `p_<slug>_v<n>` shape `ProcedureId` validates. Coupling this field
  /// to `ProcedureId` would force every agent slug to migrate to that
  /// format for no consumer benefit.
  final String procedureId;

  /// `WriteBudget` to install on every run the dispatcher starts on
  /// this agent's behalf. The dispatcher passes it to
  /// `WriteBudgetTracker.beginRun(runId, budget)` at run start.
  /// A per-run override can still ask for less; the registration's
  /// budget is the ceiling.
  final WriteBudget defaultBudget;

  /// Set of scope tags the agent may read against. Memory consults
  /// this on reads that go through a registered enforcement path —
  /// for v0 the read enforcement is advisory (no read path consults
  /// the registry yet); the field is populated so the dispatcher
  /// can validate at run-start that a procedure's planned reads are
  /// representable by the agent's declared scopes.
  final Set<String> readScopes;

  /// Set of scope tags the agent may write against. Memory enforces
  /// this on every `persist` / `edge` / `push` call that carries a
  /// `Scope.agentName` matching this registration.
  ///
  /// Forms:
  ///   * `"*"`                        — global wildcard
  ///   * `"node:*"` / `"edge:*"` / `"stack:*"` — per-kind wildcard
  ///   * `"node:<TypeName>"`          — single node type
  ///   * `"edge:<wireName>"`          — single edge label
  ///   * `"stack:<name>"`             — single stack
  final Set<String> writeScopes;

  /// Constructs an immutable registration. The two scope sets are
  /// defensively copied into unmodifiable views so a downstream
  /// consumer cannot grow the privileges of an in-memory registration.
  ///
  /// `agentName` and `procedureId` must be non-empty. Empty strings
  /// would silently match nothing and are almost always a programmer
  /// mistake (e.g. an uninitialised field) — fail fast at construction.
  AgentRegistration({
    required this.agentName,
    required this.procedureId,
    required this.defaultBudget,
    required Set<String> readScopes,
    required Set<String> writeScopes,
  })  : readScopes = Set.unmodifiable(readScopes),
        writeScopes = Set.unmodifiable(writeScopes) {
    requireNonEmpty(agentName, 'agentName');
    requireNonEmpty(procedureId, 'procedureId');
    for (final tag in readScopes) {
      _validateTag(tag, field: 'readScopes');
    }
    for (final tag in writeScopes) {
      _validateTag(tag, field: 'writeScopes');
    }
  }

  /// Returns `true` when [scope] is permitted by this agent's
  /// [writeScopes]. The match honours the three wildcard forms named
  /// in the file header.
  ///
  /// [scope] must already be in canonical form (e.g. `"node:Event"`,
  /// `"edge:contradicts"`, `"stack:questions_open"`). Callers that
  /// build the tag from raw inputs use the [nodeScope] / [edgeScope]
  /// / [stackScope] helpers — same shape, fewer typos.
  bool allowsWrite(String scope) => _scopeMatches(writeScopes, scope);

  /// Mirror of [allowsWrite] for read enforcement. The semantics are
  /// identical — wildcard expansion + exact-name match.
  bool allowsRead(String scope) => _scopeMatches(readScopes, scope);

  /// Builds a `"node:<typeName>"` tag. Sugar that keeps call sites
  /// readable.
  static String nodeScope(String typeName) => 'node:$typeName';

  /// Builds an `"edge:<wireName>"` tag. The caller passes the
  /// `EdgeType.wireName` value, not the enum (this package does not
  /// know about the closed alphabet — it's owned by memory).
  static String edgeScope(String wireName) => 'edge:$wireName';

  /// Builds a `"stack:<name>"` tag.
  static String stackScope(String stackName) => 'stack:$stackName';

  /// The global wildcard tag (`"*"`). A registration whose
  /// [writeScopes] contains this tag may write anything; same for
  /// [readScopes] and reads. Reserved for bootstrap / author
  /// procedures that need full reach.
  static const String globalWildcard = '*';

  /// The per-kind wildcard tag (e.g. `"node:*"`). Use the helper to
  /// avoid typos:
  ///
  /// ```dart
  /// final scopes = {AgentRegistration.kindWildcard('node')};
  /// ```
  static String kindWildcard(String kind) => '$kind:*';

  // ─── Internals ──────────────────────────────────────────────────

  static bool _scopeMatches(Set<String> granted, String requested) {
    if (granted.isEmpty) return false;
    if (granted.contains(globalWildcard)) return true;
    if (granted.contains(requested)) return true;
    // Per-kind wildcard. Split on the first colon; everything before
    // it is the kind; the registered `"kind:*"` form matches any
    // request whose prefix matches.
    final colon = requested.indexOf(':');
    if (colon < 0) {
      // Requested tag lacks a kind prefix (only the global wildcard
      // would match, and we already handled that above).
      return false;
    }
    final kind = requested.substring(0, colon);
    return granted.contains('$kind:*');
  }

  static void _validateTag(String tag, {required String field}) {
    if (tag.isEmpty) {
      throw ArgumentError.value(
        tag,
        field,
        'scope tag must be non-empty',
      );
    }
    if (tag == globalWildcard) return;
    // Tag must be `<kind>:<name>` with both sides non-empty. `kind:*`
    // is allowed and treated as a per-kind wildcard.
    final colon = tag.indexOf(':');
    if (colon <= 0 || colon == tag.length - 1) {
      throw ArgumentError.value(
        tag,
        field,
        'scope tag must be "<kind>:<name>" (e.g. "node:Event") '
            'or a wildcard ("*" or "<kind>:*"). Got "$tag".',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AgentRegistration &&
      other.agentName == agentName &&
      other.procedureId == procedureId &&
      other.defaultBudget == defaultBudget &&
      setEquals(other.readScopes, readScopes) &&
      setEquals(other.writeScopes, writeScopes);

  @override
  int get hashCode => Object.hash(
        agentName,
        procedureId,
        defaultBudget,
        Object.hashAllUnordered(readScopes),
        Object.hashAllUnordered(writeScopes),
      );

  @override
  String toString() => 'AgentRegistration('
      'agentName: $agentName, '
      'procedureId: $procedureId, '
      'defaultBudget: $defaultBudget, '
      'readScopes: $readScopes, '
      'writeScopes: $writeScopes)';
}
