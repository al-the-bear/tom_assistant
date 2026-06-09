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

// A.10 — ids/ module: ULID + NodeId/EdgeId/TrailId/StackEntryId/ProcedureId/
// TurnId + TimestampId.
export 'src/ids/ids.dart';

// §10.2 — correlation/ module: `TurnContext` pairs the access-edge-minted
// `TurnId` with the per-turn `callSeq` counter (logging-spec §3). One context
// is created per turn at `ProcedureEngine.invoke` and shared across every
// nested run, so `turnId` + `callSeq` uniquely name any LLM call of the turn.
export 'src/correlation/correlation.dart' show TurnContext;

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
        BrainEventBus,
        DiagnosticEnvelope,
        DiagnosticSeverity,
        DiagnosticSeverityCompare;

// A.15 — time/ module: BrainTime canonical timestamp + Clock injection
// surface (SystemClock for production, FixedClock / MutableTestClock for
// tests). Every brain component that reads "now" takes a Clock by
// constructor; the shared layer offers no global clock.
export 'src/time/time.dart'
    show
        BrainTime,
        Clock,
        FixedClock,
        MutableTestClock,
        SystemClock,
        defaultNowUtc;

// A.16 — version/ module: BrainVersion monotonic positive-integer
// version with total ordering and `next()` successor. Used by procedure
// revisions, schema migrations, the node-type registry, and stack-
// policy revisions. "No version yet" is represented as
// `Maybe<BrainVersion>`; the integer range itself is always ≥ 1.
export 'src/version/version.dart' show BrainVersion;

// Todo 4 — procedure/ module: `ProcedureNotImplemented` is the clear error a
// stub verb (`plan_v1` / `create_v1` / `critique_v1` / `decide_v1`) throws when
// invoked before its real loop ships (proto spec § 5.2.1). It is raised mid-run
// from the `notImplemented` engine-native primitive and surfaces onto a run's
// `outcome.error`, so every observer (engine, access edge, Forge inspector,
// substrate trail render) references it without depending on the procedure
// package. `ProcedureNotFound` (resolver miss, pre-run) stays in
// `tom_brain_procedure`.
//
// Todo 7 adds the lifecycle vocabulary: `ProcedureStatus` (the closed stage
// alphabet authored → draft → active → preferred → demoted with the forward-
// only + demotion transition rule) and `CapabilitySet` (the `requires`-name set
// with the selector's overlap measure). Both are cross-component value types
// (memory stores them, the selector ranks on them, the authoring loop stamps
// them), so they belong to the shared vocabulary (procedure spec § 14).
//
// Todo 7 also adds the typed read-projections `ProcedureView` / `ProcedureRunView`
// (and the `procedure(Run)NodeTypeName` constants), which decode a stored
// `Procedure` / `ProcedureRun` node once at the boundary so memory's typed
// queries and a Forge inspector read the same shape (procedure spec § 7.1, § 9.2).
export 'src/procedure/procedure.dart'
    show
        CapabilitySet,
        ProcedureNotImplemented,
        ProcedureRunView,
        ProcedureStatus,
        ProcedureView,
        procedureNodeTypeName,
        procedureNotImplementedCode,
        procedureRunNodeTypeName;

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

// B.44 — json_shape/ module: `JsonShape` static-only namespace of
// pure JSON shape readers (`readString`, `readIntN`, `readMapList`,
// `readDoubleListN`, …) plus `JsonShapeException`. Extracted at the
// reuse-extraction pass after the rule-of-three was reached across
// the substrate's Ollama + OpenAI HTTP clients. Memory's MCP server
// payload parsing and the planning / creation / procedure on-disk
// JSON stores will consume the same surface as they ship.
export 'src/json_shape/json_shape.dart' show JsonShape, JsonShapeException;

// C.48 — effort/ module: `EffortMetrics`, the closed seven-field effort
// record stamped onto every `ProcedureRun`. Extracted from
// `tom_brain_procedure` (Plan step C.31) at the Phase C review
// reuse-extraction pass: the run recorder produces it and the Phase D
// dispatcher's harvester reads the same shape off the `recent_runs`
// stack. Pure value type — fits the A.9 dependency-discipline contract.
export 'src/effort/effort.dart' show EffortMetrics;

// C.48 — preemption/ module: `PreemptionState`, the cooperative
// single-foreground / single-background preemption state. Extracted from
// `tom_brain_procedure` (Plan step C.34) at the same pass: the
// engine reads it (`yield_if_foreground_waiting()`) and the Phase D
// dispatcher's coordinator drives it — two distinct components on one
// state contract. Pure state object (only `dart:async`).
export 'src/preemption/preemption.dart' show PreemptionState;

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

