// C.49 — ProcedureEngine API conformance suite (subphase C.12, phase-end).
//
// Plan step C.49 (verbatim): "API conformance tests: black-box test suite
// driving `ProcedureEngine` only. Cover invoke / cancel / deadline /
// depth-cap / fallback selection."
//
// This is the phase-end conformance pass. Where the per-step suites pinned
// one promise each (C.38 entry point, C.39 cancel + timeout, C.40 sugar)
// and C.41 folded invoke / cancel / sugar into one black-box read, C.49
// closes the *whole* public contract along the five axes the plan names —
// importantly the three C.41 did not exercise: the hard per-step DEADLINE,
// the hard recursion DEPTH-CAP, and version FALLBACK SELECTION. It drives
// the engine the way the Phase D dispatcher will and nothing else: build a
// `ProcedureInvocation`, `invoke`, watch `run.trail`, read `run.outcome`,
// `run.cancel()`. No engine internal is reached — every assertion is on a
// value the public surface hands back (the outcome, the run handle, or the
// memory the recorder wrote to, which is the engine's only durable output).
//
//   1. INVOKE          — a trivial script runs end-to-end; the outcome
//                        resolves `accepted` carrying the coerced result,
//                        the durable record lands on `recent_runs`, the
//                        inflight marker is cleared, and the bound
//                        arguments are on the trail verbatim.
//   2. CANCEL          — `run.cancel()` on an in-flight run closes it
//                        `aborted` with a `run_cancelled` note; an external
//                        `timeout:` closes `aborted` with a `run_timed_out`
//                        note; a late cancel on a finished run is a no-op.
//   3. DEADLINE        — a step that overruns the `StepDeadline` closes
//                        `preempted` with a `step_truncated` note carrying
//                        the breached limit.
//   4. DEPTH-CAP       — a `runProcedure` call that would exceed the hard
//                        cap is refused: a single over-cap jump surfaces a
//                        `RecursionLimitExceeded` on the outcome, and an
//                        unbounded self-recursion terminates `errored` at
//                        exactly the cap (proven by the recorded-run count).
//   5. FALLBACK SELECT — with several versions of one id loaded, an
//                        unpinned invoke resolves the latest; a pinned
//                        version resolves exactly that one; an unknown
//                        pinned version surfaces `ProcedureNotFound`.
//
// The harness mirrors the C.38/C.39/C.40/C.41 suites: a stateful in-memory
// memory client (so the recorder writes a real trail + run record), a
// controllable substrate double whose `completeStream` never completes (so
// a step that awaits `sub.llm(...)` hangs until a deadline / cancel closes
// it), and a `_FakeTimer` to drive the deadline and timeout timers
// deterministically.

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
    int hardDepthCap = RunProcedurePrimitive.defaultHardDepthCap,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        stepDeadline: stepDeadline,
        deadlineTimerFactory: deadlineTimerFactory,
        cancellationTimerFactory: cancellationTimerFactory,
        hardDepthCap: hardDepthCap,
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  /// A procedure whose only step awaits a never-completing `sub.llm(...)`, so
  /// the step never settles on its own — the deadline / cancel path must be
  /// what closes it.
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

  group('C.49-1 invoke', () {
    test('a trivial procedure resolves accepted and lands on recent_runs',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'answer_v1',
          "Object? run(inputs) => {'answer': 'backup nightly'};",
        ),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'answer_v1'));
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.isSuccess, isTrue);
      expect(outcome.result!.output<String>('answer'), 'backup nightly');
      expect(outcome.procedureId, 'answer_v1');
      expect(outcome.runId, run.runId);

      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
      expect(recent.single.nodeId, outcome.record.runNodeId);
      expect(await memory.stacks.peek(inflightStackName), isEmpty);
    });

    test('the trail streams invocation-first, outcome-last, args verbatim',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final run = engine.invoke(
        ProcedureInvocation(
          procedureId: 'answer_v1',
          arguments: <String, Object?>{'q': 'how to back up?'},
        ),
      );
      final streamed = await run.trail.toList();
      final outcome = await run.outcome;

      expect(streamed.first.kind, TrailEntryKind.invocation);
      expect(streamed.last.kind, TrailEntryKind.outcome);
      // The streamed trail and the terminal entries agree.
      expect(streamed.map((e) => e.kind).toList(),
          outcome.entries.map((e) => e.kind).toList());
      // The invocation entry records the bound arguments exactly.
      expect(streamed.first.payload['arguments'],
          <String, Object?>{'q': 'how to back up?'});
    });
  });

  group('C.49-2 cancel', () {
    test('an explicit cancel closes aborted with a run_cancelled note',
        () async {
      final engine = engineFor(<LoadedProcedure>[hangingProcedure('hang_v1')]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'hang_v1'));
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
      // A cancelled run still lands on recent_runs, inflight cleared.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
      expect(await memory.stacks.peek(inflightStackName), isEmpty);
    });

    test('an external timeout closes aborted with a run_timed_out note',
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
      await armed.future;
      scheduled!.fire();
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.aborted);
      expect(run.isCancelled, isTrue);
      final timeoutNotes = outcome.entries
          .where((e) => e.kind == TrailEntryKind.note)
          .where((e) => e.payload['category'] == runTimedOutNoteCategory)
          .toList();
      expect(timeoutNotes, hasLength(1));
      final payload = timeoutNotes.single.payload['payload']! as Map;
      expect(payload['timeoutMs'], 5 * 1000);
    });

    test('a late cancel on a finished run is a no-op', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'answer_v1'));
      expect((await run.outcome).status, TrailOutcomeStatus.accepted);

      run.cancel();
      expect(run.isCancelled, isFalse);
      expect((await run.outcome).status, TrailOutcomeStatus.accepted);
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

  group('C.49-3 deadline', () {
    test('an overrunning step closes preempted with a truncated note',
        () async {
      _FakeTimer? scheduled;
      final armed = Completer<void>();

      final engine = engineFor(
        <LoadedProcedure>[hangingProcedure('slow_v1')],
        stepDeadline: const Duration(seconds: 30),
        deadlineTimerFactory: (duration, onExpire) {
          scheduled = _FakeTimer(duration, onExpire);
          if (!armed.isCompleted) armed.complete();
          return scheduled!;
        },
      );

      final run = engine.invoke(ProcedureInvocation(procedureId: 'slow_v1'));
      await armed.future; // the deadline timer is counting down
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

  group('C.49-4 depth-cap', () {
    test('a single over-cap jump surfaces RecursionLimitExceeded', () async {
      // The top-level frame runs at depth 1; a `depthDelta` jump straight past
      // the cap is refused before the executor is ever called. The native
      // exception propagates through d4rt unwrapped and the run closes errored
      // carrying it (the same propagation the C.41 ProcedureNotFound test
      // proves for resolution failures).
      final engine = engineFor(
        <LoadedProcedure>[
          _procedure(
            'jumper_v1',
            '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await runProcedure('child_v1', inputs, depthDelta: 5);
}
''',
          ),
          _procedure('child_v1', 'Object? run(inputs) => 1;'),
        ],
        hardDepthCap: 3,
      );

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'jumper_v1')).outcome;

      expect(outcome.status, TrailOutcomeStatus.errored);
      expect(outcome.result, isNull);
      expect(outcome.error, isA<RecursionLimitExceeded>());
      final exceeded = outcome.error! as RecursionLimitExceeded;
      expect(exceeded.attemptedDepth, 1 + 5);
      expect(exceeded.hardDepthCap, 3);
      // The child it would have run was never resolved or recorded — only the
      // top-level jumper landed on recent_runs.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
    });

    test('unbounded self-recursion terminates errored at exactly the cap',
        () async {
      // A procedure that always recurses into itself; with `depthDelta` 1 the
      // chain advances one level per call. The hard cap bounds it: the cap-th
      // frame's `runProcedure` is refused, so the recursion terminates rather
      // than running away — proven by the recorded-run count equalling the cap.
      const cap = 3;
      final engine = engineFor(
        <LoadedProcedure>[
          _procedure(
            'recurse_v1',
            '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await runProcedure('recurse_v1', inputs);
}
''',
          ),
        ],
        hardDepthCap: cap,
      );

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'recurse_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.errored);
      // Exactly one run per depth 1..cap was recorded; the recursion did not
      // run away.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(cap));
    });
  });

  group('C.49-5 fallback selection', () {
    Iterable<LoadedProcedure> rankerVersions() => <LoadedProcedure>[
          _procedure(
            'ranker',
            "Object? run(inputs) => {'v': 1};",
            version: 1,
          ),
          _procedure(
            'ranker',
            "Object? run(inputs) => {'v': 2};",
            version: 2,
          ),
        ];

    test('an unpinned invoke resolves the latest version', () async {
      final engine = engineFor(rankerVersions());

      final outcome =
          await engine.invoke(ProcedureInvocation(procedureId: 'ranker')).outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The descending fallback chain `[v2, v1]` resolves v2 as the head.
      expect(outcome.result!.output<int>('v'), 2);
    });

    test('a pinned version resolves exactly that version', () async {
      final engine = engineFor(rankerVersions());

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'ranker', version: 1))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<int>('v'), 1);
    });

    test('an unknown pinned version surfaces ProcedureNotFound', () async {
      final engine = engineFor(rankerVersions());

      final run =
          engine.invoke(ProcedureInvocation(procedureId: 'ranker', version: 7));

      await expectLater(run.outcome, throwsA(isA<ProcedureNotFound>()));
      // Resolution failed before any run opened — nothing reached recent_runs.
      expect(await memory.stacks.peek(recentRunsStackName), isEmpty);
    });
  });
}

/// Builds a [LoadedProcedure] from [body], wrapping it in a minimal valid
/// `@procedure` header (§ 4.4) so the resolver treats it as a real procedure.
/// The ref carries the version so two versions of one id have distinct refs.
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
      ref: ProcedureRef.system('/procedures/${id}_v$version.dart'),
      source: source,
    ),
  );
}

// ── A `Timer` test double ───────────────────────────────────────────
//
// Captures the scheduled callback and fires it on demand so the deadline and
// timeout timers are driven deterministically (mirrors the C.38/C.39/C.41
// suites).
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
// `completeStream` returns a never-completing stream by default, so a
// procedure that awaits `sub.llm(...)` hangs — the runaway step the deadline
// and cancel paths must close. Copied from the C.38/C.39/C.41 suites.
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

// ── A stateful in-memory `TomBrainMemoryClient` ─────────────────────
//
// Models just enough of the store for the recorder's writes to be read back:
// trails are ordered entry logs, stacks are push/peek/remove containers,
// persisted nodes are resolvable by id. Copied from the C.38/C.39/C.41
// suites; unimplemented members fall through to `noSuchMethod`.
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
