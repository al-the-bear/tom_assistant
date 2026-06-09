// StepKind / StepStatus — the closed vocabulary of a `PlanStep` node
// (`planning_specification.md` § 4.3, § 5.2).
//
// Each decomposed step carries a *kind* (which subsystem is expected to execute
// it, § 4.3) and moves through an execution *status* as a consumer runs it
// (§ 5.2). Both alphabets are closed; both carry a stable wire token. They live
// in `tom_brain_shared` for the same reason as [PlanKind] / [PlanStatus]:
// memory stores them, `plan_v1` stamps them, the typed queries filter on them,
// and a Forge inspector renders them.

/// The kind of work a `PlanStep` represents — which subsystem (or the user)
/// is expected to execute it (`planning_specification.md` § 4.3).
enum StepKind {
  /// A thinking-loop sub-question.
  think('think'),

  /// A nested planning goal (step expansion).
  plan('plan'),

  /// An artifact production handed to the creation subsystem.
  create('create'),

  /// A memory recall.
  recall('recall'),

  /// A research step (recall + web tools).
  research('research'),

  /// A choice between alternatives, captured as a `Conclusion`.
  decide('decide'),

  /// Something the user or Tom Assistant must do that Tom Brain cannot
  /// (physical task, third-party UI, a conversation on the user's behalf).
  externalAction('external_action');

  const StepKind(this.token);

  /// The stable wire/serialisation token.
  final String token;

  /// Resolves a [token] back to its [StepKind], throwing [ArgumentError] for an
  /// unknown token.
  static StepKind fromToken(String token) {
    for (final kind in values) {
      if (kind.token == token) return kind;
    }
    throw ArgumentError.value(token, 'token', 'unknown StepKind token');
  }
}

/// The execution stage of a `PlanStep` node (`planning_specification.md`
/// § 5.2). Closed and ordered (`pending` first, `skipped` last).
enum StepStatus {
  /// Not yet started.
  pending('pending'),

  /// A consumer is executing it.
  inProgress('in_progress'),

  /// The success criterion was met.
  succeeded('succeeded'),

  /// Execution reported failure; triggers re-planning of the affected sub-graph.
  failed('failed'),

  /// Replaced by a newer step on a re-plan (structural, hard principle 6).
  superseded('superseded'),

  /// Deliberately not executed (a branch the plan trimmed).
  skipped('skipped');

  const StepStatus(this.token);

  /// The stable wire/serialisation token.
  final String token;

  /// Resolves a [token] back to its [StepStatus], throwing [ArgumentError] for
  /// an unknown token.
  static StepStatus fromToken(String token) {
    for (final status in values) {
      if (status.token == token) return status;
    }
    throw ArgumentError.value(token, 'token', 'unknown StepStatus token');
  }

  /// Whether the step still awaits execution — `pending` or `in_progress`. A
  /// step that blocks another (the `StepsBlockedBy` query) is one whose
  /// prerequisites are still open.
  bool get isOpen => this == StepStatus.pending || this == StepStatus.inProgress;
}
