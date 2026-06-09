// Barrel for the `planning/` module — the cross-component planning vocabulary
// (`planning_specification.md` § 5, § 10.1, § 11; completion-plan Todo 8 /
// G-P1…G-P6).
//
// `PlanKind` / `PlanStatus` / `StepKind` / `StepStatus` are the closed token
// alphabets a `Plan` / `PlanStep` node carries; `PlanView` / `PlanStepView`
// decode a stored node once at the boundary; `PlanningEvent` (sealed, nine
// leaves) is the loop's observability surface. All cross-component (memory
// stores them, the `plan_v1` loop stamps/emits them, the typed queries filter on
// them, a Forge inspector renders them), so they live in shared (spec § 11).

export 'plan_status.dart' show PlanKind, PlanStatus;
export 'plan_view.dart'
    show
        PlanStepView,
        PlanView,
        dependsOnEdgeKind,
        planNodeTypeName,
        planStepNodeTypeName;
export 'planning_event.dart'
    show
        GoalClassified,
        GraphEstimated,
        PlanAccepted,
        PlanCritiqueProduced,
        PlanRejected,
        PlanRequested,
        PlanRevised,
        PlanningEvent,
        StepStatusChanged,
        StepsDecomposed,
        planningEventKinds;
export 'step_status.dart' show StepKind, StepStatus;
