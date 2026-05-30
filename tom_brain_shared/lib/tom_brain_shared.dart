/// Shared types and primitives used across all Tom Brain components.
///
/// This is the cross-component vocabulary for the Tom Brain quest. It carries
/// **no behaviour with side effects** — no I/O, no LLM calls, no storage. It
/// is allowed exactly one runtime dependency: `tom_basics`.
///
/// Modules are introduced in subsequent Phase-A steps (A.10 – A.17). At the
/// step A.7 scaffold this barrel is intentionally empty; consumers can still
/// import the package and rely on the dependency being resolvable.
///
/// See `_ai/quests/tom_brain/prototype_implementation_plan.md` § Phase A for
/// the surface that will be exported from this library.
library;

// Exports land here, one per module, as A.10 – A.17 ship.

// A.10 — ids/ module: ULID + NodeId/EdgeId/TrailId/StackEntryId/ProcedureId.
export 'src/ids/ids.dart';

// A.11 — embedding/ module: Vec (Float32List wrapper) + cosine / dot / l2.
export 'src/embedding/embedding.dart';

// A.12 — budget/ module: Budget, TokenSpend, BudgetDelta, WriteBudget plus
// the BudgetExceededError raised by Budget.minus when a charge would
// overflow.
export 'src/budget/budget.dart'
    show Budget, BudgetDelta, BudgetExceededError, TokenSpend, WriteBudget;

// A.13 — result/ module: Result<T, E> sealed sum (Ok / Err) and Maybe<T>
// sealed sum (Some / None), with fluent whenOk / whenErr / whenSome /
// whenNone extensions and map / mapErr / fold transformations. The
// extension types are exported so consumers can reference them by name
// (rare — the methods are reached via dispatch), and so a future
// `extension on Result` augmentation in this package stays unambiguous.
export 'src/result/result.dart'
    show
        Err,
        Maybe,
        MaybeMap,
        MaybeWhen,
        None,
        Ok,
        Result,
        ResultMap,
        ResultWhen,
        Some;

// A.14 — events/ module: BrainEvent abstract base + DiagnosticEnvelope
// transport wrapper + DiagnosticSeverity. Subclasses of BrainEvent live in
// the owning component (memory adds MemoryEvent at A.38). The
// DiagnosticSeverityCompare extension is exported so consumers can read
// `severity.atLeast(...)` predicates without an additional import.
export 'src/events/events.dart'
    show
        BrainEvent,
        DiagnosticEnvelope,
        DiagnosticSeverity,
        DiagnosticSeverityCompare;

// A.15 — time/ module: BrainTime canonical timestamp + Clock injection
// surface (SystemClock for production, FixedClock / MutableTestClock for
// tests). Every brain component that reads "now" takes a Clock by
// constructor; the shared layer offers no global clock.
export 'src/time/time.dart'
    show BrainTime, Clock, FixedClock, MutableTestClock, SystemClock;

// A.16 — version/ module: BrainVersion monotonic positive-integer
// version with total ordering and `next()` successor. Used by procedure
// revisions, schema migrations, the node-type registry, and stack-
// policy revisions. "No version yet" is represented as
// `Maybe<BrainVersion>`; the integer range itself is always ≥ 1.
export 'src/version/version.dart' show BrainVersion;
