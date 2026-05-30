// Scope — write provenance + idempotency key bundle, supplied with
// every `persist` / `edge` call.
//
// From `memory_specification.md` § 3.1 ("Scope carries idempotency
// keys, producer identity (which procedure run produced this), and
// a `causedBy` reference for trace stitching"). Also surfaces in
// the agent infrastructure (§ 9.1, § 9.5) and in stream cursors
// (§ 9.2).
//
// `DemotionReason` and `ForgetReason` live here too — they share
// the lifecycle theme and are tiny enums that don't justify their
// own file.

/// Producer / idempotency / causal context attached to a write.
///
/// Every `persist` and every `edge` requires a `Scope`. The agent
/// registry (§ 9.5) restricts which producers may issue which
/// scopes — a `Connector` agent for example cannot write under a
/// `Pruner` producer name.
final class Scope {
  /// Stable producer identity — typically `<agent>:<procedure>:<run>`,
  /// e.g. `extractor:dream_extract_v1:r_01J...`. Used for
  /// `AgentRegistration.writeScopes` enforcement.
  final String producer;

  /// Idempotency key. A second write with the same key is a no-op
  /// that returns the original `NodeId` (§ 9.1). `null` skips
  /// idempotency — only safe for writes the caller can prove are
  /// unique (e.g. a freshly minted Event with a UUID payload).
  final String? idempotencyKey;

  /// Opaque pointer to the prior event / node / run that caused
  /// this write. Used by the trace stitcher to reconstruct the
  /// brain's causal graph.
  final String? causedBy;

  /// Optional run id (the engine-assigned run identity) so the
  /// write can be attributed back to the producing run even if
  /// `producer` is shared across runs.
  final String? runId;

  /// Agent identity the write is issued under (spec § 9.5, plan
  /// step A.70). When non-null AND the memory store was opened with
  /// an `AgentRegistry`, the registry resolves this name to an
  /// `AgentRegistration` and enforces the registration's
  /// `writeScopes` against the resource the write touches
  /// (`node:<TypeName>`, `edge:<wireName>`, `stack:<name>`).
  ///
  /// When null the registry pass-through fires — bootstrap writes
  /// (initial node-type registration, bootstrap-stack installation)
  /// and migration writes have no agent identity, and forcing one
  /// would muddy the layering. The same opt-in shape the
  /// `WriteBudgetTracker` uses for `runId`.
  final String? agentName;

  const Scope({
    required this.producer,
    this.idempotencyKey,
    this.causedBy,
    this.runId,
    this.agentName,
  });

  /// Convenience constructor for non-idempotent writes (rare,
  /// usually only for primary Event ingestion where uniqueness is
  /// guaranteed upstream).
  const Scope.nonIdempotent({
    required this.producer,
    this.causedBy,
    this.runId,
    this.agentName,
  }) : idempotencyKey = null;
}

/// Reason supplied to `TomBrainMemory.demote`.
///
/// Demotion is reversible — the node remains queryable by id; it
/// just no longer surfaces in retrieval. The reason is kept on the
/// demoted row for audit.
enum DemotionReason {
  /// Reinforcement decayed past the type's retention horizon
  /// (§ 5.3 `boundedAge`).
  retentionHorizon,

  /// A `Pruner` agent decided this node is redundant or low-value.
  prunerDecision,

  /// A `Reconsolidator` agent superseded this node and demoted the
  /// original (§ 9.4 reconsolidation).
  supersession,

  /// A migration archived the node after re-classification
  /// (§ 11.2).
  migrationArchive,

  /// Operator UI override.
  operatorOverride,
}

/// Reason supplied to `TomBrainMemory.forget`.
///
/// `forget` is the user-explicit, irreversible deletion path — it
/// writes a `Tombstone` (§ 4.1) and removes the row. The Tombstone
/// is the only surviving record.
enum ForgetReason {
  /// The user asked, via an inbound channel, to forget this
  /// node.
  userRequested,

  /// Legal / compliance erasure (GDPR-style right-to-be-forgotten).
  legalErasure,

  /// Data was discovered to be sensitive in a way the original
  /// scope did not permit; the responsible agent forgets it.
  scopeViolation,
}
