// Engine-level memory-access forwarding (`tom_brain_logging.md` §5.6 / §9 /
// §10 step #8 — the "engine → per-profile memory log" half of the seam).
//
// Every bridged memory primitive a run issues (`recall`, `persist`, `edge`,
// `stackPush`, …) is dispatched through the per-run `MemoryBridge`. The engine
// is the only place that knows the run's correlation — its `runId`, the live
// `trailId` the recorder opened, the turn it serves, and the memory `profile`
// the request ran under — so it wraps each bridged memory call into a
// [MemoryAccessRecord] carrying all four and hands it to the bound
// `memoryAccessSink` (the host binds a `MemoryProfileLogWriter`).
//
// Substrate `llm` calls go through the *substrate* bridge, not the memory
// bridge, so they must never reach the memory sink. With no sink bound the
// engine composes no observer onto the per-run memory bridge, so nothing is
// emitted and the run completes unchanged.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        EdgeId,
        FusionStrategy,
        DiversityStrategy,
        Node,
        NodeId,
        RecallMode,
        RecallQuery,
        RecallReport,
        RecallResult,
        Scope,
        StackEntryId,
        TrailId,
        TurnId,
        Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:test/test.dart';

void main() {
  late _RecallingMemory memory;
  late _StubSubstrate substrate;

  setUp(() {
    memory = _RecallingMemory();
    substrate = _StubSubstrate();
  });

  ProcedureEngine engineFor(
    Iterable<LoadedProcedure> procedures, {
    MemoryAccessSink? memoryAccessSink,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
        memoryAccessSink: memoryAccessSink,
      );

  // A procedure that issues one substrate call (which must NOT reach the
  // memory sink) and three memory accesses (recall + persist + stackPush).
  LoadedProcedure mixedAccessProcedure() => _procedure(
        'mixed_access_v1',
        '''
import '${BrainBridges.substrateLibrary}';
import '${BrainBridges.memoryLibrary}';

Future<Object?> run(inputs) async {
  await sub.llm('hello');
  await mem.recall('q', modes: ['bm25'], k: 4);
  final id = await mem.persist('Conclusion', {'text': 'x'}, producer: 'p');
  await mem.stackPush('recent', id, priority: 1.0, producer: 'p');
  return 1;
}
''',
      );

  group('ProcedureEngine memory-access forwarding (§5.6 / §10 step #8)', () {
    test(
        'a bound sink receives one record per memory call, run-correlated, '
        'profile-stamped — and substrate llm calls do not reach it', () async {
      final records = <MemoryAccessRecord>[];
      final engine = engineFor(
        <LoadedProcedure>[mixedAccessProcedure()],
        memoryAccessSink: records.add,
      );

      final turnId = TurnId.generate();
      final run = engine.invoke(
        ProcedureInvocation(
          procedureId: 'mixed_access_v1',
          turnId: turnId,
          memoryProfile: 'work',
        ),
      );
      final outcome = await run.outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);

      // Exactly the three memory primitives — the `llm` call rode the
      // substrate bridge and never reached the memory sink.
      expect(records.map((r) => r.primitive).toList(),
          <String>['recall', 'persist', 'stackPush'],
          reason: 'one record per memory call, in call order; no llm record');

      for (final record in records) {
        expect(record.runId, run.runId, reason: 'run-correlated');
        expect(record.trailId, isNotNull,
            reason: 'the recorder trail is open when the bridge fires');
        expect(record.turnId, turnId.value, reason: 'turn-stamped');
        expect(record.profile, 'work',
            reason: 'the memory profile threaded from the invocation');
        expect(record.at, DateTime.utc(2026, 6, 1, 12, 0, 0));
      }

      // The recall record carries the query shape (modes + k) and the result
      // (nodes + report incl. the degraded flag).
      final recall = records[0];
      expect(recall.input['modes'], <String>['bm25']);
      expect(recall.input['k'], 4);
      expect((recall.result['nodes'] as List).length, 1);
      expect((recall.result['report'] as Map)['degraded'], isTrue);

      // The persist record carries the new node id; stackPush carries its
      // entry id.
      expect(records[1].result['id'], isNotNull);
      expect(records[2].result['id'], isNotNull);
    });

    test('with no sink bound the engine forwards nothing', () async {
      final engine = engineFor(<LoadedProcedure>[mixedAccessProcedure()]);

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'mixed_access_v1'))
          .outcome;

      // The run still completes — the sink is purely observational.
      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(memory.recallCalls, 1);
    });

    test('a turn-less invocation leaves turnId null and profile null',
        () async {
      final records = <MemoryAccessRecord>[];
      final engine = engineFor(
        <LoadedProcedure>[mixedAccessProcedure()],
        memoryAccessSink: records.add,
      );

      await engine
          .invoke(ProcedureInvocation(procedureId: 'mixed_access_v1'))
          .outcome;

      expect(records, isNotEmpty);
      for (final record in records) {
        expect(record.turnId, isNull);
        expect(record.profile, isNull);
      }
    });
  });
}

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

/// A substrate client whose `llm` completes with a tiny answer — enough to
/// prove substrate calls do not reach the memory sink.
class _StubSubstrate implements TomBrainSubstrateClient {
  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c', text: 'ok'),
        LlmStreamCompleted(
          callId: 'c',
          wire: CapturedWirePrompt(
            body: 'ANCHOR',
            anchorHash: 'sha256:anchor',
            roleId: call.roleId,
          ),
          report: const LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'sha256:anchor',
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
        vec: Vec.zero(1),
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

/// A stateful in-memory `TomBrainMemoryClient` that supports the recorder's
/// writes plus a controllable `recall` (one node, degraded report) so the
/// engine seam has real memory calls to forward.
class _RecallingMemory implements TomBrainMemoryClient {
  final _InMemoryStacks _stacks = _InMemoryStacks();
  final Map<NodeId, Node> _nodes = <NodeId, Node>{};
  final Map<TrailId, List<TrailEntry>> _trails = <TrailId, List<TrailEntry>>{};
  final Set<TrailId> _closedTrails = <TrailId>{};
  int recallCalls = 0;

  @override
  StackApi get stacks => _stacks;

  @override
  Future<RecallResult> recall(RecallQuery query) async {
    recallCalls++;
    final node = Node(
      id: NodeId.generate(),
      typeName: 'Conclusion',
      values: const <String, Object?>{'text': 'hit'},
      createdAt: DateTime.utc(2026, 6, 1),
    );
    return RecallResult(
      nodes: <Node>[node],
      report: const RecallReport(
        candidatesPerMode: <RecallMode, int>{},
        fusionStrategy: FusionStrategy.rrf,
        diversityStrategy: DiversityStrategy.off,
        elapsedMs: 1,
        degraded: true,
      ),
    );
  }

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
