// EdgeType — the closed 12-edge alphabet for the memory graph.
//
// From `memory_specification.md` § 4.2 (the authoritative source — the
// folder barrel's earlier draft list is superseded by the spec; see
// Q-A.24.1 in `prototype_implementation_questions.md`):
//
//   mentions, derived_from, superseded_by, satisfied_by, motivates,
//   evidence_for, contradicts, part_of, produced_by, authored_by,
//   targets, caused_by.
//
// The alphabet is **closed**. New edge labels never arrive at runtime
// (in contrast to node types, which are open). Adding one is a spec
// change followed by a migration; never a code edit alone.
//
// Per-edge permission rules (which node types may emit / receive which
// edge) live in `NodeTypeDecl.allowedOutgoing` / `allowedIncoming` (see
// `nodes/node_type_decl.dart`). The `EdgeType` enum here is the
// vocabulary; the permission table is the grammar.

/// The closed 12-edge alphabet for the memory graph.
///
/// Each constant carries the canonical snake_case wire name used in the
/// SQLite `edges.type` column. The enum's Dart identifier is the
/// camelCase form to satisfy Dart style; the wire name is read via
/// [wireName] and is the one that round-trips through storage and the
/// MCP surface.
enum EdgeType {
  /// `mentions` — soft reference. A node refers to another without
  /// implying derivation, evidence, or causation.
  mentions('mentions'),

  /// `derived_from` — the source node was used to produce this node.
  /// Used heavily by consolidation (an extracted Claim is `derived_from`
  /// the Event that mentioned it).
  derivedFrom('derived_from'),

  /// `superseded_by` — version chain. The target replaces this node.
  /// Original is retained for audit; queries default to the live tip.
  supersededBy('superseded_by'),

  /// `satisfied_by` — the target node closes / answers / fulfils this
  /// one. Question → Conclusion, AutomationIdea → Procedure, etc.
  satisfiedBy('satisfied_by'),

  /// `motivates` — this node is a reason to do / investigate the
  /// target. Question motivates a research run; InterestItem
  /// motivates a procedure draft.
  motivates('motivates'),

  /// `evidence_for` — this node supports the target Claim or
  /// Conclusion. Sources, observations, and prior claims edge here.
  evidenceFor('evidence_for'),

  /// `contradicts` — this node conflicts with the target. The pair
  /// triggers a `ContradictionDetected` shaking event (§ 9.4).
  contradicts('contradicts'),

  /// `part_of` — structural membership. StackEntry → Stack, PlanStep
  /// → Plan, sub-concept → concept. Also carries the `depends_on`
  /// sub-shape via `attrs.kind=depends_on` for plan steps.
  partOf('part_of'),

  /// `produced_by` — output → producing run. Every persisted Artifact,
  /// Conclusion, or Claim that came out of a procedure run edges
  /// `produced_by` the ProcedureRun.
  producedBy('produced_by'),

  /// `authored_by` — Procedure → author (a Session, a Persona, or a
  /// dedicated `procedure_author` run). Used by the procedure
  /// promotion heuristics.
  authoredBy('authored_by'),

  /// `targets` — Plan / Artifact → the goal node. Distinguishes "what
  /// this is *about*" from `part_of` ("what this *belongs to*").
  targets('targets'),

  /// `caused_by` — temporal / causal antecedent. Event chains use it
  /// (inbound prompt `caused_by` a Session; ProcedureRun `caused_by`
  /// the Event that dispatched it).
  causedBy('caused_by');

  /// Canonical snake_case form used in storage and on the wire.
  final String wireName;

  const EdgeType(this.wireName);

  /// Parses an edge type from its [wireName].
  ///
  /// Throws [FormatException] when [wire] does not match any edge in
  /// the closed alphabet. The throw is strict by design: silently
  /// returning `null` would let a typo become a forever-orphaned edge.
  static EdgeType fromWireName(String wire) {
    for (final t in EdgeType.values) {
      if (t.wireName == wire) return t;
    }
    throw FormatException(
      'Unknown EdgeType wireName "$wire" — the alphabet is closed; '
      'see memory_specification.md § 4.2 for the 12 permitted values.',
    );
  }
}

/// Direction filter for [TomBrainMemory.edgesOf].
///
/// `both` is the default — most agents that walk the graph want every
/// edge touching a node regardless of orientation. The directional
/// values are for procedures that care about provenance (`incoming`
/// from a Claim → who supplied evidence) versus consequence (`outgoing`
/// from an Event → what it caused).
enum EdgeDirection {
  /// Edges where the node is the `from` endpoint.
  outgoing,

  /// Edges where the node is the `to` endpoint.
  incoming,

  /// Edges in either direction.
  both,
}
