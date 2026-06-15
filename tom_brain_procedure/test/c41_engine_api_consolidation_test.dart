// C.41 — engine API surface consolidation suite (subphase C.10).
//
// Plan step C.41 (verbatim): "Tests: invoke roundtrips a trivial script;
// cancellation propagates; sugar resolves to runProcedure."
//
// C.38–C.40 each pinned one promise of the engine API surface in its own
// suite (entry point, cancellation + timeout, sugar aliases). C.41 is the
// consolidated *black-box* pass: it drives `ProcedureEngine` only — build a
// `ProcedureInvocation`, `invoke`, watch `run.trail`, read `run.outcome`,
// `run.cancel()` — and folds the three promises into one suite that an
// integrator can read as the contract of the API:
//
//   1. INVOKE ROUNDTRIP — a trivial script runs end-to-end; the outcome
//      resolves `accepted` carrying the coerced result, and the durable run
//      record lands on `recent_runs` with the inflight marker cleared.
//   2. CANCELLATION PROPAGATES — `run.cancel()` on an in-flight run closes it
//      `aborted` with a `run_cancelled` note; *and the gap C.39 deferred* —
//      cancellation propagating **through a sugar call** (a `think(...)` whose
//      `think_v1` target hangs): cancelling the top-level run abandons the
//      whole sub-tree, closing the caller `aborted` even though the abandoned
//      work was inside a nested sugar-dispatched run.
//   3. SUGAR RESOLVES TO runProcedure — `think(inputs)` from a script reaches
//      `runProcedure('think_v1', …)` (proven by injecting a marker `think_v1`
//      and by the shipped no-op stub), and an unimplemented verb resolves to a
//      missing `<verb>_v1` and surfaces `ProcedureNotFound` informatively.
//
// The harness is the one the C.38/C.39/C.40 suites use: a stateful in-memory
// memory client (so the recorder writes a real trail + run record), a
// controllable substrate double whose `completeStream` never completes (so a
// step that awaits `sub.llm(...)` hangs until cancelled), and a `_FakeTimer`
// to drive timers deterministically.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

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
    CancellationTimerFactory? cancellationTimerFactory,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        stepDeadline: stepDeadline,
        cancellationTimerFactory: cancellationTimerFactory,
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
      );

  /// A procedure whose only step awaits a never-completing `sub.llm(...)`, so
  /// the step never settles on its own — cancellation must be what closes it.
  LoadedProcedure hangingProcedure(String id) => _procedure(
        id,
        '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.send('hang forever', llmRoute: 'fast');
  return 1;
}
''',
      );

  /// The shipped no-op `think_v1` stub, loaded from disk through the real
  /// store + resolver path so the test exercises the actual artifact.
  Future<LoadedProcedure> loadThinkStub() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    final resolver = await ProcedureResolver.fromStore(store);
    return resolver.resolve('think_v1');
  }

  group('C.41-1 invoke roundtrips a trivial script', () {
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

      // The outcome carries the coerced result.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.isSuccess, isTrue);
      expect(outcome.result!.output<String>('answer'), 'backup nightly');
      expect(outcome.procedureId, 'answer_v1');
      expect(outcome.runId, run.runId);

      // The durable record is on recent_runs; the inflight marker is gone.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(1));
      expect(recent.single.nodeId, outcome.record.runNodeId);
      expect(await memory.stacks.peek(inflightStackName), isEmpty);
    });

    test('the handle streams the trail invocation-first, outcome-last',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure('answer_v1', 'Object? run(inputs) => 1;'),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'answer_v1'));
      final streamed = await run.trail.toList();

      expect(streamed.first.kind, TrailEntryKind.invocation);
      expect(streamed.last.kind, TrailEntryKind.outcome);
    });
  });

  group('C.41-2 cancellation propagates', () {
    test('cancel on an in-flight run closes it aborted with a cancel note',
        () async {
      final engine = engineFor(<LoadedProcedure>[hangingProcedure('hang_v1')]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'hang_v1'));
      // Cancel once the trail has opened (invocation entry emitted), before
      // the step would ever settle on its own.
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

    test('cancellation propagates through a sugar call (think_v1 hangs)',
        () async {
      // The gap C.39 deferred: a script reaches `think(...)`, whose `think_v1`
      // target hangs. Cancelling the top-level run abandons the parent's step
      // — which is awaiting the nested sugar-dispatched run — and closes the
      // caller `aborted`, proving cancellation propagates across the sugar
      // boundary even though the abandoned work is one level down.
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await think(inputs);
}
''',
        ),
        // A `think_v1` that hangs instead of the shipped no-op stub, so the
        // sugar-dispatched nested run never settles on its own.
        hangingProcedure('think_v1'),
      ]);

      final run = engine.invoke(ProcedureInvocation(procedureId: 'caller_v1'));
      await run.trail.firstWhere(
        (TrailEntry e) => e.kind == TrailEntryKind.invocation,
      );
      run.cancel();
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.aborted);
      expect(run.isCancelled, isTrue);
      final cancelNotes = outcome.entries
          .where((e) => e.kind == TrailEntryKind.note)
          .where((e) => e.payload['category'] == runCancelledNoteCategory)
          .toList();
      expect(cancelNotes, hasLength(1));
    });

    test('an external timeout closes the run aborted with a timeout note',
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
  });

  group('C.41-3 sugar resolves to runProcedure', () {
    test('think(inputs) reaches runProcedure(think_v1, …) — marker target',
        () async {
      // Inject a marker `think_v1` whose result is distinguishable from any
      // other procedure, proving the `think` verb dispatched to the
      // `think_v1` id (not to some other procedure or a no-op).
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await think(inputs);
}
''',
        ),
        _procedure(
          'think_v1',
          "Object? run(inputs) => {'dispatched': 'think_v1'};",
        ),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      // The marker flowed back through the sugar alias and the nested run.
      expect(outcome.result!.output<String>('dispatched'), 'think_v1');
      // Two runs were recorded — the caller and the nested think_v1.
      final recent = await memory.stacks.peek(recentRunsStackName);
      expect(recent, hasLength(2));
    });

    test('think(inputs) runs the shipped no-op think_v1 stub', () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await think(inputs);
}
''',
        ),
        await loadThinkStub(),
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(outcome.result!.output<String>('stub'), 'think_v1');
    });

    test('an unimplemented verb resolves to a missing target and errors',
        () async {
      final engine = engineFor(<LoadedProcedure>[
        _procedure(
          'caller_v1',
          '''
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  return await plan(inputs);
}
''',
        ),
        // No `plan_v1` is loaded — the resolver does not know it.
      ]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'caller_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.errored);
      expect(outcome.error, isA<ProcedureNotFound>());
      final notFound = outcome.error! as ProcedureNotFound;
      expect(notFound.id, 'plan_v1');
      expect(notFound.code, procedureNotFoundCode);
    });
  });
}

/// Builds a [LoadedProcedure] from [body], wrapping it in a minimal valid
/// `@procedure` header (§ 4.4) so the resolver treats it as a real procedure.
/// Mirrors the helper the C.38/C.39/C.40 suites use.
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
// Captures the scheduled callback and fires it on demand so the cancellation
// timeout is driven deterministically (mirrors the C.38/C.39 suites).
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
// procedure that awaits `sub.llm(...)` hangs — the runaway step cancellation
// must close. Copied from the C.38/C.39 engine suite.
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
// persisted nodes are resolvable by id. Copied from the C.38/C.39/C.40 suites;
// unimplemented members fall through to `noSuchMethod`.
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
