// Barrel for the `stacks/` module.
//
// History of additions:
//
//   - A.23 — folder layout.
//   - A.24 — abstract `StackApi` surface + value-type shapes.
//   - A.40 — concrete `SqliteStackApi` implementation, typed
//     `MemoryEvent` leaves (`StackCreated`, `StackPushed`,
//     `StackPopped`, `StackEntryUpdated`, `StackEntryRemoved`,
//     `StackPolicyChanged`, `StackOverflowDemoted`), and the
//     sealed `StackException` family. Bootstrap-name constant
//     `bootstrapStackNames` exported here so A.43 and the operator
//     UI can share one source of truth.
//   - A.41 — `priority_policy.dart` — pure-function evaluators
//     for all four `PriorityPolicyKind` variants. Exported as
//     `sortByPolicy`, `comparePolicy`, `effectivePriority` so
//     consumers (the SQLite reader's time-decayed post-sort, the
//     operator UI's "show effective score" overlay, future
//     in-memory `StackApi` mocks) share one canonical ordering
//     implementation.
//
// Hidden from the public surface:
//
//   - `Row` is a `sqlite3` type; internal to the implementation.
//   - The `Sqlite*` prefix is exposed so consumers can construct
//     a concrete api in tests / wiring code. The abstract `StackApi`
//     remains the contract surface.

export 'bootstrap_stacks_installer.dart'
    show
        BootstrapInstallReport,
        BootstrapStackSpec,
        bootstrapStackSpecs,
        installBootstrapStacks,
        stackEntryNodeTypeAny;
export 'priority_policy.dart'
    show comparePolicy, effectivePriority, sortByPolicy;
export 'sqlite_stack_api.dart' show SqliteStackApi, bootstrapStackNames;
export 'stack_api.dart' show StackApi;
export 'stack_events.dart'
    show
        StackCreated,
        StackEntryRemoved,
        StackEntryUpdated,
        StackOverflowDemoted,
        StackPolicyChanged,
        StackPopped,
        StackPushed;
export 'stack_exception.dart'
    show
        BootstrapStackImmutable,
        StackAlreadyExists,
        StackEntryNotFound,
        StackException,
        StackNotFound,
        StackPolicyConfigInvalid,
        StackPolicyConfigInvalidReason;
export 'stack_types.dart'
    show
        PriorityPolicyKind,
        RetentionPolicyKind,
        StackDecl,
        StackEntry,
        StackEntryStatus,
        StackEvent,
        StackEventKind,
        StackInfo,
        StackPolicy,
        StackSummary;
