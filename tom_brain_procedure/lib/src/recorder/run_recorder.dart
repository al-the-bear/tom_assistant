// RunRecorder — opens a memory trail at procedure start, appends every
// primitive call, persists a `ProcedureRun` node at end, and moves it
// across the `inflight` → `recent_runs` stacks via the memory client
// (Plan step C.31; `tom_brain_procedure_specification.md` § 8).
//
// ── Lifecycle ───────────────────────────────────────────────────────
//
//   final recorder = RunRecorder(memory);
//   await recorder.start(RunStart(...));        // opens trail, inflight
//   await recorder.recordPrimitiveCall(...);    // one per bridged call
//   recorder.note(trailNote);                    // the C.20 note sink
//   final record = await recorder.complete(...); // persist + recent_runs
//
// One recorder instance records exactly one run. The engine (C.38)
// builds a fresh recorder per `runProcedure` level, so nested runs each
// own their trail and each leave their own marker on `inflight`.
//
// ── Why two `ProcedureRun` nodes (Q-C.31.1) ─────────────────────────
//
// The spec asks for two things that pull against each other: the run
// must be on `inflight` *at start* (so the operator can see it running),
// and the `ProcedureRun` node must carry the *final* effort-metric set,
// which is only known *at end*. Memory is append-only and immutable
// (overview principle 6) — a node persisted at start cannot later be
// updated with the effort it ended up spending. The recorder therefore
// writes two append-only records: a lightweight `status: running` marker
// persisted at start (its id is what `inflight` holds), and the
// authoritative final `ProcedureRun` persisted at completion (its id is
// what `recent_runs` holds, and the one the edges point at). At
// completion the marker is removed from `inflight`; the final record is
// pushed to `recent_runs`. This is consistent with the immutable-store
// model — the running marker and the finished run are distinct events.
//
// ── The note sink seam (shared with C.20) ───────────────────────────
//
// `NotePrimitive` (C.20) writes through a synchronous `TrailSink`
// callback. [noteSink] adapts this recorder to that seam: a `note(...)`
// call from a procedure becomes a `TrailEntryKind.note` line on the run's
// trail. The synchronous write-through is safe because each trail append
// records its side effect before its future yields.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show
        EdgeType,
        NodeDraft,
        ProcedureRunRef,
        Scope,
        TomBrainMemoryClient,
        TrailEntry,
        TrailEntryKind,
        TrailOutcome;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EffortMetrics, NodeId, TrailId, defaultNowUtc;

import '../primitives_native/trail_note.dart' show TrailNote, TrailSink;
import 'effort_accountant.dart';
import 'run_records.dart';

/// Records one procedure run end-to-end against a [TomBrainMemoryClient].
///
/// See the file header for the lifecycle and the two-node rationale. The
/// recorder keeps an in-memory, ordered view of every trail entry it
/// wrote ([entries]) so observers (and tests) can read the trail without
/// a memory round-trip.
final class RunRecorder {
  /// Wraps the interface-boundary [memory] client (PE-10). [now] is the
  /// injectable clock; tests pass a fixed clock to assert deterministic
  /// timestamps and elapsed times.
  ///
  /// [onEntry], when supplied, is called with every trail entry the
  /// recorder records — in the exact order they land on the trail
  /// (`invocation` first, then each primitive call / note, finally
  /// `outcome`). It is the observation seam the engine (C.38) wires a live
  /// `Stream<TrailEntry>` through, so a consumer can watch a run unfold
  /// without re-reading memory. It never blocks the recorder: the hook
  /// fires after the in-memory [entries] view is updated and is independent
  /// of the durable write.
  RunRecorder(
    this.memory, {
    DateTime Function()? now,
    EffortAccountant accountant = const EffortAccountant(),
    void Function(TrailEntry entry)? onEntry,
    void Function(Object error, StackTrace stackTrace)? onWriteError,
  })  : _now = now ?? defaultNowUtc,
        _accountant = accountant,
        _onEntry = onEntry,
        _onWriteError = onWriteError;

  /// The trail-entry kind recorded when a fire-and-forget `note(...)`
  /// write-through fails (E.3.1) — so a dropped note is never silent.
  static const String noteWriteFailedKind = 'recorder.note.write_failed';

  /// The memory client every write delegates to.
  final TomBrainMemoryClient memory;

  final DateTime Function() _now;

  /// Observation seam: notified of every recorded trail entry, in order.
  final void Function(TrailEntry entry)? _onEntry;

