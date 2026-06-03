// Barrel for the `trails/` module (A.23 layout; A.24 surface; A.46
// writer; A.47 store + events + outcome factory).
//
// At A.47 this barrel exports:
//
//   - `ProcedureRunRef` — handle passed to `openTrail`.
//   - `TrailEntry` + named constructors (`invocation`,
//     `primitiveCall`, `persist`, `note`, `error`, `outcome`) +
//     `TrailEntryKind`.
//   - `TrailOutcome` + `TrailOutcomeStatus`.
//   - `TrailWriter` — append-and-fsync JSONL writer over a single
//     date-sharded trail file (one per `ProcedureRun`).
//   - `SqliteTrailStore` — concrete `openTrail`/`appendTrail`/
//     `closeTrail`/`readTrail` lifecycle over `memory.db` + the
//     date-sharded JSONL tree. The store enforces the spec § 8.1
//     invariant: the `trails` index row is inserted only after the
//     first JSONL line is durable.
//   - `TrailOpened`, `TrailEntryAppended`, `TrailClosed`,
//     `TrailEntryCorrupted` — observability leaves of `MemoryEvent`.
//
// Wiring across later Phase A steps:
//
//   - A.48 — corruption-tolerant `readTrail` reader (streaming +
//     richer corruption diagnostics; today's `SqliteTrailStore`
//     emits `TrailEntryCorrupted` from a basic line-by-line parse).
//   - A.49 — append-fsync ordering + corruption + roundtrip tests
//     (some of which already land here at A.47 alongside the
//     contract surface).

export 'sqlite_trail_store.dart' show SqliteTrailStore;
// The trail record value types moved to `tom_brain_shared` at A.88
// (todo #16); re-exported here so the barrel keeps its surface. The
// JSONL writer, the SQLite store, and the event leaves stay here.
export 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        ProcedureRunRef,
        TrailEntry,
        TrailEntryKind,
        TrailOutcome,
        TrailOutcomeStatus;
export 'trail_events.dart'
    show
        TrailClosed,
        TrailEntryAppended,
        TrailEntryCorrupted,
        TrailOpened;
export 'trail_writer.dart' show TrailWriter;
