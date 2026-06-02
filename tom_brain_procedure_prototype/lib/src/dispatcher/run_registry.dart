// `RunRegistry` — the dispatcher half of the `inflight` / `recent_runs`
// stack integration (Plan step D.26;
// `tom_brain_procedure_prototype_specification.md` § 8 (PE-4),
// `tom_brain_definition.md` § 7.2, § 7.4).
//
// ── Why a dispatcher-side registry at all (the PE-4 two halves) ──────
//
// PE-4 ("every run is recorded as a first-class memory object") has two
// halves. The *engine* half is the `RunRecorder` (C.31): it opens a
// memory trail, appends every primitive call, and persists the
// authoritative `ProcedureRun` node carrying the closed effort-metric
// set. The *dispatcher* half is this registry: it tracks, on the
// `inflight` / `recent_runs` bootstrap stacks, *which runs the
// coordinator currently has live*, so an operator (the Tom Forge run
// inspector) can see the runtime's shape without reaching into the
// engine.
//
// In the prototype the coordinator schedules opaque [RunBody] thunks
// (test bodies and the D.33 free-time scheduler stub) that do **not**
// yet drive the engine, so this registry is the only thing pushing a
// run onto `inflight` for coordinator-scheduled work. The reconciliation
// with the engine recorder — so that a *real* engine run dispatched
// through the coordinator does not land on `inflight` twice — is a
// D.36–D.46 concern (when the coordinator's bodies actually invoke the
// engine). See Q-D.26.1.
//
// ── What D.26 / D.27 own (this file) ────────────────────────────────
//
// [recordStart] (D.26) — persist a lightweight `status: running`
// `ProcedureRun` marker node and push its id onto the `inflight` stack,
// returning the marker id.
//
// [recordEnd] (D.27) — the run-end half: on success *or* failure, remove
// the running marker from `inflight` (membership only — the node stays)
// and push a `status: completed` / `failed` / `force_yielded`
// `ProcedureRun` marker onto `recent_runs`. The running marker id from
// [recordStart] is the handle the coordinator hands back here.
//
// ── Node shape ──────────────────────────────────────────────────────
//
// Both markers are the same `ProcedureRun` bootstrap node type (#13) the
// recorder uses, with the run/procedure identity and the coordinator slot
// the run occupied. The running marker carries `status: running` + a UTC
// `startedAt`; the finished marker carries the terminal `status` + a UTC
// `endedAt`. The memory store is immutable (overview principle 6): the
// running marker, the finished marker, and the recorder's authoritative
// finished `ProcedureRun` are distinct append-only events, exactly as the
// recorder's own two-node split (Q-C.31.1) already establishes.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show NodeDraft, Scope, TomBrainMemoryClient;
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../recorder/run_records.dart'
    show inflightStackName, procedureRunNodeType, recentRunsStackName;
import 'run_coordinator.dart' show RunSlot;

/// The launch facts the coordinator hands the registry when a run begins
/// occupying a slot (D.26).
///
/// [runId] is the coordinator-assigned run identity (threaded into the
/// `PreemptionController` record calls too); [procedureId] / [version]
/// name the procedure the run executes; [slot] is the coordinator slot
/// the run occupies, so concurrent foreground + background runs appear as
/// two distinguishable entries on `inflight` (D.28).
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

/// The terminal outcome a run reached when the coordinator freed its slot
/// (D.27), recorded as the finished marker's `status` on `recent_runs`.
///
/// Mirrors the three run-end paths the coordinator distinguishes: a body
/// that returned normally ([completed]), one that threw a non-deadline
/// error ([failed]), and one the coordinator's hard step deadline truncated
/// ([forceYielded]). The registry stays independent of the preemption
/// controller's `RunSlotOutcome`; the coordinator maps between them.
enum RunOutcome {
  /// The run body returned normally.
  completed,

  /// The run body threw a non-deadline error.
  failed,

  /// The coordinator's hard step deadline truncated the run.
  forceYielded;

