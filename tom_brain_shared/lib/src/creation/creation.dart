// Barrel for the `creation/` module — the cross-component creation vocabulary
// (`creation_specification.md` § 9.1, § 12; UB5 — the first real consumer that
// § 12.1 decision 4 deferred the typed family to).
//
// `CreationEvent` (sealed, twelve leaves) is the creation loop's observability
// surface. It is cross-component (the `create_v1` procedure realises it, the
// `tom_brain_run` creation-trail writer projects a `create_v1` run into it, and
// a Forge session inspector renders it), so it lives in shared (spec § 12
// topology — "CreationEvent value types → tom_brain_shared").

export 'creation_event.dart'
    show
        CreationAccepted,
        CreationEvent,
        CreationRequested,
        CreationRolledBack,
        CritiqueProduced,
        DraftProduced,
        DraftWritten,
        EnvironmentObserved,
        PostObservationCaptured,
        ScopeViolation,
        SuccessChecked,
        TestDrafted,
        TestRun,
        creationEventKinds;
