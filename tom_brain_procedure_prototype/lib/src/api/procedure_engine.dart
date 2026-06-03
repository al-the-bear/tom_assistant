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
// (Q-C.39.2). The sugar aliases (`think`, `plan`, …) are C.40.
//
// ── Sandbox gate (§ 7, PE-1) ────────────────────────────────────────
//
// Every resolved procedure clears the static `SandboxValidator` before the
// host is built (`_runInternal`, right after `resolver.resolve`). The
// validator allows an `import` only of the host-injected bridge / input /
// engine-native libraries and bans `export` and the SDK-gateway identifiers
// (E.3.5 reconciled the old blanket import ban with the host's
// import-to-reach-`mem`/`sub` convention, Q-D.37.1). A violation propagates
// like a resolution failure — surfaced as an outcome error, no run recorded.
// The strict `Future<ProcedureResult>` entry-point shape — including
// ProcedureResult bridging into d4rt — does not yet exist, so a procedure's
// entry-point return is still coerced (a `ProcedureResult` passes through; a
// `Map` becomes a succeeded result; see Q-C.38.2). C.38 owns the entry point,
// the run handle, and the outcome — the machinery that roundtrips a procedure.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemoryClient, TrailEntry, TrailOutcomeStatus;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show PreemptionState, defaultNowUtc;

import '../bridges/memory_bridge.dart';
import '../bridges/substrate_bridge.dart';
import '../budget/budget.dart';
import '../d4rt_host/d4rt_dcli_host.dart';
import '../d4rt_host/procedure_parse_exception.dart';
import '../preemption/step_deadline.dart';
import '../primitives_native/emit_primitive.dart';
import '../primitives_native/native_primitives_installer.dart';
import '../primitives_native/note_primitive.dart';
import '../primitives_native/run_procedure_primitive.dart';
import '../primitives_native/trail_note.dart';
import '../primitives_native/yield_primitive.dart';
import '../procedure_store/procedure_loader.dart';
import '../procedure_store/procedure_resolver.dart';
import '../recorder/run_records.dart';
import '../recorder/run_recorder.dart';
import '../validator/sandbox_validator.dart';
import 'procedure_inputs.dart';
import 'procedure_invocation.dart';
import 'procedure_outcome.dart';
import 'procedure_result.dart';
import 'procedure_run.dart';
import 'run_cancellation.dart';

/// The typed failure class a crashed run is recorded under (§ 10.4).
const String _runtimeCrashKind = 'procedure.runtime.crash';

/// The typed failure class a source-parse failure is recorded under (§ 10.4).
///
/// Distinct from [_runtimeCrashKind] because the two route differently for
/// version-chain fallback: a runtime crash steps the chain to an older
/// version, a parse failure does not (an older version cannot repair a
/// syntactically broken newer source). Collapsing them would trigger a wrong
/// fallback on a parse error (Q-C.46.1).
const String _parseFailedKind = 'procedure.parse.failed';

/// The typed failure class an uncaught budget refusal is recorded under
/// (PE-8, § 14). Distinct from a crash: a refused call is a deliberate stop,
/// so the run closes `budgetExceeded` (not `errored`) and the version chain is
/// never stepped (an older version would hit the same cap). A procedure that
/// *catches* `ProcedureBudgetExceeded` never reaches this path — it adapts and
/// resolves normally.
const String _budgetExceededKind = ProcedureBudgetExceeded.errorKind;

