// C.38 — ProcedureEngine.invoke acceptance suite.
//
// Plan step C.38 (verbatim): "Implement `ProcedureEngine.invoke(
// ProcedureInvocation, …)` — the dispatcher's entry point. Returns a
// `ProcedureRun` handle that streams trail entries and resolves to a
// `ProcedureOutcome`."
//
// These tests drive the engine the way the Phase D dispatcher will: build
// a `ProcedureInvocation`, call `invoke`, watch `run.trail`, and read
// `run.outcome`. Each group pins one promise of the entry point:
//
//   1. ROUNDTRIP   — a trivial procedure runs end-to-end; the outcome
//                    resolves `accepted` with the coerced result, and the
//                    durable run record is on `recent_runs`.
//   2. TRAIL       — the handle's stream emits the run's trail in order
//                    (`invocation` first, `outcome` last), live.
//   3. DEADLINE    — a step that overruns the `StepDeadline` is recorded
//                    `preempted` with a `step_truncated` note (the mapping
//                    C.37 prototyped in a test double, now production).
//   4. CRASH       — a procedure that throws closes `errored`, carrying the
//                    captured error.
//   5. RESOLUTION  — an unresolvable id surfaces as an error on the outcome
//                    future (there is no run to record).
//   6. NESTED      — a procedure that calls `runProcedure` runs the child
//                    through the engine and threads its result back.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late _StatefulMemory memory;
  late _ControllableSubstrate substrate;
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memory = _StatefulMemory();
    substrate = _ControllableSubstrate();
    memoryBridge = MemoryBridge(memory);
    substrateBridge = SubstrateBridge(substrate);
  });

  ProcedureEngine engineFor(
    Iterable<LoadedProcedure> procedures, {
    Duration stepDeadline = defaultStepDeadline,
    DeadlineTimerFactory? deadlineTimerFactory,
    CancellationTimerFactory? cancellationTimerFactory,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        stepDeadline: stepDeadline,
        deadlineTimerFactory: deadlineTimerFactory,
        cancellationTimerFactory: cancellationTimerFactory,
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  /// A procedure whose only step awaits a never-completing `sub.llm(...)`, so
  /// the step never settles on its own — the C.39 cancel / timeout path must
  /// be what closes it (mirrors the deadline test's runaway step).
  LoadedProcedure hangingProcedure(String id) => _procedure(
        id,
        '''
import '${BrainBridges.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.llm('hang forever');
  return 1;
}
''',
      );

  group('C.38-1 a trivial procedure roundtrips end-to-end', () {
    test('a value-returning procedure resolves an accepted outcome', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final run = engine.invoke(
        ProcedureInvocation(procedureId: 'answer_v1'),
      );
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.isSuccess, isTrue);
      expect(outcome.result, isNotNull);
      // A bare value is coerced under a single `value` output (Q-C.38.2).
      expect(outcome.result!.output<Object?>('value'), 1);
      expect(outcome.procedureId, 'answer_v1');
      expect(outcome.runId, run.runId);
    });

    test('a map-returning procedure surfaces its entries as outputs', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'answer_v1',
          "Object? run(inputs) => {'answer': 'backup nightly'};",
        ),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'answer_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'), 'backup nightly');
    });

    test('the run lands on recent_runs with a durable record', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'answer_v1')).outcome;

      // The recorder persisted a final ProcedureRun and pushed it to
      // recent_runs; the outcome carries that record without a re-read.
      expect(outcome.record.status, TrailOutcomeStatus.accepted);
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
      expect(recent.single.nodeId, outcome.record.runNodeId);
      // The inflight marker was removed at completion.
      final inflight = await memory.stacks.peek(inflightStackName);
      expect(inflight, isEmpty);
    });

    test('the bound arguments are recorded verbatim on the trail', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final outcome = await engine
          .invoke(
            ProcedureInvocation(
              procedureId: 'answer_v1',
              arguments: <String, Object?>{'q': 'how to back up?'},
            ),
          )
          .outcome;

      // The invocation entry — the first on the trail — records the bound
      // arguments exactly as the caller passed them.
      final invocation = outcome.entries.first;
      expect(invocation.kind, TrailEntryKind.invocation);
      expect(invocation.payload['arguments'],
          <String, Object?>{'q': 'how to back up?'});
    });
  });

  group('C.38-2 the handle streams the run trail live', () {
    test('trail emits invocation first and outcome last, in order', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'answer_v1',
          '''
import '$engineNativeLibrary';

Object? run(inputs) {
  note('progress', {'phase': 'mid'});
  return 1;
}
''',
        ),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'answer_v1'));
      // Subscribe before the pipeline advances (invoke returns synchronously,
      // the run runs on the event queue): toList sees every entry.
      final streamed = await run.trail.toList();
      final outcome = await run.outcome;

      expect(streamed.first.kind, TrailEntryKind.invocation);
      expect(streamed.last.kind, TrailEntryKind.outcome);
      // The in-procedure note shows up between the two.
      final notes =
          streamed.where((e) => e.kind == TrailEntryKind.note).toList();
      expect(notes, hasLength(1));
      expect(notes.single.payload['category'], 'progress');
      // The streamed trail and the terminal entries agree.
      expect(streamed.map((e) => e.kind).toList(),
          outcome.entries.map((e) => e.kind).toList());
    });
  });

  group('C.38-3 a step that overruns the deadline is preempted', () {
    test('an overrunning procedure closes preempted with a truncated note',
        () async {
      // The procedure awaits an llm call whose stream never completes, so the
      // step never finishes on its own — the deadline must force-yield it.
      _FakeTimer? scheduled;
      final armed = Completer<void>();

      final engine = engineFor(
        <LoadedProcedure>[
          _procedure(
            'slow_v1',
            '''
import '${BrainBridges.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.llm('think forever');
  return 1;
}
''',
          ),
        ],
        stepDeadline: const Duration(seconds: 30),
        deadlineTimerFactory: (duration, onExpire) {
          scheduled = _FakeTimer(duration, onExpire);
          if (!armed.isCompleted) armed.complete();
          return scheduled!;
        },
      );

      final run = engine.invoke(ProcedureInvocation(procedureId: 'slow_v1'));
      await armed.future; // the deadline timer is now counting down
      scheduled!.fire(); // force the deadline to expire
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.preempted);
      expect(outcome.result, isNull);

      final truncationNotes = outcome.entries
          .where((e) => e.kind == TrailEntryKind.note)
          .where((e) => e.payload['category'] == stepTruncatedNoteCategory)
          .toList();
      expect(truncationNotes, hasLength(1));
      final payload = truncationNotes.single.payload['payload']! as Map;
      expect(payload['limitMs'], 30 * 1000);
      expect(outcome.entries.last.payload['status'], 'preempted');
    });
  });

  group('C.38-4 a procedure that crashes closes errored', () {
    test('a thrown procedure resolves an errored outcome carrying the error',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'boom_v1',
          "Object? run(inputs) { throw StateError('kaboom'); }",
        ),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'boom_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.errored);
      expect(outcome.result, isNull);
      expect(outcome.error, isNotNull);
      // The crash is captured on the trail as a runtime-crash error entry.
      final errors =
          outcome.entries.where((e) => e.kind == TrailEntryKind.error).toList();
      expect(errors, hasLength(1));
    });
  });

  group('C.38-5 an unresolvable id surfaces as an outcome error', () {
    test('invoking an unknown procedure errors the outcome future', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('known_v1', 'Object? run(inputs) => 1;'),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'missing_v1'));

      await expectLater(run.outcome, throwsA(isA<ProcedureNotFound>()));
      // No run was recorded — nothing reached recent_runs.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, isEmpty);
    });
  });

  group('C.38-6 a procedure can run a nested procedure', () {
    test('runProcedure threads the child result back to the parent', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'parent_v1',
          '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await runProcedure('child_v1', inputs);
}
''',
        ),
        _procedure(
          'child_v1',
          "Object? run(inputs) => {'v': 42};",
        ),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'parent_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The child's ProcedureResult passed through unchanged (Q-C.38.2).
      expect(outcome.result!.output<int>('v'), 42);
      // Two runs were recorded — the parent and the nested child.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(2));
    });
  });

  group('E.3.2 bridged calls are recorded on the run trail', () {
    test('a sub.embed call lands as a primitiveCall entry and counts effort',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'embed_v1',
          '''
import '${BrainBridges.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.embed('hello');
  return 1;
}
''',
        ),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'embed_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);

      // The bridged effect call landed on this run's trail as a primitiveCall
      // entry naming the primitive (E.3.2).
      final primitiveCalls = outcome.entries
          .where((e) => e.kind == TrailEntryKind.primitiveCall)
          .toList();
      expect(primitiveCalls, hasLength(1));
      expect(primitiveCalls.single.payload['primitive'], 'embed');
      expect((primitiveCalls.single.payload['input']! as Map)['text'], 'hello');

      // The call folded into the run's effort tally: embed is a substrate
      // tool callout (+1 toolCalls) per the EffortAccountant.
      expect(outcome.record.effort.toolCalls, 1);
    });

    test('a procedure that makes no bridged call records none', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'answer_v1')).outcome;

      final primitiveCalls = outcome.entries
          .where((e) => e.kind == TrailEntryKind.primitiveCall)
          .toList();
      expect(primitiveCalls, isEmpty);
      expect(outcome.record.effort.toolCalls, 0);
      expect(outcome.record.effort.memoryReads, 0);
    });
  });

  group('C.39-1 run.cancel() abandons a run and closes it aborted', () {
    test('an explicit cancel closes aborted with a run_cancelled note',
        () async {
      final engine = engineFor(<LoadedProcedure>[hangingProcedure('hang_v1')]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'hang_v1'));
      // Cancel once the run has opened its trail (the invocation entry is the
      // first thing the recorder emits, before the step race is set up).
      await run.trail.firstWhere(
        (TrailEntry e) => e.kind == TrailEntryKind.invocation,
      );
      run.cancel();
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.aborted);
      expect(outcome.result, isNull);
      expect(run.isCancelled, isTrue);

      final cancelNotes = outcome.entries
          .where((e) => e.kind == TrailEntryKind.note)
          .where((e) => e.payload['category'] == runCancelledNoteCategory)
          .toList();
      expect(cancelNotes, hasLength(1));
      // A cancel carries no timeout budget.
      expect(cancelNotes.single.payload['payload'], <String, Object?>{});
      expect(outcome.entries.last.payload['status'], 'aborted');
    });

    test('a cancelled run still lands on recent_runs, inflight cleared',
        () async {
      final engine = engineFor(<LoadedProcedure>[hangingProcedure('hang_v1')]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'hang_v1'));
      await run.trail.firstWhere(
        (TrailEntry e) => e.kind == TrailEntryKind.invocation,
      );
      run.cancel();
      final outcome = await run.outcome;

      expect(outcome.record.status, TrailOutcomeStatus.aborted);
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
      expect(recent.single.nodeId, outcome.record.runNodeId);
      final inflight = await memory.stacks.peek(inflightStackName);
      expect(inflight, isEmpty);
    });
  });

  group('C.39-2 an external timeout closes a run aborted', () {
    test('an elapsed timeout closes aborted with a run_timed_out note',
        () async {
      _FakeTimer? scheduled;
      final armed = Completer<void>();

      final engine = engineFor(
        <LoadedProcedure>[hangingProcedure('hang_v1')],
        cancellationTimerFactory: (duration, onExpire) {
          scheduled = _FakeTimer(duration, onExpire);
          if (!armed.isCompleted) armed.complete();
          return scheduled!;
        },
      );

      final run = engine.invoke(
        ProcedureInvocation(procedureId: 'hang_v1'),
        timeout: const Duration(seconds: 5),
      );
      await armed.future; // the timeout timer is now counting down
      scheduled!.fire(); // force the timeout to elapse
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.aborted);
      expect(outcome.result, isNull);
      expect(run.isCancelled, isTrue);

      final timeoutNotes = outcome.entries
          .where((e) => e.kind == TrailEntryKind.note)
          .where((e) => e.payload['category'] == runTimedOutNoteCategory)
          .toList();
      expect(timeoutNotes, hasLength(1));
      final payload = timeoutNotes.single.payload['payload']! as Map;
      expect(payload['timeoutMs'], 5 * 1000);
      expect(outcome.entries.last.payload['status'], 'aborted');
    });

    test('a run that finishes before its timeout closes normally, timer off',
        () async {
      _FakeTimer? scheduled;

      final engine = engineFor(
        <LoadedProcedure>[
          _procedure('answer_v1', 'Object? run(inputs) => 1;'),
        ],
        cancellationTimerFactory: (duration, onExpire) {
          scheduled = _FakeTimer(duration, onExpire);
          return scheduled!;
        },
      );

      final run = engine.invoke(
        ProcedureInvocation(procedureId: 'answer_v1'),
        timeout: const Duration(seconds: 60),
      );
      final outcome = await run.outcome;

      // The run finished on its own: accepted, not aborted.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(run.isCancelled, isFalse);
      // The timeout timer was disarmed when the run resolved.
      expect(scheduled, isNotNull);
      expect(scheduled!.isActive, isFalse);
    });

    test('a non-positive timeout is rejected', () {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      expect(
        () => engine.invoke(
          ProcedureInvocation(procedureId: 'answer_v1'),
          timeout: Duration.zero,
        ),
        throwsArgumentError,
      );
    });
  });

  group('C.39-3 cancel after the run finished is a no-op', () {
    test('cancelling a completed run does not change its outcome', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'answer_v1'));
      final outcome = await run.outcome;
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // A late cancel is dropped — the run already produced its outcome.
      run.cancel();
      expect(run.isCancelled, isFalse);
      expect((await run.outcome).status, TrailOutcomeStatus.accepted);
    });
  });

  group('E.3.5 the static sandbox gate runs before the host', () {
    test('a forbidden import surfaces a violation and records no run',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'rogue_v1',
          "import 'dart:io';\nObject? run(inputs) => 1;",
        ),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'rogue_v1'));

      await expectLater(
        run.outcome,
        throwsA(
          isA<ProcedureSandboxViolation>()
              .having((e) => e.procedureId, 'procedureId', 'rogue_v1')
              .having((e) => e.offender, 'offender', 'import'),
        ),
      );
      // The gate fires before the recorder starts: nothing was recorded.
      expect(await memory.stacks.peek(recentRunsStackName), isEmpty);
      expect(await memory.stacks.peek(inflightStackName), isEmpty);
    });

    test('a procedure importing only allow-listed libraries runs', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'clean_v1',
          "import '${BrainBridges.memoryLibrary}';\n"
              'Object? run(inputs) => 1;',
        ),
      ]);

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'clean_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<Object?>('value'), 1);
    });
  });

  group('P1.3 #8 the per-run token sink streams sub.llm + emit deltas', () {
    // A procedure that authors a delta with `emit`, then pulls a two-chunk
    // substrate completion through `sub.llm`. The whole answer is still
    // returned (the bridge concatenates), so the route can mark the stream
    // end without re-sending text.
    ProcedureEngine streamingEngine(_StreamingSubstrate streaming) =>
        ProcedureEngine(
          resolver: ProcedureResolver(<LoadedProcedure>[
            _procedure(
              'stream_v1',
              '''
import '${BrainBridges.substrateLibrary}';
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  await emit('[start] ');
  final res = await sub.llm('prompt');
  return {'answer': res['text']};
}
''',
            ),
          ]),
          memory: memory,
          memoryBridge: memoryBridge,
          substrateBridge: SubstrateBridge(streaming),
          now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
        );

    test('an external run (tokenSink supplied) forwards both the emit delta '
        'and each sub.llm chunk in body order', () async {
      final engine = streamingEngine(_StreamingSubstrate(<String>['He', 'llo']));

      final deltas = <String>[];
      final outcome = await engine
          .invoke(
            ProcedureInvocation(procedureId: 'stream_v1'),
            tokenSink: (delta) async => deltas.add(delta),
          )
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The emit delta first (authored before the llm call), then the two
      // substrate chunks, in order — both halves share the one sink.
      expect(deltas, <String>['[start] ', 'He', 'llo']);
      // The buffered answer still carries the concatenated completion.
      expect(outcome.result!.output<String>('answer'), 'Hello');
    });

    test('an internal run (no tokenSink) streams nothing but still completes '
        'with the full answer', () async {
      final engine = streamingEngine(_StreamingSubstrate(<String>['He', 'llo']));

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'stream_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('answer'), 'Hello');
    });
  });
}

/// Builds a [LoadedProcedure] from [body], wrapping it in a minimal valid
/// `@procedure` header so the resolver and loader treat it as a real
/// procedure (§ 4.4).
LoadedProcedure _procedure(String id, String body, {int version = 1}) {
  final source = '''
