// ProcedureEngine — the engine's consumer-facing entry point (Plan step
// C.38; `tom_brain_procedure_prototype_specification.md` § 10.1, § 3, § 8).
//
// ── What invoke does ────────────────────────────────────────────────
//
// `invoke(ProcedureInvocation)` is the single seam the Phase D dispatcher
// drives a run through. For each invocation the engine:
//
//   1. resolves the procedure id → a `LoadedProcedure` (source + header)
//      through the injected resolver (C.25);
//   2. opens a `RunRecorder` (C.31) over the memory client, wiring its
//      `onEntry` observation seam to a live `Stream<TrailEntry>`;
//   3. boots a fresh sandboxed `D4rtDcliHost` (C.16) with the two brain
//      bridges and the engine-native primitives bound to *this* run — the
//      `note` primitive writes to this recorder, `runProcedure` recurses
//      back through the engine under the hard depth cap (C.19), and
//      `yield_if_foreground_waiting` reads the shared `PreemptionState`
//      (C.34/C.35);
//   4. runs the procedure source under a hard per-step `StepDeadline`
//      (C.36) — a step that overruns is force-yielded, recorded with a
//      `step_truncated` note, and the run closes `preempted` (the mapping
//      C.37 prototyped in a test double, now production here);
//   5. closes the recorder and resolves the handle's outcome.
//
// invoke returns a `ProcedureRun` *synchronously*; the pipeline runs on the
// event queue so a caller can subscribe to `run.trail` before the first
// entry is emitted.
//
// ── Cancellation + external timeout (C.39) ──────────────────────────
//
// `invoke` builds a `RunCancellation` per run and races the run's guarded
// step against its signal. A caller drives it two ways: explicitly
// (`run.cancel()`) or by passing `invoke(..., timeout: …)` so an elapsed
// wall-clock budget fires the signal. Either way the engine stops waiting on
// the step (the abandoned d4rt work may still finish, its result dropped),
// records a `run_cancelled` / `run_timed_out` trail note, and closes the run
// `aborted`. This is the external counterpart to the internal `StepDeadline`
// (C.36, which closes `preempted`).
//
// ── What C.39 deliberately does NOT own ─────────────────────────────
//
// Cancelling a parent abandons its whole sub-tree by abandoning the parent's
// step future; a nested `runProcedure` is not threaded its own cancellation
// (Q-C.39.2). The sugar aliases (`think`, `plan`, …) are C.40. The
// header → sandbox → contract
// validation gate (§ 7, validators built at C.27–C.30) is wired into the
// run path when `answer_with_memory_v1` lands (Phase D) and the strict
// `Future<ProcedureResult>` entry-point shape — including ProcedureResult
// bridging into d4rt — exists; until then a procedure's entry-point return
// is coerced (a `ProcedureResult` passes through; a `Map` becomes a
// succeeded result; see Q-C.38.2). C.38 owns the entry point, the run
// handle, and the outcome — the machinery that roundtrips a procedure.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemoryClient, TrailEntry, TrailOutcomeStatus;
import 'package:tom_brain_shared/tom_brain_shared.dart' show PreemptionState;

import '../bridges/memory_bridge.dart';
import '../bridges/substrate_bridge.dart';
import '../d4rt_host/d4rt_dcli_host.dart';
import '../preemption/step_deadline.dart';
import '../primitives_native/native_primitives_installer.dart';
import '../primitives_native/note_primitive.dart';
import '../primitives_native/run_procedure_primitive.dart';
import '../primitives_native/trail_note.dart';
import '../primitives_native/yield_primitive.dart';
import '../procedure_store/procedure_loader.dart';
import '../procedure_store/procedure_resolver.dart';
import '../recorder/run_records.dart';
import '../recorder/run_recorder.dart';
import 'procedure_inputs.dart';
import 'procedure_invocation.dart';
import 'procedure_outcome.dart';
import 'procedure_result.dart';
import 'procedure_run.dart';
import 'run_cancellation.dart';

/// The typed failure class a crashed run is recorded under (§ 10.4).
const String _runtimeCrashKind = 'procedure.runtime.crash';

