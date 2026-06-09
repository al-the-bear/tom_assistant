// ProcedureStatus — the closed lifecycle alphabet of a Procedure node
// (`procedure_specification.md` § 6.1).
//
// A procedure moves authored → draft → active → preferred, and may be demoted
// from draft, active, or preferred. Procedures are never deleted (umbrella
// overview hard principle 6): demotion removes a procedure from default
// retrieval but it stays queryable by id and stays in backup; a "revival" is a
// *new* revision (a fresh node, linked `superseded_by`), never a transition out
// of `demoted`. So `demoted` is terminal here.
//
// The transition rule lives on the enum (not in the store or the sleep cycle)
// because every layer that mutates a procedure's status — the authoring loop
// (authored/draft), the dispatcher (draft→active on first successful run), and
// the Synthesizer sleep pass (active↔preferred, →demoted) — must agree on what
// is legal. Encoding it once, in the shared vocabulary, makes an illegal
// transition a single guarded decision rather than three independent ones.

/// The lifecycle stage of a `Procedure` node.
///
/// The set is closed and ordered (`authored` first, `demoted` last). Iteration
/// order of [values] follows the lifecycle, so tests and trail dumps can rely
/// on a stable ordering.
enum ProcedureStatus {
  /// Newly written: header validated and body parsed, but not yet run.
  authored('authored'),

  /// Parseable and validated, but not yet run successfully end-to-end.
  draft('draft'),

  /// Passing critique; eligible for retrieval and reuse.
  active('active'),

  /// High success rate; promoted by the sleep cycle.
  preferred('preferred'),

  /// Superseded or repeatedly failing; removed from default retrieval but
  /// retained (queryable by id, kept in backup).
  demoted('demoted');

  const ProcedureStatus(this.token);

  /// The stable wire/serialisation token. Renaming an enum value preserves the
  /// token, so stored Procedure nodes and trail records keep resolving.
  final String token;

  /// Resolves a [token] back to its [ProcedureStatus], throwing
  /// [ArgumentError] for an unknown token (loud, never a silent default).
  static ProcedureStatus fromToken(String token) {
    for (final status in values) {
      if (status.token == token) return status;
    }
    throw ArgumentError.value(token, 'token', 'unknown ProcedureStatus token');
  }

  /// Whether default retrieval surfaces a procedure in this stage. Only
  /// `active` and `preferred` procedures are reused; `authored` / `draft`
  /// are not yet trusted and `demoted` is withdrawn.
  bool get isRetrievable =>
      this == ProcedureStatus.active || this == ProcedureStatus.preferred;

  /// Whether a procedure may move from this stage to [to].
  ///
  /// Forward-only progression with demotion as the escape hatch:
  ///   * `authored → draft`
  ///   * `draft → active | demoted`
  ///   * `active → preferred | demoted`
  ///   * `preferred → active | demoted`
  ///   * `demoted → ∅` (terminal)
  ///
  /// A stage never transitions to itself.
  bool canTransitionTo(ProcedureStatus to) {
    switch (this) {
      case ProcedureStatus.authored:
        return to == ProcedureStatus.draft;
      case ProcedureStatus.draft:
        return to == ProcedureStatus.active || to == ProcedureStatus.demoted;
      case ProcedureStatus.active:
        return to == ProcedureStatus.preferred || to == ProcedureStatus.demoted;
      case ProcedureStatus.preferred:
        return to == ProcedureStatus.active || to == ProcedureStatus.demoted;
      case ProcedureStatus.demoted:
        return false;
    }
  }
}
