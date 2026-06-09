// PlanKind / PlanStatus — the closed vocabulary of a `Plan` node
// (`planning_specification.md` § 4.2, § 5.1).
//
// A plan is classified into one of four *kinds* the moment the `planner` role
// tags the goal (§ 4.2), and it moves through a *status* lifecycle as the
// planning loop commits it and consumers execute against it (§ 5.1). Both
// alphabets are closed; both carry a stable wire token so a stored Plan node and
// a `PlanningEvent` trail keep resolving across a rename of the enum identifier.
//
// Why these live in `tom_brain_shared` (not in `tom_brain_memory` or
// `tom_brain_procedure`): memory stores the token, the `plan_v1` procedure
// stamps it, a Forge plan inspector renders it, and the typed queries filter on
// it — none owns the vocabulary, so it is shared (same placement rationale as
// `ProcedureStatus`, procedure spec § 14).

/// The kind a goal is classified into by the `planner` role
/// (`planning_specification.md` § 4.2). Drives which subsystem the leaf steps
/// lean on and what shape their success criteria take.
enum PlanKind {
  /// Terminal state is one or more artifacts; leaf steps are `create` steps.
  creation('creation'),

  /// Terminal state is a body of claims/conclusions that answer a question;
  /// leaf steps lean on recall + web tools.
  research('research'),

  /// Terminal state is a chosen option plus a captured rationale.
  decision('decision'),

  /// A mix of the above; sub-graphs may be tagged differently.
  composite('composite');

  const PlanKind(this.token);

  /// The stable wire/serialisation token. Renaming an enum value preserves it,
  /// so stored Plan nodes and trail records keep resolving.
  final String token;

  /// Resolves a [token] back to its [PlanKind], throwing [ArgumentError] for an
  /// unknown token (loud, never a silent default).
  static PlanKind fromToken(String token) {
    for (final kind in values) {
      if (kind.token == token) return kind;
    }
    throw ArgumentError.value(token, 'token', 'unknown PlanKind token');
  }
}

/// The lifecycle stage of a `Plan` node (`planning_specification.md` § 5.1).
///
/// The set is closed and ordered (`draft` first, `abandoned` last). Iteration
/// order of [values] follows the lifecycle so tests and trail dumps can rely on
/// a stable ordering.
enum PlanStatus {
  /// Just built by the loop; not yet handed to a consumer.
  draft('draft'),

  /// Committed and being executed against.
  active('active'),

  /// Every root step reached a terminal success; the goal is served.
  completed('completed'),

  /// Replaced by a newer plan (revision is structural, hard principle 6); the
  /// node is retained and points to its replacement via `superseded_by`.
  superseded('superseded'),

  /// Dropped before completion (e.g. user-alignment drift caught on re-plan).
  abandoned('abandoned');

  const PlanStatus(this.token);

  /// The stable wire/serialisation token.
  final String token;

  /// Resolves a [token] back to its [PlanStatus], throwing [ArgumentError] for
  /// an unknown token.
  static PlanStatus fromToken(String token) {
    for (final status in values) {
      if (status.token == token) return status;
    }
    throw ArgumentError.value(token, 'token', 'unknown PlanStatus token');
  }

  /// Whether the plan is still being pursued — `draft` or `active`. The
  /// `OpenPlansFor` query returns exactly the open plans.
  bool get isOpen => this == PlanStatus.draft || this == PlanStatus.active;
}