/// Reserved entry-point return key a procedure body uses to report the ids of
/// the memory nodes it produced (D.39).
///
/// A body persists its result nodes itself (it has `mem.persist`), but it
/// cannot draw the `produced_by` edge to the run record — the authoritative
/// `ProcedureRun` node is only persisted at `complete()`, after the body
/// returns (recorder Q-C.31.1). The body therefore returns the produced node
/// ids under this key; the engine threads them into
/// `RunCompletion.producedNodeIds` (so the recorder draws the edges) and
/// strips the key from the procedure's declared outputs.
const String producedNodeIdsOutputKey = 'producedNodeIds';

/// The depth the top-level procedure of an `invoke` runs at (§ 5.1 / C.19).
const int _topLevelDepth = 1;

/// Resolves, runs, records, and hands back procedure runs.
///
/// One engine serves many invocations; it holds the shared, run-independent
/// collaborators (the resolver, the memory client, the two bridges, the
/// preemption state) and builds a fresh recorder + host per run so each run
/// owns its trail and its native-primitive bindings.
final class ProcedureEngine {
  /// Builds an engine over its shared collaborators.
  ///
  /// [resolver] resolves a procedure id to a loaded source (C.25).
  /// [memory] is the client the run recorder writes trails and run nodes
  /// to (C.31). [memoryBridge] / [substrateBridge] are the bridged effect
  /// surfaces a procedure script reaches (C.12/C.13). [preemptionState] is
  /// the shared cooperative-preemption state the dispatcher's coordinator
  /// drives (C.34); a fresh one is created when omitted. [stepDeadline] is
  /// the hard per-step wall-clock cap (C.36). [deadlineTimerFactory] is the
  /// injectable timer the deadline arms (tests drive it deterministically).
  /// [hardDepthCap] bounds the `runProcedure` chain (C.19).
  /// [cancellationTimerFactory] is the injectable timer the external-timeout
  /// path (C.39) arms (tests drive it deterministically). [now] / [newRunId]
  /// are injectable for deterministic tests.
  ProcedureEngine({
    required this.resolver,
    required this.memory,
    required this.memoryBridge,
    required this.substrateBridge,
    PreemptionState? preemptionState,
    Duration stepDeadline = defaultStepDeadline,
    DeadlineTimerFactory? deadlineTimerFactory,
    CancellationTimerFactory? cancellationTimerFactory,
    int hardDepthCap = RunProcedurePrimitive.defaultHardDepthCap,
    DateTime Function()? now,
    String Function()? newRunId,
  })  : preemptionState = preemptionState ?? PreemptionState(),
        _stepDeadlineLimit = stepDeadline,
        _deadlineTimerFactory = deadlineTimerFactory,
        _cancellationTimerFactory = cancellationTimerFactory,
        _hardDepthCap = hardDepthCap,
        _now = now ?? DateTime.now,
        _newRunId = newRunId ?? _defaultRunIdGenerator();

  /// Resolves a procedure id (and optional version) to a loaded source.
  final ProcedureResolver resolver;

  /// The memory client the recorder writes every run to.
  final TomBrainMemoryClient memory;

  /// The bridged memory surface a procedure script reaches as `mem`.
  final MemoryBridge memoryBridge;

  /// The bridged substrate surface a procedure script reaches as `sub`.
  final SubstrateBridge substrateBridge;

  /// The shared cooperative-preemption state the engine yields against and
  /// the dispatcher's coordinator drives.
  final PreemptionState preemptionState;

  final Duration _stepDeadlineLimit;
  final DeadlineTimerFactory? _deadlineTimerFactory;
  final CancellationTimerFactory? _cancellationTimerFactory;
  final int _hardDepthCap;
  final DateTime Function() _now;
  final String Function() _newRunId;

