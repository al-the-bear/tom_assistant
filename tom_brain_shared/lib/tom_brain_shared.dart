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

// A.17 — anchor/ module: `AssistantDedicationAnchor` is the framing
// every internal Tom Brain prompt opens with (overview's Postulate 3).
// Static-only surface: `text`, `version`, `wrap(prompt)`,
// `containsAnchor(candidate)`, `wrapAll(messages)`. The substrate
// (B.22 / B.23) calls `wrap` on every outbound prompt; the access
// edge (E.31) uses `containsAnchor` for an inbound pre-check. The
// hashing referenced in `thinking_specification.md` § 10.1 is
// computed by the substrate (which already depends on `crypto`); the
// shared layer carries only the text and a hand-bumped revision
// number. There is no role-template assembly here — that lives in
// the substrate at B.22.
export 'src/anchor/anchor.dart' show AssistantDedicationAnchor;

// A.70 — cognitive_agents/ module: `AgentRegistration` is the per-
// agent registry value memory uses to attribute writes (`producedBy`)
// and to enforce read/write scopes (spec § 9.5). The runtime registry
// and the `AgentScopeViolation` exception live in `tom_brain_memory`;
// the value type stays here because the dispatcher (Phase D) and the
// procedure-author role (Phase E) populate / serialise it without
// depending on memory.
export 'src/cognitive_agents/cognitive_agents.dart' show AgentRegistration;

// A.88 — symbolic/ module: `SymbolicFilter`, `SymbolicOp`, `AttrClause`.
// Shape-only filter primitives used by the memory symbolic retrieval
// mode. They live in shared because every component that constructs a
// `RecallQuery` (substrate B.x via web tools, procedure engine C.x via
// the bridged `recall` primitive, dispatcher D.x as a primitive-act
// pass-through, access E.x via REST/SSE request mapping) needs to
// build these without taking a runtime dependency on the memory
// implementation. The SQL compiler that turns a `SymbolicFilter` into
// a parameterised `WHERE` clause stays in `tom_brain_memory`.
export 'src/symbolic/symbolic.dart'
    show AttrClause, SymbolicFilter, SymbolicOp;