// D.11 — access/ module: the canonical `Access` object the dispatcher
// consumes regardless of channel, plus the field types it references —
// `InboundRequest`, `OutboundChunk`, the minimal `ResolvedIdentity` /
// `Session` / `Persona` handles, and the `DeliverCallback` typedef.
// Declared in shared because Phase D consumes the shape and Phase E
// produces instances of it (def § 1.5; proto spec § 10.1). The rich
// session window, the kernel identity, and the persona enrichment stay
// with their owners (memory, `tom_core_kernel`, the substrate role map);
// shared carries only the cross-phase shape.
// D.12 also re-exports the `AccessEvent` sealed sum (`AccessCreated` /
// `AccessDelivered` / `AccessFailed`) from the same library — it traces one
// inbound request from construction through delivery / failure. Phase E emits
// the events from the edge; the dispatcher / a Forge inspector observe them
// off the shared `BrainEvent` base. The variants carry routing identity and
// counts only — never the prompt text or the answer body. One `export` for
// the whole `access.dart` surface (D.11 shape + D.12 events).
// G.19 also re-exports the three Extension-G request-fidelity element types
// (`PriorTurn` / `RemoteToolResult` / `RemoteToolDef`) from the same library —
// the typed elements that populate `InboundRequest`'s four optional
// history/tool fields (`priorTurns` / `toolResults` / `remoteTools`;
// `sessionId` is a plain `String?`). Phase E decodes them from the wire
// payload; `call_llm_v1` consumes them (hub § 22.1 / access § 4.2).
export 'src/access/access.dart'
    show
        Access,
        AccessCreated,
        AccessDelivered,
        AccessEvent,
        AccessFailed,
        DeliverCallback,
        InboundRequest,
        OutboundChunk,
        Persona,
        PriorTurn,
        RemoteToolDef,
        RemoteToolResult,
        ResolvedIdentity,
        Session;

// E.39 — access/ backpressure: the `BackpressureSignal` sealed base + its one
// realisation `DeliveryStalled` (with `StallReason`), plus the `Backpressure`
// stream builders (`clear` / `stalled`). The `DeliverCallback` backpressure
// `Stream<OutboundChunk>` is produced by the Phase-E delivery paths (E.37 /
// E.38) and consumed by the engine, so the signal type is declared once, in
// shared — joining `OutboundChunk` (D.11) rather than being moved at E.52.
export 'src/access/backpressure.dart'
    show
        Backpressure,
        BackpressureSignal,
        DeliveryStalled,
        StallReason,
        StallReasonTerminality;

// A.88 — memory/ module: the consumer-facing `TomBrainMemoryClient`
// contract and the ~25 pure value types it traffics in (`Node`,
// `Edge`, `NodeTypeDecl`, `RecallQuery`, `RecallResult`, `Scope`,
// `MemoryConfig`, the stack / trail / migration / classification value
// types, `MemoryEvent`). Hoisted out of `tom_brain_memory` (todo #16,
// Q-A.88.4) so the substrate, the engine, and the access edge can
// consume the memory interface without pulling `sqlite3` / `dart_mcp`.
// Concrete implementations (`SqliteTomBrainMemory`, the isolate
// host/client, SQL compilers, stores) and the `dart:io` path getters
// (`MemoryConfigPaths`) stay in `tom_brain_memory`.
export 'src/memory/memory.dart';

// D.52 — access/ inbound-kind vocabulary: `InboundKinds` names the
// well-known inbound kind strings the Phase-E heuristic classifier (E.33)
// writes into `InboundRequest.kindHint` and the Phase-D dispatcher
// classifier (D.15) reads back. Promoted from
// `tom_brain_procedure` at the Phase-D review reuse-extraction
// pass (D.51 surfaced it; D.52 moves it) so the edge producer and the
// dispatcher consumer share one spelling without Phase E depending on the
// dispatcher package for a single constant. The procedure-id holder
// (`SystemProcedures`) stays with the dispatcher — Phase E never selects a
// procedure.
export 'src/access/inbound_kinds.dart' show InboundKinds;

// G.21 — history/ module: the brain's own running record of a conversation
// — `ConversationHistory` (raw window + pending batch + bounded
// `compactedSummary` + a durable append-only record), the `HistoryTurn` it
// holds (user prompt + brain answer + optional tool round), and the
// `HistorySizing` knobs. Declared in shared because the access layer's
// `SessionManager` produces and owns the store (hub § 22.3) while the engine
// reads it and drives compaction (`applyCompaction`, access § 21.10) — two
// components on one value/store contract, so it lives once in shared. The
// substrate call that rewrites the summary, and the model-config parse of the
// sizing knobs, stay with their owners (the engine, the procedure config).
export 'src/history/history.dart'
    show
        ConversationHistory,
        HistorySizing,
        HistoryTurn,
        conversationHistoriesEqual;