/// @procedure
/// id: $id
/// version: $version
/// summary: a test procedure
/// successCriterion: returns a value
/// budget: { wallClockMs: 60000 }
$body
''';
  return ProcedureLoader.shared.load(
    ProcedureSource(
      ref: ProcedureRef.system('/procedures/$id.dart'),
      source: source,
    ),
  );
}

// ── A `Timer` test double ───────────────────────────────────────────
//
// Captures the scheduled deadline callback and fires it on demand so the
// `StepDeadline` is driven deterministically (mirrors the cooperative-
// preemption suite).
final class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;

  bool _active = true;
  int _ticks = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    _ticks++;
    _active = false;
    callback();
  }
}

// ── A controllable `TomBrainSubstrateClient` ────────────────────────
//
// `completeStream` returns a never-completing stream by default (a
// `StreamController` that is never closed), so a procedure that awaits
// `sub.llm(...)` hangs — exactly the runaway step the deadline test needs.
class _ControllableSubstrate implements TomBrainSubstrateClient {
  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      StreamController<LlmStreamEvent>().stream;

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec(Float32List.fromList(<double>[0.0])),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'm',
          dims: 1,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ── A streaming `TomBrainSubstrateClient` ───────────────────────────
//
// `completeStream` emits one `LlmStreamChunk` per configured chunk and then
// completes — so a procedure that awaits `sub.llm(...)` gets the concatenated
// text back while each chunk is forwarded live to the per-run token sink
// (P1.3 #8). Used by the token-sink streaming tests.
class _StreamingSubstrate implements TomBrainSubstrateClient {
  _StreamingSubstrate(this.chunks);

  final List<String> chunks;

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        for (final chunk in chunks) LlmStreamChunk(callId: 'c', text: chunk),
        const LlmStreamCompleted(
          callId: 'c',
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'a',
            promptHash: 'pr',
            tokensIn: 1,
            tokensOut: 1,
            retries: 0,
            wallClockMs: 1,
          ),
        ),
      ]);

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec(Float32List.fromList(<double>[0.0])),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'p',
          modelId: 'm',
          dims: 1,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

// ── A stateful in-memory `TomBrainMemoryClient` ─────────────────────
//
// Models just enough of the store for the recorder's writes to be read
// back: trails are ordered entry logs, stacks are push/peek/remove
// containers, persisted nodes are resolvable by id. Copied from the
// cooperative-preemption suite; unimplemented members fall through to
// `noSuchMethod`.
class _StatefulMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};

  @override
  StackApi get stacks => _stacks;

  @override
  Future<TrailId> openTrail(ProcedureRunRef run) async {
    final id = TrailId.generate();
    _trails[id] = <TrailEntry>[];
    return id;
  }

  @override
  Future<void> appendTrail(TrailId id, TrailEntry entry) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('appendTrail on an unopened trail: $id');
    }
    if (_closedTrails.contains(id)) {
      throw StateError('appendTrail on a closed trail: $id');
    }
    entries.add(entry);
  }

  @override
  Future<void> closeTrail(TrailId id, TrailOutcome outcome) async {
    final entries = _trails[id];
    if (entries == null) {
      throw StateError('closeTrail on an unopened trail: $id');
    }
    entries.add(TrailEntry.outcome(outcome));
    _closedTrails.add(id);
  }

  @override
  Stream<TrailEntry> readTrail(TrailId id) {
    final entries = _trails[id];
    if (entries == null) {
      return Stream<TrailEntry>.error(
        StateError('readTrail on an unknown trail: $id'),
      );
    }
    return Stream<TrailEntry>.fromIterable(List<TrailEntry>.of(entries));
  }

  @override
  Future<NodeId> persist(NodeDraft draft, {required Scope scope}) async {
    final id = NodeId.generate();
    _nodes[id] = Node(
      id: id,
      typeName: draft.typeName,
      values: Map<String, Object?>.of(draft.values),
      createdAt: DateTime.now().toUtc(),
    );
    return id;
  }

  @override
  Future<Node?> get(NodeId id) async => _nodes[id];

  @override
  Future<EdgeId> edge(
    NodeId from,
    EdgeType type,
    NodeId to, {
    required Scope scope,
    double weight = 1.0,
    Map<String, Object?>? attrs,
  }) async =>
      EdgeId.generate();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _InMemoryStacks implements StackApi {
  final Map<String, List<StackEntry>> _stacks = <String, List<StackEntry>>{};

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    final id = StackEntryId.generate();
    (_stacks[name] ??= <StackEntry>[]).add(
      StackEntry(
        id: id,
        stackName: name,
        nodeId: entry,
        priority: priority,
        pushedAt: DateTime.now().toUtc(),
        attrs: attrs ?? const <String, Object?>{},
      ),
    );
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    final entries = _stacks[name] ?? const <StackEntry>[];
    final active = entries
        .where((e) => e.status == StackEntryStatus.active)
        .toList(growable: false);
    return active.length <= k ? active : active.sublist(0, k);
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    _stacks[name]?.removeWhere((e) => e.nodeId == entry);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    final entries = _stacks[name];
    if (entries == null || entries.isEmpty) return null;
    return entries.removeLast();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