  /// Error sink for the fire-and-forget `note(...)` write-through (E.3.1).
  ///
  /// A note append cannot be awaited — the C.20 `TrailSink` is synchronous —
  /// so a failed durable write would otherwise be dropped silently (the
  /// `automation_candidate` signal the dispatcher's harvester keys on rides
  /// this path). When the write fails the recorder *always* surfaces a
  /// `noteWriteFailedKind` error entry into its in-memory view (so the loss
  /// shows on the live trail and the [_onEntry] seam) and, when this sink is
  /// supplied, also reports the raw error here so a composition root can
  /// route it to the engine event bus.
  final void Function(Object error, StackTrace stackTrace)? _onWriteError;

  /// Maps each recorded primitive call to its [EffortMetrics] delta
  /// (C.32). Injectable so a deployment can refine the accounting policy
  /// without re-touching the recorder; defaults to the standard rules.
  final EffortAccountant _accountant;

  /// The running effort total, folded one bridged-primitive call at a
  /// time as `recordPrimitiveCall` is invoked (C.32). `wallClockMs` stays
  /// zero here — the recorder stamps the run's measured elapsed at
  /// `complete`, never the sum of per-call latencies.
  EffortMetrics _accumulatedEffort = EffortMetrics.zero;

  final List<TrailEntry> _entries = <TrailEntry>[];

  RunStart? _start;
  DateTime? _startedAt;
  TrailId? _trailId;
  NodeId? _inflightMarkerId;
  bool _completed = false;

  /// Whether `start` has run and `complete` has not.
  bool get isOpen => _trailId != null && !_completed;

  /// The wall-clock instant `start` stamped, or `null` before `start`.
  ///
  /// The live-run registry reads this so `/check_usage` can measure how long
  /// the running prompt has been in flight (the recorder's own `wallClockMs`
  /// is only filled in at `complete`, so it is zero while the run is open).
  DateTime? get startedAt => _startedAt;

  /// Whether `complete` has run.
  bool get isCompleted => _completed;

  /// The effort accumulated from the bridged-primitive calls recorded so
  /// far (C.32). `wallClockMs` is always zero until `complete` stamps the
  /// run's measured elapsed; the counters reflect every call recorded via
  /// `recordPrimitiveCall`.
  EffortMetrics get accumulatedEffort => _accumulatedEffort;

  /// The open trail's id. Throws [StateError] before `start`.
  TrailId get trailId => _requireTrailId();

  /// The id of the `inflight` marker node. Throws before `start`.
  NodeId get inflightMarkerId =>
      _inflightMarkerId ?? (throw _notStarted());

  /// Ordered, read-only view of every trail entry written so far —
  /// `invocation` first, then each primitive call / note in order, and
  /// finally the `outcome` once `complete` has run.
  List<TrailEntry> get entries => List<TrailEntry>.unmodifiable(_entries);

  /// The synchronous sink the C.20 `NotePrimitive` writes through.
  ///
  /// Wire it as `NotePrimitive(sink: recorder.noteSink)`. Each note
  /// becomes a `TrailEntryKind.note` line carrying the note's category
  /// and payload.
  TrailSink get noteSink => note;

  /// Opens the run's trail, writes the `invocation` entry, persists the
  /// `inflight` marker, and pushes it onto the `inflight` stack.
  ///
  /// Throws [StateError] if called twice on the same recorder.
  Future<void> start(RunStart info) async {
    if (_start != null) {
      throw StateError('RunRecorder.start called twice for the same run.');
    }
    _start = info;
    final startedAt = _now();
    _startedAt = startedAt;

    final ref = ProcedureRunRef(
      procedureId: info.procedureId,
      runId: info.runId,
      parentRunId: info.parentRunId,
    );
    final trailId = await memory.openTrail(ref);
    _trailId = trailId;

    await _appendEntry(
      TrailEntry.invocation(info.arguments, at: startedAt),
    );

    final scope = _scope();
    final markerId = await memory.persist(
      NodeDraft(
        typeName: procedureRunNodeType,
        values: <String, Object?>{
          'procedureId': info.procedureId,
          'version': info.version,
          'runId': info.runId,
          if (info.parentRunId != null) 'parentRunId': info.parentRunId,
          'status': runStatusRunning,
          'startedAt': startedAt.toUtc().toIso8601String(),
          'trailId': trailId.value,
        },
      ),
      scope: scope,
    );
    _inflightMarkerId = markerId;

    await memory.stacks.push(inflightStackName, markerId, scope: scope);
  }