  /// Runs the procedure named by [invocation] and returns its handle.
  ///
  /// The handle's [ProcedureRun.trail] streams trail entries live; its
  /// [ProcedureRun.outcome] resolves to the terminal [ProcedureOutcome], and
  /// [ProcedureRun.cancel] abandons the run (C.39). Returns synchronously —
  /// the run pipeline is scheduled on the event queue so a caller can
  /// subscribe to the trail before the run advances. An unresolvable
  /// procedure id surfaces as an error on the outcome future (there is no run
  /// to record).
  ///
  /// When [timeout] is supplied the run is closed `aborted` if it has not
  /// finished within that wall-clock budget — the external counterpart to the
  /// internal per-step deadline (C.36). [timeout] must be strictly positive.
  ProcedureRun invoke(ProcedureInvocation invocation, {Duration? timeout}) {
    final runId = invocation.runId ?? _newRunId();
    final trail = StreamController<TrailEntry>.broadcast();
    final outcome = Completer<ProcedureOutcome>();
    final cancellation = RunCancellation(
      timeout: timeout,
      timerFactory: _cancellationTimerFactory,
    );

    unawaited(
      Future<void>(() async {
        try {
          final result = await _runInternal(
            runId: runId,
            procedureId: invocation.procedureId,
            version: invocation.version,
            inputs: invocation.inputs,
            arguments: invocation.arguments,
            parentRunId: invocation.parentRunId,
            depth: _topLevelDepth,
            onEntry: trail.add,
            cancellation: cancellation,
          );
          outcome.complete(result);
        } catch (error, stack) {
          outcome.completeError(error, stack);
        } finally {
          // Disarm a pending timeout timer once the run has resolved, so it
          // cannot fire against an already-closed run.
          cancellation.dispose();
          await trail.close();
        }
      }),
    );

    return ProcedureRun(
      runId: runId,
      procedureId: invocation.procedureId,
      trail: trail.stream,
      outcome: outcome.future,
      cancellation: cancellation,
    );
  }

  /// Resolves, runs, records, and closes one run (top-level or nested).
  ///
  /// [onEntry] is the live-trail seam — `trail.add` for the top-level run,
  /// `null` for a nested run (a nested run owns its own trail and is not
  /// surfaced on the parent's stream). [cancellation] is the C.39 cancel +
  /// external-timeout control — present for the top-level run, `null` for a
  /// nested run (cancelling a parent abandons its sub-tree by abandoning the
  /// parent's step future; see Q-C.39.2). Resolution failure propagates (the
  /// caller turns it into an outcome error); a procedure crash is caught,
  /// recorded as `errored`, and returned as an outcome carrying the error; a
  /// cancelled or timed-out run is closed `aborted`.
  Future<ProcedureOutcome> _runInternal({
    required String runId,
    required String procedureId,
    required int? version,
    required ProcedureInputs inputs,
    required Map<String, Object?> arguments,
    required String? parentRunId,
    required int depth,
    void Function(TrailEntry entry)? onEntry,
    RunCancellation? cancellation,
  }) async {
    final LoadedProcedure loaded = resolver.resolve(procedureId, version: version);
    final recorder = RunRecorder(memory, now: _now, onEntry: onEntry);

    final runPrimitive = RunProcedurePrimitive(
      executor: (call) => _executeNested(call, parentRunId: runId),
      hardDepthCap: _hardDepthCap,
      startDepth: depth,
    );
    final host = D4rtDcliHost(
      memoryBridge: memoryBridge,
      substrateBridge: substrateBridge,
      installNativePrimitives: nativePrimitivesInstaller(
        runProcedurePrimitive: runPrimitive,
        notePrimitive: NotePrimitive(sink: recorder.noteSink, now: _now),
        yieldPrimitive: YieldPrimitive(state: preemptionState),
      ),
    );

    await recorder.start(
      RunStart(
        procedureId: loaded.header.id,
        version: loaded.header.version,
        runId: runId,
        parentRunId: parentRunId,
        arguments: arguments,
      ),
    );

    final deadline = StepDeadline(
      limit: _stepDeadlineLimit,
      timerFactory: _deadlineTimerFactory,
    );

    // Race three outcomes: the deadline-guarded step settling (completed or
    // truncated), the step throwing (a crash), or the caller's cancellation /
    // timeout signal firing first (C.39).
    final _RunRace race;
    try {
      race = await _raceCancellable(
        deadline.guard<Object?>(
          host.run(loaded.source, inputs: <Object?>[inputs]),
        ),
        cancellation,
      );
    } catch (error) {
      // The procedure threw before the deadline: a runtime crash. Record it,
      // close the run as `errored`, and resolve the outcome carrying the
      // error so the caller (and any fallback executor, Phase D) sees it.
      await recorder.recordError(_runtimeCrashKind, '$error');
      final crashed = await recorder.complete(
        RunCompletion(
          status: TrailOutcomeStatus.errored,
          summary: 'procedure ${loaded.header.id} crashed',
        ),
      );
      return _outcomeOf(
        runId: runId,
        procedureId: loaded.header.id,
        record: crashed,
        entries: recorder.entries,
        result: null,
        error: error,
      );
    }

    if (race is _RaceCancelled) {
      // The caller cancelled or the run timed out before the step settled.
      // Disarm the (still-armed) deadline timer — its truncation no longer
      // matters — note the abandonment, and close the run `aborted`.
      deadline.cancel();
      final record = await _recordCancellation(
        recorder,
        cause: race.cause,
        timeout: cancellation?.timeout,
        procedureId: loaded.header.id,
      );
      return _outcomeOf(
        runId: runId,
        procedureId: loaded.header.id,
        record: record,
        entries: recorder.entries,
        result: null,
      );
    }

    final StepOutcome<Object?> step = (race as _RaceStep).step;
    switch (step) {
      case StepCompleted<Object?>(:final value):
        final producedNodeIds = _extractProducedNodeIds(value);
        final result = _coerceResult(value);
        final status = result.isSuccess
            ? TrailOutcomeStatus.accepted
            : TrailOutcomeStatus.errored;
        final record = await recorder.complete(
          RunCompletion(
            status: status,
            summary: result.isSuccess
                ? 'ran ${loaded.header.id} to completion'
                : 'procedure ${loaded.header.id} reported failure',
            producedNodeIds: producedNodeIds,
          ),
        );
        return _outcomeOf(
          runId: runId,
          procedureId: loaded.header.id,
          record: record,
          entries: recorder.entries,
          result: result,
        );

      case StepTruncated<Object?>(:final limit):
        recorder.note(
          TrailNote(
            category: stepTruncatedNoteCategory,
            recordedAt: _now(),
            payload: <String, Object?>{'limitMs': limit.inMilliseconds},
          ),
        );
        final record = await recorder.complete(
          RunCompletion(
            status: TrailOutcomeStatus.preempted,
            summary: 'step exceeded ${limit.inSeconds}s deadline',
          ),
        );
        return _outcomeOf(
          runId: runId,
          procedureId: loaded.header.id,
          record: record,
          entries: recorder.entries,
          result: null,
        );
    }
  }

