// Trail value types — append-only per-run audit log
// (memory_specification.md § 8).
//
// One `Trail` is opened per `ProcedureRun`. Memory provides the
// storage (JSONL with fsync per append + a `Trail` index row in
// `memory.db`); the engine drives the lifecycle:
//
//   final tid = await memory.openTrail(runRef);
//   await memory.appendTrail(tid, TrailEntry.invocation(args));
//   await memory.appendTrail(tid, TrailEntry.primitiveCall(...));
//   ...
//   await memory.closeTrail(tid, outcome);
//
// At A.24 only the value types exist. The writer / reader land at
// A.46 – A.49.

/// Reference to the procedure run a trail belongs to.
///
/// The procedure-engine identity (a `ProcedureId`) plus the
/// concrete run identity (an opaque ULID-shaped string assigned by
/// the engine). Memory does not generate the run id — the engine
/// does, because runs span more than memory.
final class ProcedureRunRef {
  /// Procedure id (e.g. `p_answer_with_memory_v1`).
  final String procedureId;

  /// Opaque run id assigned by the engine at dispatch.
  final String runId;

  /// Parent run id when this run was dispatched from another
  /// procedure (sub-procedure). `null` for top-level runs.
  final String? parentRunId;

  const ProcedureRunRef({
    required this.procedureId,
    required this.runId,
    this.parentRunId,
  });
}

/// Outcome record written at `closeTrail`.
///
/// `status` is the structural outcome; `summary` is a short
/// human-readable line (one sentence) that surfaces in inspectors
/// and the recent-runs stack peek.
final class TrailOutcome {
  /// Structural outcome — one of `accepted`, `rejected`, `aborted`,
  /// `errored`, `preempted`, `budgetExceeded`.
  final TrailOutcomeStatus status;

  /// Short human-readable line.
  final String summary;

  /// Optional structured detail. JSON-encodable values only.
  final Map<String, Object?> details;

  /// Wall-clock elapsed for the whole run, in milliseconds.
  final int elapsedMs;

  TrailOutcome({
    required this.status,
    required this.summary,
    Map<String, Object?> details = const <String, Object?>{},
    this.elapsedMs = 0,
  }) : details = Map<String, Object?>.unmodifiable(details);

  /// The canonical JSON shape of this outcome.
  ///
  /// Single source of the `status` / `summary` / (`details`) /
  /// `elapsedMs` map. Both consumers — the `outcome` JSONL line
  /// ([TrailEntry.outcome]) and the `trails.outcome` column written
  /// by `closeTrail` — call this so the on-disk file and the
  /// `memory.db` index row can never drift.
  Map<String, Object?> toJson() => <String, Object?>{
        'status': status.name,
        'summary': summary,
        if (details.isNotEmpty) 'details': details,
        'elapsedMs': elapsedMs,
      };
}

/// Structural outcome kinds.
enum TrailOutcomeStatus {
  /// Run produced an accepted result.
  accepted,

  /// Run produced a result that the critique rejected.
  rejected,

  /// Run was aborted by the caller (cooperative cancel).
  aborted,

  /// Run threw an unhandled exception.
  errored,

  /// Run was preempted by a higher-priority foreground waiter
  /// (procedure_specification.md § 8 preemption).
  preempted,

  /// Run hit a `BudgetExceeded` and aborted.
  budgetExceeded,
}

/// Entry kind discriminator. Names match § 8.2.
enum TrailEntryKind {
  invocation,
  primitiveCall,
  persist,
  edge,
  stackPush,
  note,
  subProcedure,
  error,
  yield_,
  outcome,
}

/// One JSONL line in a trail file.
///
/// The named constructors mirror § 8.1's example call sites.
final class TrailEntry {
  /// Wall-clock UTC timestamp of the entry.
  final DateTime at;

  /// Kind discriminator.
  final TrailEntryKind kind;

  /// JSON-encodable payload. Shape depends on [kind] — the
  /// concrete schema per kind is documented in spec § 8.2.
  final Map<String, Object?> payload;

  const TrailEntry({
    required this.at,
    required this.kind,
    required this.payload,
  });

  /// `invocation` entry — written by the engine when a run begins.
  /// Records the bound argument map.
  factory TrailEntry.invocation(
    Map<String, Object?> arguments, {
    DateTime? at,
  }) =>
      TrailEntry(
        at: (at ?? DateTime.now()).toUtc(),
        kind: TrailEntryKind.invocation,
        payload: <String, Object?>{'arguments': arguments},
      );

  /// `primitiveCall` entry — one call into the bridged API
  /// (`recall`, `think`, `persist`, ...).
  factory TrailEntry.primitiveCall(
    String primitive,
    Map<String, Object?> input,
    Map<String, Object?> result, {
    int? elapsedMs,
    DateTime? at,
  }) =>
      TrailEntry(
        at: (at ?? DateTime.now()).toUtc(),
        kind: TrailEntryKind.primitiveCall,
        payload: <String, Object?>{
          'primitive': primitive,
          'input': input,
          'result': result,
          'elapsedMs': ?elapsedMs,
        },
      );

  /// `persist` entry — records a node that was written. The node id
  /// is the stable handle; the rest is on the node itself.
  factory TrailEntry.persist(String nodeId, {DateTime? at}) => TrailEntry(
        at: (at ?? DateTime.now()).toUtc(),
        kind: TrailEntryKind.persist,
        payload: <String, Object?>{'nodeId': nodeId},
      );

  /// `note` entry — free-form annotation from inside the procedure.
  factory TrailEntry.note(String message, {DateTime? at}) => TrailEntry(
        at: (at ?? DateTime.now()).toUtc(),
        kind: TrailEntryKind.note,
        payload: <String, Object?>{'message': message},
      );

  /// `error` entry — captured exception with kind + message.
  factory TrailEntry.error(
    String errorKind,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
    DateTime? at,
  }) =>
      TrailEntry(
        at: (at ?? DateTime.now()).toUtc(),
        kind: TrailEntryKind.error,
        payload: <String, Object?>{
          'errorKind': errorKind,
          'message': message,
          if (details.isNotEmpty) 'details': details,
        },
      );

  /// `outcome` entry — synthesised by `closeTrail` from the
  /// caller-supplied [TrailOutcome]. Always the last line of a
  /// closed trail. Carrying the outcome as a regular JSONL line
  /// (rather than as a SQLite-only column) means a readback over a
  /// trail file alone is sufficient to reconstruct the full run
  /// without consulting `memory.db` — which is what corruption-
  /// tolerant inspectors and offline forensic tooling rely on.
  factory TrailEntry.outcome(TrailOutcome outcome, {DateTime? at}) =>
      TrailEntry(
        at: (at ?? DateTime.now()).toUtc(),
        kind: TrailEntryKind.outcome,
        payload: outcome.toJson(),
      );
}
