// Engine-level combined per-procedure tree forwarding (`tom_brain_logging.md`
// §5.7 / §9 / §10 step #9 — the "engine → per-procedure combined log" seam).
//
// A top-level run spans its nested runs, but each nested `runProcedure` is a
// *separate* `RunRecorder` that completes before the parent's call returns, so
// no single recorder holds the combined structure. The engine is the only
// layer that sees the whole shape — it assembles one [ProcedureTreeRecord] per
// top-level run (the parent's own trail entries as nodes, with each
// subprocedure's sub-record spliced in at the call position) and hands it to
// the bound [ProcedureTreeSink]. A nested run bubbles its sub-record up to its
// parent rather than firing the sink, so the sink sees exactly one record per
// top-level run.
//
// The tree is link-only (§5.7): each `llm` node carries a [ProcedureTreeLlmRef]
// (callType + turn correlation + token counts) so the writer can *find* the raw
// dump, never the body. Memory primitives (recall / persist / …) ride the tree
// as plain primitive nodes.

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
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
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
    ProcedureTreeSink? procedureTreeSink,
  }) =>
      ProcedureEngine(
        resolver: ProcedureResolver(procedures),
        memory: memory,
        memoryBridge: MemoryBridge(memory),
        substrateBridge: SubstrateBridge(substrate),
        now: () => DateTime.utc(2026, 6, 1, 12, 0, 0),
        procedureTreeSink: procedureTreeSink,
      );

  // A parent that issues a memory recall, one llm call (recaller), then a
  // nested subprocedure (which issues its own llm call), then a final llm
  // call (assistant_to_user). The subtree must splice in *between* the two
  // parent llm calls, at the position the nested call was issued.
  List<LoadedProcedure> mixedTreeProcedures() => <LoadedProcedure>[
        _procedure(
          'parent_v1',
          '''
import '${BridgeLibraries.substrateLibrary}';
import '${BridgeLibraries.memoryLibrary}';
import '$engineNativeLibrary';

Future<Object?> run(inputs) async {
  await mem.recall('q', modes: ['bm25'], k: 4);
  await sub.llm('parent', role: 'recaller');
  await runProcedure('child_v1', inputs);
  await sub.llm('final', role: 'assistant_to_user');
  return 1;
}
''',
        ),
        _procedure(
          'child_v1',
          '''
import '${BridgeLibraries.substrateLibrary}';

Future<Object?> run(inputs) async {
  await sub.llm('child', role: 'evaluator');
  return {'v': 1};
}
''',
        ),
      ];

  group('ProcedureEngine combined-tree forwarding (§5.7 / §10 step #9)', () {
    test(
        'a bound sink receives exactly one record per top-level run, with the '
        'subprocedure spliced between the parent calls and llm link facts',
        () async {
      final records = <ProcedureTreeRecord>[];
      final engine = engineFor(
        mixedTreeProcedures(),
        procedureTreeSink: records.add,
      );

      final turnId = TurnId.generate();
      final run = engine.invoke(
        ProcedureInvocation(procedureId: 'parent_v1', turnId: turnId),
      );
      final outcome = await run.outcome;
      expect(outcome.status, TrailOutcomeStatus.accepted);

      // Exactly one record — the top-level run. The nested run bubbled its
      // sub-record up to the parent and never fired the sink itself.
      expect(records, hasLength(1));
      final top = records.single;
      expect(top.procedureId, 'parent_v1');
      expect(top.runId, run.runId);
      expect(top.parentRunId, isNull, reason: 'top-level run has no parent');
      expect(top.turnId, turnId.value, reason: 'turn threaded from invocation');
      expect(top.depth, 1);
      expect(top.status, TrailOutcomeStatus.accepted);

      // The nodes are interleaved in trail order: recall, the recaller llm,
      // the spliced subtree, then the assistant llm — the subtree sits exactly
      // where `runProcedure` was issued.
      expect(top.nodes.map(_kindOf).toList(),
          <String>['recall', 'llm', 'subtree', 'llm'],
          reason: 'subtree spliced between the two parent llm calls');

      final recall = top.nodes[0] as ProcedurePrimitiveNode;
      expect(recall.primitive, 'recall');
      expect(recall.llm, isNull, reason: 'a memory primitive carries no llm ref');
      expect(recall.input['modes'], <String>['bm25']);
      expect((recall.result['nodes'] as List).length, 1);

      final recaller = top.nodes[1] as ProcedurePrimitiveNode;
      expect(recaller.primitive, 'llm');
      expect(recaller.llm, isNotNull);
      expect(recaller.llm!.callType, 'recaller');
      expect(recaller.llm!.turnId, turnId.value);
      expect(recaller.llm!.callSeq, 1, reason: 'first llm of the turn');

      final subtree = (top.nodes[2] as ProcedureSubtreeNode).tree;
      expect(subtree.procedureId, 'child_v1');
      expect(subtree.parentRunId, run.runId,
          reason: 'the nested record points back at the top-level run');
      expect(subtree.turnId, turnId.value);
      expect(subtree.depth, 2);
      // The child's single node is its evaluator llm call (callSeq advanced
      // across the run boundary).
      expect(subtree.nodes.map(_kindOf).toList(), <String>['llm']);
      final childLlm = subtree.nodes.single as ProcedurePrimitiveNode;
      expect(childLlm.llm!.callType, 'evaluator');
      expect(childLlm.llm!.callSeq, 2);

      final assistant = top.nodes[3] as ProcedurePrimitiveNode;
      expect(assistant.primitive, 'llm');
      expect(assistant.llm!.callType, 'assistant_to_user');
      expect(assistant.llm!.callSeq, 3,
          reason: 'third llm of the turn — counter spans the subprocedure');
    });

    test('a turn-less (dream) invocation fires once with turnId + callSeq null',
        () async {
      final records = <ProcedureTreeRecord>[];
      final engine = engineFor(
        mixedTreeProcedures(),
        procedureTreeSink: records.add,
      );

      await engine.invoke(ProcedureInvocation(procedureId: 'parent_v1')).outcome;

      expect(records, hasLength(1));
      final top = records.single;
      expect(top.turnId, isNull);
      // Every llm ref in the whole tree (parent + subtree) is unstamped.
      final llmRefs = <ProcedureTreeLlmRef>[
        ...top.nodes.whereType<ProcedurePrimitiveNode>()
            .map((n) => n.llm)
            .whereType<ProcedureTreeLlmRef>(),
        ...top.nodes
            .whereType<ProcedureSubtreeNode>()
            .expand((s) => s.tree.nodes)
            .whereType<ProcedurePrimitiveNode>()
            .map((n) => n.llm)
            .whereType<ProcedureTreeLlmRef>(),
      ];
      expect(llmRefs, isNotEmpty);
      for (final ref in llmRefs) {
        expect(ref.turnId, isNull);
        expect(ref.callSeq, isNull);
        expect(ref.runId, isNotEmpty, reason: 'the raw-stem fallback owner');
      }
    });

    test('with no sink bound the engine assembles nothing and the run is '
        'unchanged', () async {
      final engine = engineFor(mixedTreeProcedures());

      final outcome = await engine
          .invoke(ProcedureInvocation(procedureId: 'parent_v1'))
          .outcome;

      expect(outcome.status, TrailOutcomeStatus.accepted);
      expect(memory.recallCalls, 1);
    });
  });
}

String _kindOf(ProcedureTreeNode node) => switch (node) {
      ProcedurePrimitiveNode(:final primitive) =>
        primitive == 'llm' ? 'llm' : primitive,
      ProcedureSubtreeNode() => 'subtree',
      ProcedureNoteNode() => 'note',
      ProcedureErrorNode() => 'error',
    };

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

/// A substrate whose `llm` completes with a tiny answer + report, enough to
/// populate the tree's `llm` link facts.
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
            tokensIn: 7,
            tokensOut: 3,
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

/// A stateful in-memory `TomBrainMemoryClient` supporting the recorder's
/// writes plus a controllable `recall` (one node) so the tree has a real
/// memory node to render.
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
        degraded: false,
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