// `producedNodeIdsOutputKey` — the reserved produced-node-ids key the engine
// splits off a body's outputs — is owned by `recorder/run_records.dart` (the
// recorder writes the matching `ProcedureRun` field), and is in scope here
// through the `run_records.dart` import above.

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
    this.validator = SandboxValidator.shared,
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
        _now = now ?? defaultNowUtc,
        _newRunId = newRunId ?? _defaultRunIdGenerator();

  /// Resolves a procedure id (and optional version) to a loaded source.
  final ProcedureResolver resolver;

  /// The memory client the recorder writes every run to.
  final TomBrainMemoryClient memory;

  /// The static sandbox gate every resolved procedure clears before it runs.
  ///
  /// PE-1's static half (§ 7): a procedure whose source imports a library
  /// outside the host-injected bridge / input / engine-native set, or names a
  /// disallowed SDK identifier, is rejected before any effect surface is built
  /// — the violation surfaces as an outcome error and no run is recorded, the
  /// same shape as an unresolvable id. The host's doc states the validator
  /// "gates source *before* it reaches here"; this is where that gate lives
  /// (Q-D.37.1). Defaults to [SandboxValidator.shared].
  final SandboxValidator validator;

  /// Template for the bridged memory surface a procedure script reaches as
  /// `mem`. Its `client` is rebound to a per-run recording bridge in
  /// `_runInternal` (E.3.2); the template instance itself is never
  /// dispatched through.
  final MemoryBridge memoryBridge;

  /// Template for the bridged substrate surface a procedure script reaches
  /// as `sub`. Its `client` is rebound to a per-run recording bridge in
  /// `_runInternal` (E.3.2); the template instance itself is never
  /// dispatched through.
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
  ///
  /// When [tokenSink] is supplied (the external/user request path, P1.3 #8)
  /// the engine binds it both to the per-run substrate bridge (every
  /// `sub.llm(...)` chunk is forwarded as it arrives) and to the `emit`
  /// primitive (text the body authors itself), so the run streams its answer
  /// increment-by-increment rather than only returning a whole-text result.
  /// Left `null` for an internal secondary / free-time run, where the
  /// substrate forwarding and `emit` both fall back to buffer-only no-ops.
  /// A [tokenSink] is bound only to the top-level run; nested `runProcedure`
  /// calls do not inherit it (the answer is streamed by the top-level body).
  ProcedureRun invoke(
    ProcedureInvocation invocation, {
    Duration? timeout,
    OutboundDeltaSink? tokenSink,
  }) {
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
            tokenSink: tokenSink,
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
  /// classified (`procedure.parse.failed` for a source-parse failure,
  /// `procedure.runtime.crash` otherwise — Q-C.46.1), recorded as `errored`,
  /// and returned as an outcome carrying the error; a cancelled or timed-out
  /// run is closed `aborted`.
  ///
  /// [tokenSink] is the per-run outbound channel (P1.3 #8) — bound to the
  /// substrate bridge's `onToken` and the `emit` primitive's sink for the
  /// top-level external run, `null` for a nested run (the top-level body owns
  /// the answer stream; a nested `runProcedure` does not re-stream).
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
    OutboundDeltaSink? tokenSink,
  }) async {
    final LoadedProcedure loaded = resolver.resolve(procedureId, version: version);

    // Static sandbox gate (§ 7, PE-1): a procedure that imports outside the
    // host-injected surface or names a disallowed identifier never reaches the
    // host. A violation propagates like a resolution failure — surfaced as an
    // outcome error, with no run recorded (the procedure never started).
    validator.validate(loaded);

    final recorder = RunRecorder(memory, now: _now, onEntry: onEntry);

    // Bind the bridges to *this* run's recorder so every effect call lands on
    // the run's trail and folds into its effort tally (E.3.2). The engine's
    // `memoryBridge` / `substrateBridge` are shared templates; dispatching
    // through them directly would force one mutable observer across concurrent
    // runs, so a fresh recording instance over the same client is built per
    // run (the deferred composition-root wiring, Q-C.44.1).
    final recordCall = recorder.recordPrimitiveCall;

    // One budget ledger over this run's header budget, shared by both bridges
    // so token / tool-call / memory-write spend accumulates in a single place
    // across memory and substrate calls (PE-8). `null` when the budget
    // enforces no count/spend cap (a wall-clock-only budget — the deadline
    // owns that), so the bridges keep their zero-overhead fast path.
    final ledger = BudgetLedger(loaded.header.budget);
    final runBudget = ledger.enforces ? ledger : null;

    final runMemoryBridge =
        MemoryBridge(memoryBridge.client, onCall: recordCall, budget: runBudget);
    // Bind the run's outbound channel (P1.3 #8) to both halves of the
    // streaming seam: the substrate bridge forwards each `sub.llm(...)` chunk
    // through `onToken`, and the `emit` primitive forwards text the body
    // authors itself — the same closure on both so they share one ordered
    // wire. `null` on a nested or internal run leaves both buffer-only.
    final runSubstrateBridge = SubstrateBridge(
      substrateBridge.client,
      onCall: recordCall,
      onToken: tokenSink,
      budget: runBudget,
    );

    final runPrimitive = RunProcedurePrimitive(
      executor: (call) => _executeNested(call, parentRunId: runId),
      hardDepthCap: _hardDepthCap,
      startDepth: depth,
    );
    final host = D4rtDcliHost(
      memoryBridge: runMemoryBridge,
      substrateBridge: runSubstrateBridge,
      installNativePrimitives: nativePrimitivesInstaller(
        runProcedurePrimitive: runPrimitive,
        notePrimitive: NotePrimitive(sink: recorder.noteSink, now: _now),
        yieldPrimitive: YieldPrimitive(state: preemptionState),
        emitPrimitive: EmitPrimitive(sink: tokenSink),
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
    } on ProcedureBudgetExceeded catch (error) {
      // An *uncaught* budget refusal (PE-8): a bridged call exceeded an
      // applicable header-budget cap and the procedure did not catch it. This
      // is a deliberate stop, not a crash — the run closes `budgetExceeded`
      // (not `errored`), and the fallback executor surfaces the error without
      // stepping the version chain (an older version would hit the same cap).
      // A procedure that *catches* `ProcedureBudgetExceeded` adapts inside its
      // own body and never reaches here.
      await recorder.recordError(_budgetExceededKind, '$error');
      final aborted = await recorder.complete(
        RunCompletion(
          status: TrailOutcomeStatus.budgetExceeded,
          summary: 'procedure ${loaded.header.id} exceeded its '
              '${error.dimension.name} budget',
        ),
      );
      return _outcomeOf(
        runId: runId,
        procedureId: loaded.header.id,
        record: aborted,
        entries: recorder.entries,
        result: null,
        error: error,
      );
    } catch (error) {
      // The step threw before the deadline. Classify it: a source-parse
      // failure (the procedure never ran — the host raises
      // `ProcedureSourceParseException`) is `procedure.parse.failed`; any other
      // uncaught error mid-execution is a `procedure.runtime.crash`. The two
      // route differently for version-chain fallback (§ 10.4) — only a runtime
      // crash steps the chain — so collapsing them would wrongly fall back on
      // a parse error (Q-C.46.1). Either way the run closes `errored` and the
      // outcome carries the error so the caller (and the Phase-D fallback
      // executor) sees the typed class.
      final isParseFailure = error is ProcedureSourceParseException;
      await recorder.recordError(
        isParseFailure ? _parseFailedKind : _runtimeCrashKind,
        '$error',
      );
      final crashed = await recorder.complete(
        RunCompletion(
          status: TrailOutcomeStatus.errored,
          summary: isParseFailure
              ? 'procedure ${loaded.header.id} failed to parse'
              : 'procedure ${loaded.header.id} crashed',
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
        final (:result, :producedNodeIds) = _coerceReturn(value);
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

  /// Coerces a procedure entry point's raw return into a [ProcedureResult]
  /// and, in the same pass, extracts the reserved produced-node-ids channel.
  ///
  /// Coercion rules: a `ProcedureResult` passes through unchanged (it carries
  /// no produced-node-ids channel, so the list is empty). A `Map` becomes a
  /// succeeded result carrying its entries as outputs — except the reserved
  /// [producedNodeIdsOutputKey] (D.39), which is split off as the list of
  /// node ids the body produced and never surfaced as a declared output. Any
  /// other non-null value is wrapped under a single `value` output; `null` is
  /// an empty succeeded result.
  ///
  /// See Q-C.38.2: until ProcedureResult is bridged into d4rt, a script cannot
  /// construct one in-procedure, so the engine coerces; a procedure signals
  /// failure by throwing, not by returning a failed result. Returning both
  /// halves from one map walk keeps the produced-node-ids extraction
  /// (consumed for `produced_by` edges) and the output coercion in lockstep —
  /// they previously walked the same map twice (E.2.1).
  ({ProcedureResult result, List<String> producedNodeIds}) _coerceReturn(
    Object? raw,
  ) {
    if (raw is ProcedureResult) {
      return (result: raw, producedNodeIds: const <String>[]);
    }
    if (raw is Map) {
      final outputs = <String, Object?>{};
      var producedNodeIds = const <String>[];
      raw.forEach((Object? key, Object? value) {
        if ('$key' == producedNodeIdsOutputKey) {
          if (value is List) {
            producedNodeIds = value.whereType<String>().toList(growable: false);
          }
          return;
        }
        outputs['$key'] = value;
      });
      return (
        result: ProcedureResult.succeeded(outputs: outputs),
        producedNodeIds: producedNodeIds,
      );
    }
    if (raw == null) {
      return (
        result: ProcedureResult.succeeded(),
        producedNodeIds: const <String>[],
      );
    }
    return (
      result: ProcedureResult.succeeded(
        outputs: <String, Object?>{'value': raw},
      ),
      producedNodeIds: const <String>[],
    );
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