  /// Races the deadline-guarded [guarded] step against [cancellation].
  ///
  /// Returns a [_RaceStep] when the step settles first (completed or
  /// truncated), or a [_RaceCancelled] when the cancellation / timeout signal
  /// fires first. A step that throws propagates the error (the caller maps it
  /// to a crash). When [cancellation] is `null` (a nested run, Q-C.39.2) there
  /// is nothing to race — the guarded step is awaited directly.
  Future<_RunRace> _raceCancellable(
    Future<StepOutcome<Object?>> guarded,
    RunCancellation? cancellation,
  ) {
    if (cancellation == null) {
      return guarded.then<_RunRace>(_RaceStep.new);
    }
    final race = Completer<_RunRace>();
    unawaited(
      guarded.then(
        (StepOutcome<Object?> step) {
          if (!race.isCompleted) race.complete(_RaceStep(step));
        },
        onError: (Object error, StackTrace stack) {
          if (!race.isCompleted) race.completeError(error, stack);
        },
      ),
    );
    unawaited(
      cancellation.signal.then((RunCancelCause cause) {
        if (!race.isCompleted) race.complete(_RaceCancelled(cause));
      }),
    );
    return race.future;
  }

  /// Notes the abandonment and closes an aborted run through the recorder.
  ///
  /// An explicit cancel records a [runCancelledNoteCategory] note; a timeout
  /// records a [runTimedOutNoteCategory] note carrying the breached
  /// `timeoutMs`. Both close the run on [TrailOutcomeStatus.aborted]
  /// (Q-C.39.1).
  Future<ProcedureRunRecord> _recordCancellation(
    RunRecorder recorder, {
    required RunCancelCause cause,
    required Duration? timeout,
    required String procedureId,
  }) async {
    final timedOut = cause == RunCancelCause.timedOut;
    recorder.note(
      TrailNote(
        category:
            timedOut ? runTimedOutNoteCategory : runCancelledNoteCategory,
        recordedAt: _now(),
        payload: <String, Object?>{
          if (timedOut && timeout != null) 'timeoutMs': timeout.inMilliseconds,
        },
      ),
    );
    return recorder.complete(
      RunCompletion(
        status: TrailOutcomeStatus.aborted,
        summary: timedOut
            ? 'run $procedureId timed out'
            : 'run $procedureId cancelled by caller',
      ),
    );
  }