  /// The string written to the finished marker's `status` field.
  String get status => switch (this) {
        RunOutcome.completed => 'completed',
        RunOutcome.failed => 'failed',
        RunOutcome.forceYielded => 'force_yielded',
      };
}

/// Tracks the coordinator's live runs on the `inflight` bootstrap stack
/// via the memory client (Plan D.26; spec § 8, PE-4 dispatcher half).
///
/// Wraps the interface-boundary [TomBrainMemoryClient] (PE-10) — never the
/// concrete store, never `tom_brain_memory/lib/src/`. The host injects
/// whichever implementation the deployment topology chose (in-process or
/// isolate-bridged); the registry cannot tell the difference.
final class RunRegistry {
  /// Wraps the interface-boundary [memory] client. [now] is the injectable
  /// clock; tests pass a fixed clock to assert the marker's `startedAt`.
  RunRegistry(this.memory, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  /// The memory client every write delegates to.
  final TomBrainMemoryClient memory;

  final DateTime Function() _now;

  /// Persists a `status: running` `ProcedureRun` marker for [registration]
  /// and pushes its id onto the `inflight` stack; returns the marker id.
  ///
  /// The marker id is the handle the run-end transition (D.27) will use to
  /// remove the run from `inflight` and push the authoritative finished
  /// record onto `recent_runs`. Both writes carry a [Scope] attributing
  /// them to the dispatcher and the run, so a write-budget tracker (A.68)
  /// and the trace stitcher can follow them back to the producing run.
  Future<NodeId> recordStart(RunRegistration registration) async {
    final scope = Scope(
      producer: 'dispatcher:${registration.procedureId}:${registration.runId}',
      runId: registration.runId,
    );
    final markerId = await memory.persist(
      NodeDraft(
        typeName: procedureRunNodeType,
        values: <String, Object?>{
          'procedureId': registration.procedureId,
          'version': registration.version,
          'runId': registration.runId,
          'slot': registration.slot.name,
          if (registration.parentRunId != null)
            'parentRunId': registration.parentRunId,
          'status': 'running',
          'startedAt': _now().toUtc().toIso8601String(),
        },
      ),
      scope: scope,
    );
    await memory.stacks.push(inflightStackName, markerId, scope: scope);
    return markerId;
  }

  /// Closes out the run [registration] started under [markerId] (D.27):
  /// removes the running marker from `inflight` and pushes a terminal
  /// `ProcedureRun` marker onto `recent_runs`; returns the finished marker id.
  ///
  /// Called on every run end — success ([RunOutcome.completed]), failure
  /// ([RunOutcome.failed]), or a coordinator deadline force-yield
  /// ([RunOutcome.forceYielded]). The running marker is removed from
  /// `inflight` by node id ([markerId], the [recordStart] return value);
  /// membership removal leaves the running node itself intact (the store is
  /// append-only — overview principle 6). A *distinct* finished marker node
  /// is persisted with the terminal `status` + a UTC `endedAt`, then pushed
  /// onto `recent_runs`. Both writes carry the same dispatcher-attributing
  /// [Scope] the start write used, so the trace stitcher follows them to the
  /// producing run.
  Future<NodeId> recordEnd(
    RunRegistration registration, {
    required NodeId markerId,
    required RunOutcome outcome,
  }) async {
    final scope = Scope(
      producer: 'dispatcher:${registration.procedureId}:${registration.runId}',
      runId: registration.runId,
    );
    // Pop the running marker from `inflight` (membership only — the node
    // stays addressable by id).
    await memory.stacks.remove(inflightStackName, markerId);
    final finishedId = await memory.persist(
      NodeDraft(
        typeName: procedureRunNodeType,
        values: <String, Object?>{
          'procedureId': registration.procedureId,
          'version': registration.version,
          'runId': registration.runId,
          'slot': registration.slot.name,
          if (registration.parentRunId != null)
            'parentRunId': registration.parentRunId,
          'status': outcome.status,
          'endedAt': _now().toUtc().toIso8601String(),
        },
      ),
      scope: scope,
    );
    await memory.stacks.push(recentRunsStackName, finishedId, scope: scope);
    return finishedId;
  }
}
