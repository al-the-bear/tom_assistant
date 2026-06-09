// `RunRegistry` — the dispatcher half of the `inflight` / `recent_runs`
// stack integration (Plan step D.26;
// `tom_brain_procedure_specification.md` § 8 (PE-4),
// `tom_brain_definition.md` § 7.2, § 7.4).
//
// ── Why a dispatcher-side registry at all (the PE-4 two halves) ──────
//
// PE-4 ("every run is recorded as a first-class memory object") has two
// halves. The *engine* half is the `RunRecorder` (C.31): it opens a
// memory trail, appends every primitive call, and persists the
// authoritative `ProcedureRun` node carrying the closed effort-metric
// set, pushed onto the `inflight` bootstrap stack at run start and moved
// to `recent_runs` at run end. The recorder is the **canonical and sole
// writer** of `ProcedureRun` nodes.
//
// The *dispatcher* half is this registry, and per Q-D.26.1 it is an
// **in-memory slot-occupancy view**, not a second `ProcedureRun` writer.
// It projects which coordinator slot (foreground / background) currently
// holds which run — operator-visibility state the recorder does not
// capture, and that lives only as long as the run occupies the slot. A
// real engine run dispatched through the coordinator therefore lands on
// `inflight` exactly once (the recorder writes it); the registry never
// touches memory, so the two-writer collision the earlier D.26 framing
// risked cannot occur.
//
// ── Why a view and not a durable second stack ───────────────────────
//
// Slot occupancy is ephemeral: it answers "what is the coordinator
// running *right now*", a question whose entire lifetime is bounded by
// the run's slot occupancy. Persisting it would duplicate facts the
// recorder already owns durably (the `ProcedureRun` node, its `inflight`
// membership, its `recent_runs` move) and reintroduce the very
// two-writer reconciliation Q-D.26.1 closes. The view holds the launch
// facts in a `Map<RunSlot, RunRegistration>`, set on run start and
// cleared on run end — no memory write, no held future, no node id to
// thread back.

import 'run_coordinator.dart' show RunSlot;

/// The launch facts the coordinator hands the registry when a run begins
/// occupying a slot (D.26).
///
/// [runId] is the coordinator-assigned run identity (threaded into the
/// `PreemptionController` record calls too); [procedureId] / [version]
/// name the procedure the run executes; [slot] is the coordinator slot
/// the run occupies, so a concurrent foreground + background pair appears
/// as two distinguishable occupancy entries (D.28).
final class RunRegistration {
  /// Builds the launch facts.
  const RunRegistration({
    required this.runId,
    required this.procedureId,
    required this.slot,
    this.version = 1,
    this.parentRunId,
  });

  /// Coordinator-assigned run id.
  final String runId;

  /// Procedure id this run executes (e.g. `answer_with_memory_v1`).
  final String procedureId;

  /// Resolved procedure version.
  final int version;

  /// The coordinator slot the run occupies.
  final RunSlot slot;

  /// Parent run id when this run was dispatched from another; `null` for
  /// top-level runs.
  final String? parentRunId;
}

/// An in-memory view of which coordinator slot currently holds which run
/// (Plan D.26; spec § 8, PE-4 dispatcher half; Q-D.26.1).
///
/// This is a *view*, not a writer: it never touches the memory store. The
/// engine-side `RunRecorder` (C.31) is the canonical and sole writer of
/// `ProcedureRun` nodes to `inflight` / `recent_runs`. The registry only
/// projects, for an operator (the Tom Forge run inspector), which run each
/// coordinator slot holds for as long as it holds it.
///
/// One run occupies one slot; a slot holds at most one run. The coordinator
/// calls [recordStart] when a run takes its slot and [recordEnd] when the
/// run releases it. Both are synchronous in-memory mutations.
final class RunRegistry {
  /// The launch facts of the run currently occupying each slot. A slot is
  /// absent from the map when no run holds it.
  final Map<RunSlot, RunRegistration> _occupancy =
      <RunSlot, RunRegistration>{};

  /// A read-only snapshot of the current slot occupancy, keyed by the
  /// coordinator slot each live run holds.
  Map<RunSlot, RunRegistration> get occupancy =>
      Map<RunSlot, RunRegistration>.unmodifiable(_occupancy);

  /// The run currently occupying [slot], or `null` when the slot is free.
  RunRegistration? occupant(RunSlot slot) => _occupancy[slot];

  /// The launch facts of every run the coordinator currently has live, in
  /// no defined order.
  Iterable<RunRegistration> get liveRuns => _occupancy.values;

  /// Whether any run currently occupies a slot.
  bool get isIdle => _occupancy.isEmpty;

  /// Records that [registration] has taken its slot — the run start half of
  /// the dispatcher view (D.26).
  ///
  /// Overwrites any stale occupant of the same slot: the coordinator only
  /// admits a run to a slot the previous occupant has already released, so a
  /// collision here would be a coordinator bug, and last-write-wins keeps the
  /// view consistent with the coordinator's own slot state rather than
  /// masking the bug behind a thrown error the view has no way to recover.
  void recordStart(RunRegistration registration) {
    _occupancy[registration.slot] = registration;
  }

  /// Records that the run occupying [slot] has released it — the run-end half
  /// of the dispatcher view (D.27).
  ///
  /// Called on every run end (success, failure, *or* a coordinator
  /// hard-step-deadline force-yield); the outcome is irrelevant to occupancy,
  /// which only tracks *whether* a slot is held. Idempotent: clearing an
  /// already-free slot is a no-op, so a double run-end signal cannot corrupt
  /// the view.
  void recordEnd(RunSlot slot) {
    _occupancy.remove(slot);
  }
}