  /// The `runProcedure` executor: recurses back through the engine to run a
  /// depth-validated nested call and returns its typed result.
  ///
  /// The depth was already checked against the cap by [RunProcedurePrimitive]
  /// before this runs. A nested run that fails or crashes surfaces here as a
  /// [ProcedureResult.failed]; richer error propagation up the chain is a
  /// later concern (the fallback executor, Phase D).
  Future<ProcedureResult> _executeNested(
    ProcedureCall call, {
    required String parentRunId,
  }) async {
    final outcome = await _runInternal(
      runId: _newRunId(),
      procedureId: call.id,
      version: call.version,
      inputs: call.inputs,
      arguments: call.inputs.toMap(),
      parentRunId: parentRunId,
      depth: call.depth,
    );
    return outcome.result ?? ProcedureResult.failed();
  }

  /// Coerces a procedure entry point's raw return into a [ProcedureResult].
  ///
  /// A `ProcedureResult` passes through unchanged. A `Map` becomes a
  /// succeeded result carrying its entries as outputs. Any other non-null
  /// value is wrapped under a single `value` output; `null` is an empty
  /// succeeded result. See Q-C.38.2: until ProcedureResult is bridged into
  /// d4rt, a script cannot construct one in-procedure, so the engine
  /// coerces; a procedure signals failure by throwing, not by returning a
  /// failed result.
  ProcedureResult _coerceResult(Object? raw) {
    if (raw is ProcedureResult) return raw;
    if (raw is Map) {
      final outputs = <String, Object?>{};
      raw.forEach((Object? key, Object? value) {
        // The reserved produced-node-ids channel (D.39) is consumed by
        // `_extractProducedNodeIds` and never surfaced as a declared output.
        if ('$key' == producedNodeIdsOutputKey) return;
        outputs['$key'] = value;
      });
      return ProcedureResult.succeeded(outputs: outputs);
    }
    if (raw == null) return ProcedureResult.succeeded();
    return ProcedureResult.succeeded(
      outputs: <String, Object?>{'value': raw},
    );
  }

  /// Reads the reserved [producedNodeIdsOutputKey] off a procedure's raw
  /// return (D.39): the ids of the memory nodes the body produced, which the
  /// recorder turns into `produced_by` edges to the run record. Returns an
  /// empty list when the body did not report any (every existing procedure
  /// other than `answer_with_memory_v1`).
  List<String> _extractProducedNodeIds(Object? raw) {
    if (raw is! Map) return const <String>[];
    for (final entry in raw.entries) {
      if ('${entry.key}' == producedNodeIdsOutputKey) {
        final value = entry.value;
        if (value is List) {
          return value.whereType<String>().toList(growable: false);
        }
        return const <String>[];
      }
    }
    return const <String>[];
  }

  ProcedureOutcome _outcomeOf({
    required String runId,
    required String procedureId,
    required ProcedureRunRecord record,
    required List<TrailEntry> entries,
    required ProcedureResult? result,
    Object? error,
  }) =>
      ProcedureOutcome(
        runId: runId,
        procedureId: procedureId,
        status: record.status,
        record: record,
        entries: entries,
        result: result,
        error: error,
      );

  /// A monotonic, process-unique run-id generator: `run_<micros>_<seq>`.
  static String Function() _defaultRunIdGenerator() {
    var sequence = 0;
    return () => 'run_${DateTime.now().microsecondsSinceEpoch}_${sequence++}';
  }
}

/// Which side of the cancel race won, for the step run inside `_runInternal`.
///
/// A sealed pair so the run path must handle both: the deadline-guarded step
/// settled ([_RaceStep]) or the cancellation / timeout signal fired first
/// ([_RaceCancelled]). A step that throws is not modelled here — it propagates
/// as an error and is caught as a crash.
sealed class _RunRace {
  const _RunRace();
}

/// The deadline-guarded step settled first; [step] is its outcome
/// (completed or truncated).
final class _RaceStep extends _RunRace {
  const _RaceStep(this.step);

  /// The settled step outcome.
  final StepOutcome<Object?> step;
}

/// The cancellation / timeout signal fired before the step settled; [cause]
/// is why the run was abandoned.
final class _RaceCancelled extends _RunRace {
  const _RaceCancelled(this.cause);

  /// Why the run was abandoned (explicit cancel vs. elapsed timeout).
  final RunCancelCause cause;
}
