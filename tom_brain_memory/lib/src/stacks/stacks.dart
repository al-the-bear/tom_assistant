// Barrel for the `stacks/` module (A.23 layout; A.24 surface).
//
// At A.24 this barrel exports:
//
//   - `StackApi` — the abstract CRUD surface (§ 5.1).
//   - `StackPolicy`, `PriorityPolicyKind`, `RetentionPolicyKind` —
//     policy primitives (§ 5.2 – § 5.3).
//   - `StackDecl` — creation declaration for non-bootstrap stacks.
//   - `StackSummary`, `StackInfo` — catalogue read models.
//   - `StackEntry`, `StackEntryStatus` — the materialised entry
//     shape returned by `peek` / `pop`.
//   - `StackEvent`, `StackEventKind` — lifecycle stream value.
//
// The six bootstrap stack *instances* (questions_open,
// automation_ideas, interests, inflight, recent_runs,
// restructure_backlog) land at A.43.

export 'stack_api.dart' show StackApi;
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