  /// Appends one bridged-primitive call to the run's trail.
  ///
  /// [primitive] is the call name (`recall`, `llm`, `persist`, …);
  /// [input] / [result] are the primitive's JSON-encodable argument and
  /// return maps; [elapsedMs] is the call's wall-clock cost when known.
  ///
  /// After the call is durably appended, its [EffortMetrics] delta (from
  /// the accountant — C.32) is folded into [accumulatedEffort]. Recording
  /// before `start` throws via `_appendEntry`, so accumulation only ever
  /// happens for a started recorder.
  Future<void> recordPrimitiveCall(
    String primitive,
    Map<String, Object?> input,
    Map<String, Object?> result, {
    int? elapsedMs,
  }) async {
    await _appendEntry(
      TrailEntry.primitiveCall(
        primitive,
        input,
        result,
        elapsedMs: elapsedMs,
        at: _now(),
      ),
    );
    _accumulatedEffort = _accumulatedEffort.plus(
      _accountant.classify(primitive, result: result),
    );
  }

  /// Appends a captured error to the run's trail. The run is still
  /// closed through `complete`; this only records the exception.
  Future<void> recordError(
    String errorKind,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
  }) =>
      _appendEntry(
        TrailEntry.error(errorKind, message, details: details, at: _now()),
      );

  /// The C.20 note sink. Appends [note] as a `TrailEntryKind.note` line.
  ///
  /// Synchronous to match `TrailSink`; the write-through future is fire-
  /// and-forget but its in-memory side effect ([entries]) is recorded
  /// before this returns, so ordering is observable immediately. A failed
  /// durable write is surfaced through [_onNoteWriteFailed] rather than
  /// dropped silently (E.3.1).
  void note(TrailNote note) {
    final trailId = _requireTrailId();
    final entry = TrailEntry(
      at: note.recordedAt,
      kind: TrailEntryKind.note,
      payload: <String, Object?>{
        'category': note.category,
        'payload': note.payload,
      },
    );
    _track(entry);
    unawaited(
      memory.appendTrail(trailId, entry).catchError(
        (Object error, StackTrace stack) =>
            _onNoteWriteFailed(note, error, stack),
      ),
    );
  }

  /// Surfaces a dropped `note(...)` write-through so it is never lost
  /// silently (E.3.1). The durable append failed; the recorder records the
  /// loss as an in-memory error entry (visible on the live trail and the
  /// [_onEntry] seam) and, when an `onWriteError` sink was supplied, reports
  /// the raw error so the composition root can route it onward.
  void _onNoteWriteFailed(TrailNote note, Object error, StackTrace stack) {
    _track(
      TrailEntry.error(
        noteWriteFailedKind,
        'failed to persist note "${note.category}": $error',
        details: <String, Object?>{'category': note.category},
        at: _now(),
      ),
    );
    _onWriteError?.call(error, stack);
  }

  /// Persists the authoritative final `ProcedureRun`, draws its edges,
  /// moves it from `inflight` to `recent_runs`, and closes the trail.
  ///
  /// Returns the durable [ProcedureRunRecord]. Throws [StateError] if
  /// `start` has not run or `complete` has already run.
  Future<ProcedureRunRecord> complete(RunCompletion completion) async {
    final info = _start;
    final startedAt = _startedAt;
    final trailId = _trailId;
    final markerId = _inflightMarkerId;
    if (info == null ||
        startedAt == null ||
        trailId == null ||
        markerId == null) {
      throw _notStarted();
    }
    if (_completed) {
      throw StateError('RunRecorder.complete called twice for the same run.');
    }

    final finishedAt = _now();
    final effort = _talliedEffort(completion, startedAt, finishedAt);
    final scope = _scope();

    // The in-flight marker MUST be cleared whichever way `complete` exits:
    // a partial failure between persisting the final node and the stack
    // move would otherwise strand a phantom running run that the
    // dispatcher's fallback monitor and free-time scheduler both read
    // (E.3.4). The `finally` removes it exactly once even if a step throws.
    var markerCleared = false;
    Future<void> clearInflightMarker() async {
      if (markerCleared) return;
      markerCleared = true;
      await memory.stacks.remove(inflightStackName, markerId);
    }

    try {
      final finalId = await memory.persist(
        NodeDraft(
          typeName: procedureRunNodeType,
          values: _finalRunValues(info, completion, startedAt, finishedAt,
              effort, trailId),
        ),
        scope: scope,
      );

      await _drawCompletionEdges(info, completion, finalId, scope);

      // Move across the run stacks: the marker leaves `inflight`, the
      // authoritative record lands on `recent_runs`.
      await clearInflightMarker();
      await memory.stacks.push(recentRunsStackName, finalId, scope: scope);

      // Close the trail. `closeTrail` synthesises the `outcome` JSONL line
      // in storage, so the recorder only mirrors it into its in-memory
      // view — it does not append it twice.
      final outcome = _completionOutcome(completion, effort);
      _track(TrailEntry.outcome(outcome, at: finishedAt));
      await memory.closeTrail(trailId, outcome);

      _completed = true;
      return ProcedureRunRecord(
        runNodeId: finalId,
        trailId: trailId,
        procedureId: info.procedureId,
        runId: info.runId,
        status: completion.status,
        effort: effort,
      );
    } finally {
      await clearInflightMarker();
    }
  }

  /// The run's final effort: everything the recorder accumulated per
  /// bridged-primitive call (C.32) plus anything the engine injects via
  /// `completion.effort` (counters the recorder could not observe, or an
  /// externally-measured wall clock). The wall clock is the run's measured
  /// elapsed unless a caller supplied a non-zero value.
  EffortMetrics _talliedEffort(
    RunCompletion completion,
    DateTime startedAt,
    DateTime finishedAt,
  ) {
    final measuredMs = finishedAt.difference(startedAt).inMilliseconds;
    final tallied = _accumulatedEffort.plus(completion.effort);
    return tallied.wallClockMs > 0
        ? tallied
        : tallied.withWallClockMs(measuredMs);
  }

  /// The field map of the authoritative final `ProcedureRun` node.
  Map<String, Object?> _finalRunValues(
    RunStart info,
    RunCompletion completion,
    DateTime startedAt,
    DateTime finishedAt,
    EffortMetrics effort,
    TrailId trailId,
  ) =>
      <String, Object?>{
        'procedureId': info.procedureId,
        'version': info.version,
        'runId': info.runId,
        if (info.parentRunId != null) 'parentRunId': info.parentRunId,
        'status': completion.status.name,
        'summary': completion.summary,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'finishedAt': finishedAt.toUtc().toIso8601String(),
        'effort': effort.toJson(),
        producedNodeIdsOutputKey:
            List<String>.unmodifiable(completion.producedNodeIds),
        'trailId': trailId.value,
      };

  /// Draws the completion edges: the run `derived_from` the procedure (when
  /// the procedure is a memory node), and each produced result node points
  /// `produced_by` back to the run.
  Future<void> _drawCompletionEdges(
    RunStart info,
    RunCompletion completion,
    NodeId finalId,
    Scope scope,
  ) async {
    final procedureNodeId = info.procedureNodeId;
    if (procedureNodeId != null) {
      await memory.edge(
        finalId,
        EdgeType.derivedFrom,
        procedureNodeId,
        scope: scope,
      );
    }
    for (final produced in completion.producedNodeIds) {
      await memory.edge(
        NodeId.fromString(produced),
        EdgeType.producedBy,
        finalId,
        scope: scope,
      );
    }
  }

  /// The terminal [TrailOutcome] mirrored into the closed trail.
  TrailOutcome _completionOutcome(
    RunCompletion completion,
    EffortMetrics effort,
  ) =>
      TrailOutcome(
        status: completion.status,
        summary: completion.summary,
        details: <String, Object?>{
          ...completion.details,
          'effort': effort.toJson(),
          if (completion.producedNodeIds.isNotEmpty)
            producedNodeIdsOutputKey:
                List<String>.unmodifiable(completion.producedNodeIds),
        },
        elapsedMs: effort.wallClockMs,
      );

  // ── internals ───────────────────────────────────────────────────

  Future<void> _appendEntry(TrailEntry entry) async {
    final trailId = _requireTrailId();
    _track(entry);
    await memory.appendTrail(trailId, entry);
  }

  /// Records [entry] in the in-memory view and notifies the [_onEntry]
  /// observation seam (C.38) in trail order. Kept as one helper so the
  /// in-memory order and the observed order can never drift apart.
  void _track(TrailEntry entry) {
    _entries.add(entry);
    _onEntry?.call(entry);
  }

  /// Write provenance for every memory write the recorder makes:
  /// `engine:<procedureId>:<runId>`, carrying the run id so the write is
  /// attributable even where the producer is shared.
  Scope _scope() {
    final info = _start!;
    return Scope(
      producer: 'engine:${info.procedureId}:${info.runId}',
      runId: info.runId,
    );
  }

  TrailId _requireTrailId() => _trailId ?? (throw _notStarted());

  StateError _notStarted() =>
      StateError('RunRecorder used before start() / after it failed.');
}
